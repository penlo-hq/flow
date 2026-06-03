//
//  DispatchService.swift
//  flow
//
//  API client for the Enterprise Brain dispatch endpoints. Handles listing
//  active dispatch cards, approving (auto-build / queue-for-dev), discarding,
//  and lightweight polling for live status transitions.
//
//  Auth: the brain API key (`pb_live_…`) is read from the Keychain and sent as
//  `Authorization: Bearer <key>`. This mirrors `EnterpriseBrainSyncer` and the
//  backend's `get_api_key_auth` in `backend/api/deps.py`, which expects a
//  Bearer token. (The original plan specified an `X-API-Key` header; no such
//  header exists on the backend — see PR notes.)
//

import Combine
import Foundation

@MainActor
final class DispatchService: ObservableObject {
    @Published var cards: [DispatchCard] = []
    @Published var pendingCount: Int = 0
    @Published var isLoading = false
    @Published var authError: String? = nil
    @Published var lastActionError: String? = nil
    @Published var executorEnabled = false
    @Published var highlightDispatchId: String?

    private var pollingTask: Task<Void, Never>?
    private var capabilitiesLoaded = false
    private var lastPendingCount = 0
    private var lastStatuses: [UUID: String] = [:]

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        // The model declares explicit CodingKeys for snake_case mapping, so no
        // key-decoding strategy is needed. Dates are kept as ISO-8601 strings.
        return d
    }()

    // MARK: - Base URL

    /// Derive the brain host root from the stored ingest URL. The stored value
    /// is typically the full ingest path (e.g.
    /// `http://host:8000/api/v1/ingest/penlo-brain`); strip everything past the
    /// host so relative dispatch paths resolve correctly.
    private func baseURL() -> URL? {
        guard let raw = KeychainStore.readBrainURL() else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private func apiKey() -> String? {
        KeychainStore.readBrainKey()?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) -> URLRequest? {
        guard let base = baseURL(), let key = apiKey(), !key.isEmpty else { return nil }
        guard let url = URL(string: path, relativeTo: base) else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    // MARK: - Fetch

    func fetchCapabilities() async {
        guard let base = baseURL(),
              let url = URL(string: "/health", relativeTo: base) else { return }
        var req = URLRequest(url: url, timeoutInterval: 5)
        req.httpMethod = "GET"
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                executorEnabled = json["executor_enabled"] as? Bool ?? false
            }
            capabilitiesLoaded = true
        } catch {
            executorEnabled = false
            capabilitiesLoaded = true
        }
    }

    func fetchCards() async {
        if !capabilitiesLoaded {
            await fetchCapabilities()
        }
        guard baseURL() != nil, let key = apiKey(), !key.isEmpty else {
            authError = "Configure Enterprise Brain URL and API key in Settings."
            cards = []
            pendingCount = 0
            return
        }
        guard let req = request(path: "/api/v1/dispatches?status=active") else {
            authError = "Configure Enterprise Brain URL and API key in Settings."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                authError = "API key invalid or revoked. Update it in Settings."
                return
            }
            if http.statusCode == 403 {
                authError = "API key user must be admin or team lead to view dispatches."
                return
            }
            guard (200...299).contains(http.statusCode) else { return }
            authError = nil
            let fetched = try decoder.decode([DispatchCard].self, from: data)
            let newPending = fetched.filter { $0.status == "pending" }.count
            detectDispatchChanges(fetched: fetched, newPending: newPending)
            cards = fetched
            pendingCount = newPending
            lastPendingCount = newPending
            lastStatuses = Dictionary(uniqueKeysWithValues: fetched.map { ($0.id, $0.status) })
        } catch {
            // Network/decode errors are silent during background polling so the
            // UI doesn't flicker on transient connectivity loss.
        }
    }

    // MARK: - Approve

    func approve(id: UUID, mode: String) async {
        lastActionError = nil
        guard let body = try? JSONEncoder().encode(["mode": mode]),
              let req = request(path: "/api/v1/dispatches/\(id.uuidString.lowercased())/approve", method: "POST", body: body)
        else {
            lastActionError = "Brain not configured."
            return
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastActionError = "Unexpected response from Brain."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                lastActionError = "Approve failed (HTTP \(http.statusCode))."
                return
            }
            await fetchCards()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    // MARK: - Discard

    func discard(id: UUID) async {
        lastActionError = nil
        guard let req = request(path: "/api/v1/dispatches/\(id.uuidString.lowercased())/discard", method: "POST") else {
            lastActionError = "Brain not configured."
            return
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastActionError = "Unexpected response from Brain."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                lastActionError = "Discard failed (HTTP \(http.statusCode))."
                return
            }
            await fetchCards()
        } catch {
            lastActionError = error.localizedDescription
        }
    }

    // MARK: - Polling

    /// Idempotent: a second call while polling is active is a no-op.
    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchCards()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func detectDispatchChanges(fetched: [DispatchCard], newPending: Int) {
        if newPending > lastPendingCount {
            let pending = fetched.first(where: { $0.status == "pending" })
            NotificationManager.shared.notifyDispatchPending(
                count: newPending,
                featureLabel: pending?.featureLabel,
                dispatchId: pending?.id.uuidString.lowercased()
            )
        }
        for card in fetched {
            let prev = lastStatuses[card.id]
            guard let prev, prev != card.status else { continue }
            if card.status == "completed" {
                NotificationManager.shared.notifyDispatchComplete(featureLabel: card.featureLabel, prURL: card.prUrl)
            } else if card.status == "failed" {
                NotificationManager.shared.notifyDispatchFailed(featureLabel: card.featureLabel, error: card.error ?? "Build failed")
            }
        }
    }
}
