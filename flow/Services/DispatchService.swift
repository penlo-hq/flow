//
//  DispatchService.swift
//  flow
//
//  API client for the Enterprise Brain dispatch endpoints.
//

import Combine
import Foundation

struct CompanyGitHubSettings: Equatable {
    var repo: String
    var baseBranch: String
}

enum DispatchCardAction: Equatable {
    case idle
    case approving(String)   // mode
    case discarding
}

@MainActor
final class DispatchService: ObservableObject {
    @Published var cards: [DispatchCard] = []
    @Published var pendingCount: Int = 0
    @Published var isLoading = false
    @Published var isRefreshing = false
    @Published var authError: String? = nil
    @Published var networkError: String? = nil
    @Published var lastActionError: String? = nil
    @Published var executorEnabled = false
    @Published var githubTokenConfigured = false
    @Published var highlightDispatchId: String?
    @Published var githubSettings: CompanyGitHubSettings?
    @Published var githubSettingsAdminOnly = false
    @Published var cardActions: [UUID: DispatchCardAction] = [:]

    private var pollingTask: Task<Void, Never>?
    private var capabilitiesLoaded = false
    private var lastPendingCount = 0
    private var lastStatuses: [UUID: String] = [:]

    private let decoder: JSONDecoder = {
        JSONDecoder()
    }()

    var canAutoBuild: Bool {
        executorEnabled
            && githubTokenConfigured
            && !(githubSettings?.repo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    var autoBuildDisabledReason: String? {
        guard executorEnabled else { return "Auto-build is off on the server (executor disabled)." }
        guard githubTokenConfigured else { return "Server GitHub token is not configured." }
        let repo = githubSettings?.repo.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if repo.isEmpty { return "Set a default GitHub repo below to enable auto-build." }
        return nil
    }

    // MARK: - Base URL

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
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = method
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        return req
    }

    private func apiErrorMessage(data: Data, status: Int) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = json["detail"] as? String, !detail.isEmpty {
                return detail
            }
            if let message = json["message"] as? String, !message.isEmpty {
                return message
            }
        }
        return "Request failed (HTTP \(status))."
    }

    private func setCardAction(_ id: UUID, _ action: DispatchCardAction) {
        cardActions[id] = action
    }

    private func clearCardAction(_ id: UUID) {
        cardActions[id] = nil
    }

    // MARK: - Capabilities & GitHub

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
                githubTokenConfigured = json["github_token_configured"] as? Bool
                    ?? (json["github_token"] as? Bool)
                    ?? executorEnabled
            }
            capabilitiesLoaded = true
        } catch {
            executorEnabled = false
            capabilitiesLoaded = true
        }
    }

    func fetchGitHubSettings() async {
        guard let req = request(path: "/api/v1/admin/github-settings") else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 403 {
                githubSettingsAdminOnly = true
                return
            }
            guard (200...299).contains(http.statusCode) else { return }
            githubSettingsAdminOnly = false
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let repo = (json["github_repo"] as? String) ?? ""
                let branch = (json["github_base_branch"] as? String) ?? "main"
                githubSettings = CompanyGitHubSettings(repo: repo, baseBranch: branch)
            }
        } catch {
            // Non-fatal; auto-build may still use per-dispatch repo
        }
    }

    func saveGitHubSettings(repo: String, baseBranch: String) async -> String? {
        let trimmedRepo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepo.isEmpty else { return "Repository is required." }
        let branch = baseBranch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "main" : baseBranch
        let body: [String: String] = [
            "github_repo": trimmedRepo,
            "github_base_branch": branch,
        ]
        guard let data = try? JSONEncoder().encode(body),
              let req = request(path: "/api/v1/admin/github-settings", method: "POST", body: data) else {
            return "Brain not configured."
        }
        do {
            let (respData, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return "Unexpected response." }
            if http.statusCode == 403 {
                return "Only company admins can save GitHub defaults."
            }
            guard (200...299).contains(http.statusCode) else {
                return apiErrorMessage(data: respData, status: http.statusCode)
            }
            githubSettings = CompanyGitHubSettings(repo: trimmedRepo, baseBranch: branch)
            Haptics.success()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Fetch

    func fetchCards(silent: Bool = false) async {
        if !capabilitiesLoaded {
            await fetchCapabilities()
        }
        if githubSettings == nil && !githubSettingsAdminOnly {
            await fetchGitHubSettings()
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
        if silent {
            isRefreshing = true
        } else {
            isLoading = true
        }
        defer {
            isLoading = false
            isRefreshing = false
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return }
            if http.statusCode == 401 {
                authError = "API key invalid or revoked. Update it in Settings."
                return
            }
            if http.statusCode == 403 {
                authError = "Your account must be admin or team lead to view dispatches."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                networkError = apiErrorMessage(data: data, status: http.statusCode)
                return
            }
            authError = nil
            networkError = nil
            let fetched = try decoder.decode([DispatchCard].self, from: data)
            let sorted = fetched.sorted {
                ($0.createdAt) < ($1.createdAt)
            }
            let newPending = sorted.filter { $0.status == "pending" }.count
            detectDispatchChanges(fetched: sorted, newPending: newPending)
            cards = sorted
            pendingCount = newPending
            lastPendingCount = newPending
            lastStatuses = Dictionary(uniqueKeysWithValues: sorted.map { ($0.id, $0.status) })
            pruneStaleCardActions(against: sorted)
        } catch {
            if cards.isEmpty {
                networkError = "Couldn't reach Enterprise Brain. Check URL and network."
            }
        }
    }

    func refresh() async {
        await fetchCards(silent: true)
    }

    // MARK: - Approve

    func approve(id: UUID, mode: String) async {
        lastActionError = nil
        setCardAction(id, .approving(mode))
        defer { clearCardAction(id) }

        var payload: [String: String] = ["mode": mode]
        if mode == "auto" {
            let repo = githubSettings?.repo.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !repo.isEmpty {
                payload["github_repo"] = repo
                payload["github_base_branch"] = githubSettings?.baseBranch ?? "main"
            }
        }

        guard let body = try? JSONEncoder().encode(payload),
              let req = request(
                path: "/api/v1/dispatches/\(id.uuidString.lowercased())/approve",
                method: "POST",
                body: body
              ) else {
            lastActionError = "Brain not configured."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastActionError = "Unexpected response from Brain."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                lastActionError = apiErrorMessage(data: data, status: http.statusCode)
                Haptics.medium()
                return
            }
            if let updated = try? decoder.decode(DispatchCard.self, from: data) {
                replaceCard(updated)
            }
            Haptics.success()
            await fetchCards(silent: true)
        } catch {
            lastActionError = error.localizedDescription
            Haptics.medium()
        }
    }

    // MARK: - Discard

    func discard(id: UUID) async {
        lastActionError = nil
        setCardAction(id, .discarding)
        defer { clearCardAction(id) }

        guard let req = request(
            path: "/api/v1/dispatches/\(id.uuidString.lowercased())/discard",
            method: "POST"
        ) else {
            lastActionError = "Brain not configured."
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                lastActionError = "Unexpected response from Brain."
                return
            }
            guard (200...299).contains(http.statusCode) else {
                lastActionError = apiErrorMessage(data: data, status: http.statusCode)
                Haptics.medium()
                return
            }
            cards.removeAll { $0.id == id }
            pendingCount = cards.filter { $0.status == "pending" }.count
            Haptics.light()
            await fetchCards(silent: true)
        } catch {
            lastActionError = error.localizedDescription
            Haptics.medium()
        }
    }

    func isPerformingAction(on cardId: UUID) -> Bool {
        guard let action = cardActions[cardId] else { return false }
        return action != .idle
    }

    func actionLabel(for cardId: UUID) -> String? {
        switch cardActions[cardId] {
        case .approving("auto"): return "Starting auto-build…"
        case .approving: return "Queuing…"
        case .discarding: return "Discarding…"
        default: return nil
        }
    }

    // MARK: - Polling

    func startPolling() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.fetchCards(silent: true)
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    // MARK: - Private

    private func replaceCard(_ updated: DispatchCard) {
        if let idx = cards.firstIndex(where: { $0.id == updated.id }) {
            cards[idx] = updated
        } else {
            cards.append(updated)
        }
        pendingCount = cards.filter { $0.status == "pending" }.count
    }

    private func pruneStaleCardActions(against cards: [DispatchCard]) {
        let ids = Set(cards.map(\.id))
        for key in cardActions.keys where !ids.contains(key) {
            cardActions.removeValue(forKey: key)
        }
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
                NotificationManager.shared.notifyDispatchFailed(
                    featureLabel: card.featureLabel,
                    error: card.error ?? "Build failed"
                )
            }
        }
    }
}
