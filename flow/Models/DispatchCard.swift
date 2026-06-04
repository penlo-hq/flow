//
//  DispatchCard.swift
//  flow
//
//  Codable model for a pending dispatch card returned by the Enterprise Brain
//  dispatch API (`GET /api/v1/dispatches?status=active`). Mirrors the backend's
//  `PendingDispatch.card_dict()` shape exactly.
//

import Foundation

struct DispatchRelatedDecision: Codable {
    let label: String
    let detail: String?
}

struct DispatchRelatedPerson: Codable {
    let label: String
}

struct DispatchExecutionTraceEntry: Codable {
    let tool: String
    let input: [String: String]?
    let result: String?
}

struct DispatchCard: Codable, Identifiable {
    let id: UUID
    let featureLabel: String
    let featureSummary: String?
    let source: String?
    let complexity: String?   // "simple" | "complex" | nil
    let nodeType: String?     // "feature" | "task" | nil
    let detail: String?
    let relatedDecisions: [DispatchRelatedDecision]?
    let relatedPeople: [DispatchRelatedPerson]?
    let acceptanceCriteria: [String]?
    let buildBriefPreview: String?
    let executionTrace: [DispatchExecutionTraceEntry]?
    let status: String        // pending | approved | building | completed | failed | discarded
    let mode: String?         // "auto" | "mcp" | nil
    let prUrl: String?
    let error: String?
    let githubRepo: String?
    let githubBaseBranch: String?
    let startedAt: String?
    let expiresAt: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case featureLabel = "feature_label"
        case featureSummary = "feature_summary"
        case source
        case complexity
        case nodeType = "node_type"
        case detail
        case relatedDecisions = "related_decisions"
        case relatedPeople = "related_people"
        case acceptanceCriteria = "acceptance_criteria"
        case buildBriefPreview = "build_brief_preview"
        case executionTrace = "execution_trace"
        case status
        case mode
        case prUrl = "pr_url"
        case error
        case githubRepo = "github_repo"
        case githubBaseBranch = "github_base_branch"
        case startedAt = "started_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }
}
