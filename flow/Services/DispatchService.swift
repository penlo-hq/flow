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

import Foundation

@MainActor
final class DispatchService: ObservableObject {
    @Published var cards: [DispatchCard] = []
    @Published var pendingCount: Int = 0
    @Published var isLoading = false
    @Published var authError: String? = nil

    private var pollingTask: Task<Void, Never>?

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

    func fetchCards() async {
        guard let req = request(path: "/api/v1/dispatches?status=active") else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 || http.statusCode == 403 {
                authError = "API key invalid or lacks dispatch access. Update it in Settings."
                return
            }
            guard (200...299).contains(http.statusCode) else { return }
            authError = nil
            let fetched = try decoder.decode([DispatchCard].self, from: data)
            cards = fetched
            pendingCount = fetched.filter { $0.status == "pending" }.count
        } catch {
            // Network/decode errors are silent during background polling so the
            // UI doesn't flicker on transient connectivity loss.
        }
    }

    // MARK: - Approve

    func approve(id: UUID, mode: String) async {
        guard let body = try? JSONEncoder().encode(["mode": mode]),
              let req = request(path: "/api/v1/dispatches/\(id.uuidString.lowercased())/approve", method: "POST", body: body)
        else { return }
        _ = try? await URLSession.shared.data(for: req)
        await fetchCards()
    }

    // MARK: - Discard

    func discard(id: UUID) async {
        guard let req = request(path: "/api/v1/dispatches/\(id.uuidString.lowercased())/discard", method: "POST") else { return }
        _ = try? await URLSession.shared.data(for: req)
        await fetchCards()
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
}
