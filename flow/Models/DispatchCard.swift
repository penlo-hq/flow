//
//  DispatchCard.swift
//  flow
//
//  Codable model for a pending dispatch card returned by the Enterprise Brain
//  dispatch API (`GET /api/v1/dispatches?status=active`). Mirrors the backend's
//  `PendingDispatch.card_dict()` shape exactly.
//

import Foundation

struct DispatchCard: Codable, Identifiable {
    let id: UUID
    let featureLabel: String
    let featureSummary: String?
    let source: String?
    let complexity: String?   // "simple" | "complex" | nil
    let status: String        // pending | approved | building | completed | failed | discarded
    let mode: String?         // "auto" | "mcp" | nil
    let prUrl: String?
    let error: String?
    let startedAt: String?
    let expiresAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case featureLabel = "feature_label"
        case featureSummary = "feature_summary"
        case source
        case complexity
        case status
        case mode
        case prUrl = "pr_url"
        case error
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}
