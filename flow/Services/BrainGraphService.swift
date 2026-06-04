//
//  BrainGraphService.swift
//  flow
//
//  Read-only company graph from Enterprise Brain (source of truth for vault categories).
//

import Foundation
import Observation

struct BrainGraphNode: Identifiable, Equatable, Sendable {
    let id: String
    let type: String
    let label: String
    let detail: String?
    let importance: Double
    let updatedAt: String?

    var nodeType: PenloNodeType? {
        PenloNodeType(rawValue: type)
    }
}

struct BrainGraphSnapshot: Equatable, Sendable {
    var nodes: [BrainGraphNode]
    var fetchedAt: Date
}

@MainActor
@Observable
final class BrainGraphService {
    static let shared = BrainGraphService()

    private(set) var snapshot: BrainGraphSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?

    var isConfigured: Bool { KeychainStore.hasBrainConfig }

    func nodes(ofType type: PenloNodeType) -> [BrainGraphNode] {
        (snapshot?.nodes ?? [])
            .filter { $0.type == type.rawValue }
            .sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
    }

    func count(for type: PenloNodeType) -> Int {
        nodes(ofType: type).count
    }

    func countByType() -> [PenloNodeType: Int] {
        var counts: [PenloNodeType: Int] = [:]
        for node in snapshot?.nodes ?? [] {
            guard let t = PenloNodeType(rawValue: node.type) else { continue }
            counts[t, default: 0] += 1
        }
        return counts
    }

    func refresh() async {
        guard isConfigured else {
            snapshot = nil
            lastError = nil
            return
        }
        guard let url = Self.companyGraphURL(),
              let apiKey = KeychainStore.readBrainKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            lastError = "Enterprise Brain not configured"
            return
        }

        isLoading = true
        defer { isLoading = false }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Penlo-Brain/1.1-iOS", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                lastError = "Invalid response"
                return
            }
            guard (200...299).contains(http.statusCode) else {
                let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
                lastError = "HTTP \(http.statusCode): \(body)"
                return
            }
            let decoded = try JSONDecoder().decode(GraphAPIResponse.self, from: data)
            snapshot = BrainGraphSnapshot(nodes: decoded.nodes, fetchedAt: .now)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Derive `GET /api/v1/graph/company` from the configured ingest URL.
    nonisolated static func companyGraphURL() -> URL? {
        guard let raw = KeychainStore.readBrainURL(),
              let ingestURL = EnterpriseBrainSyncer.normalizedBrainURL(raw),
              var components = URLComponents(url: ingestURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var path = components.path
        if let range = path.range(of: "/api/v1/ingest") {
            path.replaceSubrange(range, with: "/api/v1/graph/company")
        } else {
            path = "/api/v1/graph/company"
        }
        components.path = path
        components.query = nil
        components.fragment = nil
        return components.url
    }

    private struct GraphAPIResponse: Decodable {
        let nodes: [BrainGraphNode]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            let rawNodes = try container.decode([RawNode].self, forKey: .nodes)
            nodes = rawNodes.map {
                BrainGraphNode(
                    id: $0.id,
                    type: $0.type,
                    label: $0.label,
                    detail: $0.detail,
                    importance: $0.importance ?? 0,
                    updatedAt: $0.updated_at
                )
            }
        }

        enum CodingKeys: String, CodingKey { case nodes }

        private struct RawNode: Decodable {
            let id: String
            let type: String
            let label: String
            let detail: String?
            let importance: Double?
            let updated_at: String?
        }
    }
}
