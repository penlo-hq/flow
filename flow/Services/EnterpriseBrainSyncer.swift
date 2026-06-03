//
//  EnterpriseBrainSyncer.swift
//  flow
//
//  Manages syncing validated PenloPayloads to the Enterprise Brain ingestion
//  endpoint. Mirrors the Python pipeline's sync layer: exponential backoff on
//  429, offline queue for failures, automatic drain on foreground.
//
//  The endpoint URL is left configurable (empty by default) — sync only
//  attempts when both the URL and API key are configured.
//

import Foundation
import SwiftData

// MARK: - Keychain Keys for Enterprise Brain

private nonisolated(unsafe) let kBrainService = "com.getflow.flow"
private nonisolated(unsafe) let kBrainURLAccount = "enterprise-brain-url"
private nonisolated(unsafe) let kBrainKeyAccount = "enterprise-brain-key"

extension KeychainStore {

    nonisolated static func saveBrainURL(_ url: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kBrainService,
            kSecAttrAccount as String: kBrainURLAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !url.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = url.data(using: .utf8)!
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static func readBrainURL() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kBrainService,
            kSecAttrAccount as String: kBrainURLAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    nonisolated static func saveBrainKey(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kBrainService,
            kSecAttrAccount as String: kBrainKeyAccount
        ]
        SecItemDelete(query as CFDictionary)
        guard !key.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = key.data(using: .utf8)!
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    nonisolated static func readBrainKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kBrainService,
            kSecAttrAccount as String: kBrainKeyAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let str = String(data: data, encoding: .utf8),
              !str.isEmpty else {
            return nil
        }
        return str
    }

    nonisolated static var hasBrainConfig: Bool {
        readBrainURL() != nil && readBrainKey() != nil
    }
}

// MARK: - Sync Result

enum SyncStatus: String, Sendable {
    case success = "SUCCESS"
    case rateLimited = "RATE_LIMITED"
    case authFailed = "AUTH_FAILED"
    case serverError = "SERVER_ERROR"
    case networkError = "NETWORK_ERROR"
    case notConfigured = "NOT_CONFIGURED"
    case clientError = "CLIENT_ERROR"
    case validationError = "VALIDATION_ERROR"
}

struct SyncResult: Sendable {
    let ok: Bool
    let status: SyncStatus
    let detail: String
    let shouldRetry: Bool

    init(ok: Bool, status: SyncStatus, detail: String, shouldRetry: Bool = false) {
        self.ok = ok
        self.status = status
        self.detail = detail
        self.shouldRetry = shouldRetry
    }
}

// MARK: - Enterprise Brain Syncer

@MainActor
final class EnterpriseBrainSyncer {

    private static let httpTimeout: TimeInterval = 15
    private static let backoffSchedule: [UInt64] = [60, 120, 300] // seconds for 429
    private static let serverRetrySchedule: [UInt64] = [30, 60] // seconds for 5xx
    private static let userAgent = "Penlo-Brain/1.1-iOS"

    private var drainTask: Task<Void, Never>?
    private var persistenceActor: PersistenceActor?

    /// Published auth error string for display in Settings UI.
    var authError: String?

    func configure(modelContainer: ModelContainer) {
        persistenceActor = PersistenceActor(modelContainer: modelContainer)
    }

    /// Returns true if the Enterprise Brain endpoint is fully configured.
    var isConfigured: Bool {
        KeychainStore.hasBrainConfig
    }

    // MARK: - Incremental Sync Tracking

    private static let lastSyncDateKeyPrefix = "penlo.lastSyncDate."

    private func lastSyncDateKey() -> String {
        let keyPrefix = String((KeychainStore.readBrainKey() ?? "default").prefix(8))
        return Self.lastSyncDateKeyPrefix + keyPrefix
    }

    private func getLastSyncDate() -> Date? {
        UserDefaults.standard.object(forKey: lastSyncDateKey()) as? Date
    }

    private func updateLastSyncDate(_ date: Date) {
        UserDefaults.standard.set(date, forKey: lastSyncDateKey())
    }

    // MARK: - Enqueue for Sync

    /// Build incremental payload — only facts captured since last successful sync.
    private func buildIncrementalPayload(from payload: PenloPayload) -> [String: Any]? {
        guard let data = try? JSONEncoder().encode(payload),
              var dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return nil
        }

        if let lastSync = getLastSyncDate() {
            if var facts = dict["facts"] as? [[String: Any]] {
                facts = facts.filter { fact in
                    guard let capturedStr = fact["capturedAt"] as? String,
                          let captured = ISO8601DateFormatter().date(from: capturedStr) else {
                        return true
                    }
                    return captured > lastSync
                }
                dict["facts"] = facts
            }
            if var vaultFiles = dict["vaultFiles"] as? [[String: Any]] {
                vaultFiles = vaultFiles.filter { file in
                    guard let modifiedStr = file["lastModified"] as? String,
                          let modified = ISO8601DateFormatter().date(from: modifiedStr) else {
                        return true
                    }
                    return modified > lastSync
                }
                dict["vaultFiles"] = vaultFiles
            }
        }

        return dict
    }

    /// Enqueue a transcript for sync. If the endpoint is configured, attempts
    /// immediate sync. On failure, buffers the payload in SyncQueue.
    @discardableResult
    func enqueueAndSync(transcript: Transcript) async -> SyncResult {
        let userEmail = KeychainStore.readUserEmail()
        guard var payload = transcript.penloPayload else {
            return SyncResult(ok: false, status: .clientError, detail: "No payload on transcript")
        }
        payload.syncedAt = PenloTimestamp.now()
        payload.deviceID = PenloDevice.identifier
        payload.userEmail = userEmail
        guard let data = try? JSONEncoder().encode(payload) else {
            return SyncResult(ok: false, status: .clientError, detail: "Failed to encode payload")
        }

        guard isConfigured else {
            await enqueueOffline(transcriptID: transcript.id, payloadData: data, error: "Not configured")
            return SyncResult(ok: false, status: .notConfigured, detail: "Enterprise Brain URL or API key missing")
        }

        guard var payloadDict = buildIncrementalPayload(from: payload) else {
            return SyncResult(ok: false, status: .clientError, detail: "Failed to build sync payload")
        }
        let syncTimestamp = PenloTimestamp.now()
        payloadDict["syncedAt"] = syncTimestamp
        payloadDict["deviceID"] = PenloDevice.identifier
        payloadDict["userEmail"] = userEmail

        if let facts = payloadDict["facts"] as? [[String: Any]], facts.isEmpty,
           getLastSyncDate() != nil {
            try? await persistenceActor?.markSynced(transcriptID: transcript.id)
            log("Skipped sync — no new facts since last sync")
            return SyncResult(ok: true, status: .success, detail: "No new facts since last sync")
        }

        let result = await syncWithBackoff(payloadDict: payloadDict)

        if result.ok {
            try? await persistenceActor?.markSynced(transcriptID: transcript.id)
            updateLastSyncDate(Date())
            authError = nil
            log("Synced \(transcript.id.uuidString.prefix(8))")
        } else {
            handleSyncError(result, transcriptID: transcript.id)
            if result.shouldRetry {
                await enqueueOffline(transcriptID: transcript.id, payloadData: data, error: result.detail)
            }
            log("Failed \(transcript.id.uuidString.prefix(8)): \(result.status.rawValue) — \(result.detail)")
        }
        return result
    }

    /// Ping the configured Brain endpoint with a minimal payload.
    func testConnection() async -> SyncResult {
        guard isConfigured else {
            return SyncResult(ok: false, status: .notConfigured, detail: "Enter URL and API key first")
        }
        let now = PenloTimestamp.now()
        let payload: [String: Any] = [
            "schemaVersion": "1.1",
            "deviceID": PenloDevice.identifier,
            "userEmail": KeychainStore.readUserEmail() as Any,
            "syncedAt": now,
            "facts": [[
                "subject": "Penlo Flow",
                "predicate": "connected to",
                "object": "Enterprise Brain",
                "confidence": 0.99,
                "capturedAt": now,
            ]],
            "people": [],
            "topicSummary": [],
            "vaultFiles": [],
        ]
        return await syncWithBackoff(payloadDict: payload)
    }

    // MARK: - Queue Drain

    /// Attempt to drain all queued payloads. Call on app foreground.
    func drainQueue(modelContext: ModelContext) {
        guard isConfigured else { return }
        drainTask?.cancel()
        drainTask = Task {
            await performDrain(modelContext: modelContext)
        }
    }

    private func performDrain(modelContext: ModelContext) async {
        let descriptor = FetchDescriptor<SyncQueue>(
            sortBy: [SortDescriptor(\.enqueuedAt, order: .forward)]
        )
        guard let items = try? modelContext.fetch(descriptor), !items.isEmpty else { return }

        log("Draining \(items.count) queued payload(s)...")
        var drained = 0

        for item in items {
            guard !Task.isCancelled else { break }

            guard var payloadDict = (try? JSONSerialization.jsonObject(
                with: item.payload
            )) as? [String: Any] else { continue }

            payloadDict["syncedAt"] = PenloTimestamp.now()
            payloadDict["deviceID"] = PenloDevice.identifier

            let result = await syncWithBackoff(payloadDict: payloadDict)
            if result.ok {
                try? await persistenceActor?.markSynced(transcriptID: item.transcriptID)
                updateLastSyncDate(Date())
                authError = nil
                drained += 1
            } else {
                handleSyncError(result, transcriptID: item.transcriptID)
                if !result.shouldRetry {
                    try? await persistenceActor?.deleteQueueItem(id: item.id)
                } else {
                    try? await persistenceActor?.recordRetryFailure(
                        queueItemID: item.id,
                        error: result.detail
                    )
                }
            }
        }
        log("Drain complete: \(drained)/\(items.count) synced")
    }

    // MARK: - HTTP Sync

    private nonisolated func syncWithBackoff(payloadDict: [String: Any]) async -> SyncResult {
        let initial = await performSync(payloadDict: payloadDict)

        switch initial.status {
        case .rateLimited:
            for delay in Self.backoffSchedule {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else {
                    return SyncResult(ok: false, status: .networkError, detail: "Cancelled during backoff")
                }
                let retry = await performSync(payloadDict: payloadDict)
                if retry.status != .rateLimited { return retry }
            }
            return SyncResult(ok: false, status: .rateLimited, detail: "Exhausted backoff schedule", shouldRetry: true)

        case .serverError:
            for delay in Self.serverRetrySchedule {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else {
                    return SyncResult(ok: false, status: .networkError, detail: "Cancelled during backoff")
                }
                let retry = await performSync(payloadDict: payloadDict)
                if retry.status != .serverError { return retry }
            }
            return SyncResult(ok: false, status: .serverError, detail: "5xx persisted after retries", shouldRetry: true)

        case .networkError where initial.detail.contains("timed out"):
            try? await Task.sleep(for: .seconds(10))
            let retry = await performSync(payloadDict: payloadDict)
            return retry

        default:
            return initial
        }
    }

    private nonisolated func performSync(payloadDict: [String: Any]) async -> SyncResult {
        guard let urlString = KeychainStore.readBrainURL(),
              let url = Self.normalizedBrainURL(urlString),
              let apiKey = KeychainStore.readBrainKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            return SyncResult(ok: false, status: .notConfigured, detail: "Missing endpoint or key")
        }

        let sanitized = Self.sanitizePayload(payloadDict)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = Self.httpTimeout

        guard let body = try? JSONSerialization.data(withJSONObject: sanitized) else {
            return SyncResult(ok: false, status: .networkError, detail: "Failed to serialize payload")
        }
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            return SyncResult(ok: false, status: .networkError, detail: "timed out", shouldRetry: true)
        } catch {
            return SyncResult(ok: false, status: .networkError, detail: error.localizedDescription, shouldRetry: true)
        }

        guard let http = response as? HTTPURLResponse else {
            return SyncResult(ok: false, status: .networkError, detail: "Invalid response", shouldRetry: true)
        }

        let responseBody = String(data: data.prefix(500), encoding: .utf8) ?? ""

        switch http.statusCode {
        case 200...299:
            return SyncResult(ok: true, status: .success, detail: "Backend accepted payload")
        case 400:
            return SyncResult(ok: false, status: .clientError, detail: "HTTP 400: \(responseBody)")
        case 401, 403:
            return SyncResult(ok: false, status: .authFailed, detail: "HTTP \(http.statusCode) — invalid credential")
        case 422:
            return SyncResult(ok: false, status: .validationError, detail: "HTTP 422: \(responseBody)")
        case 429:
            return SyncResult(ok: false, status: .rateLimited, detail: "HTTP 429", shouldRetry: true)
        case 500...599:
            return SyncResult(ok: false, status: .serverError, detail: "HTTP \(http.statusCode): \(responseBody)", shouldRetry: true)
        default:
            return SyncResult(ok: false, status: .serverError, detail: "HTTP \(http.statusCode): \(responseBody)", shouldRetry: true)
        }
    }

    /// Ensure legacy facts with empty capturedAt still validate on the backend.
    private nonisolated static func sanitizePayload(_ dict: [String: Any]) -> [String: Any] {
        var out = dict
        let fallback = (out["syncedAt"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? PenloTimestamp.now()
        if var facts = out["facts"] as? [[String: Any]] {
            facts = facts.map { fact in
                var row = fact
                let captured = row["capturedAt"] as? String
                if captured == nil || captured?.isEmpty == true {
                    row["capturedAt"] = fallback
                }
                return row
            }
            out["facts"] = facts
        }
        return out
    }

    /// Accept base URL or full ingest path; trim whitespace.
    nonisolated static func normalizedBrainURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var urlString = trimmed
        if urlString.contains("/api/v1/ingest/penlo-brain") {
            return URL(string: urlString)
        }

        urlString = urlString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if urlString.hasSuffix("/api/v1/ingest") {
            urlString += "/penlo-brain"
        } else {
            urlString += "/api/v1/ingest/penlo-brain"
        }
        return URL(string: urlString)
    }

    // MARK: - Error Handling

    private func handleSyncError(_ result: SyncResult, transcriptID: UUID) {
        switch result.status {
        case .authFailed:
            authError = "Enterprise Brain API key is invalid. Please update in Settings."
            Task { @MainActor in
                NotificationManager.shared.notifyAuthExpired()
            }
        case .clientError, .validationError:
            logToFile("PERMANENT FAIL [\(result.status.rawValue)] transcript=\(transcriptID.uuidString.prefix(8)): \(result.detail)")
            Task { @MainActor in
                NotificationManager.shared.notifySyncFailed(detail: result.detail)
            }
        case .serverError, .rateLimited, .networkError:
            logToFile("RETRYABLE [\(result.status.rawValue)] transcript=\(transcriptID.uuidString.prefix(8)): \(result.detail)")
        default:
            break
        }
    }

    // MARK: - Offline Queue

    private func enqueueOffline(transcriptID: UUID, payloadData: Data, error: String?) async {
        try? await persistenceActor?.enqueueFailedPayload(
            transcriptID: transcriptID,
            payload: payloadData,
            error: error
        )
    }

    // MARK: - Logging

    private static let logFileName = "penlo_sync.log"

    private static var logFileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent(logFileName)
    }

    private func logToFile(_ message: String) {
        let entry = "[\(PenloTimestamp.now())] \(message)\n"
        let url = Self.logFileURL
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(entry.utf8))
            handle.closeFile()
        } else {
            try? entry.write(to: url, atomically: true, encoding: .utf8)
        }
        log(message)
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[Penlo Sync] \(message)")
        #endif
    }
}
