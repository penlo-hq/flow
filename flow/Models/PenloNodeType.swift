//
//  PenloNodeType.swift
//  flow
//
//  Canonical node taxonomy — mirrors web/src/types/graph.ts (source of truth: Brain + web).
//

import Foundation

enum PenloNodeType: String, CaseIterable, Identifiable, Sendable {
    case company
    case team
    case person
    case client
    case topic
    case task
    case event
    case feature
    case decision
    case architecture
    case draft
    case agent
    case alert

    var id: String { rawValue }

    /// Same order as web NODE_TYPE_ORDER.
    static let displayOrder: [PenloNodeType] = [
        .company, .team, .person, .client, .topic, .task, .event,
        .feature, .decision, .architecture, .draft, .agent, .alert,
    ]

    var displayLabel: String {
        switch self {
        case .company: return "Company"
        case .team: return "Team"
        case .person: return "Person"
        case .client: return "Client"
        case .topic: return "Topic"
        case .task: return "Task"
        case .event: return "Event"
        case .feature: return "Feature"
        case .decision: return "Decision"
        case .architecture: return "Architecture"
        case .draft: return "Draft"
        case .agent: return "Agent"
        case .alert: return "Alert"
        }
    }

    /// Brain vault folder key used in penlo-brain `vaultFiles[].folder`.
    var vaultFolderKey: String? {
        switch self {
        case .person: return "people"
        case .client: return "clients"
        case .topic: return "topics"
        case .feature: return "features"
        case .task: return "tasks"
        case .decision: return "decisions"
        case .event: return "events"
        default: return nil
        }
    }
}

extension VaultFolder {
    var nodeType: PenloNodeType {
        switch self {
        case .people: return .person
        case .topics: return .topic
        case .tasks: return .task
        case .decisions: return .decision
        case .features: return .feature
        case .clients: return .client
        case .events: return .event
        }
    }
}
