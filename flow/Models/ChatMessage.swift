//
//  ChatMessage.swift
//  flow
//
//  A single message in the Penlo conversational interface.
//  Three roles: user prompts, Penlo AI responses, and inline briefings
//  that inject automatically before meetings.
//

import Foundation

struct ChatMessage: Identifiable {
    let id = UUID()
    let role: Role
    let text: String
    let timestamp: Date
    var nodes: [ExtractedNode]
    var briefing: Briefing?
    var isBriefingExpanded: Bool
    var isError: Bool
    /// When true, Penlo answers animate in with a typewriter effect (new messages only).
    var shouldAnimateTyping: Bool

    enum Role {
        case user
        case penlo
        case briefing
    }

    init(
        role: Role,
        text: String,
        timestamp: Date = .now,
        nodes: [ExtractedNode] = [],
        briefing: Briefing? = nil,
        isBriefingExpanded: Bool = false,
        isError: Bool = false,
        shouldAnimateTyping: Bool = true
    ) {
        self.role = role
        self.text = text
        self.timestamp = timestamp
        self.nodes = nodes
        self.briefing = briefing
        self.isBriefingExpanded = isBriefingExpanded
        self.isError = isError
        self.shouldAnimateTyping = shouldAnimateTyping
    }

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: timestamp)
    }
}

// MARK: - Sample Data

extension ChatMessage {
    static let sampleConversation: [ChatMessage] = [
        ChatMessage(
            role: .penlo,
            text: "Good morning. I captured 3 conversations this morning.",
            nodes: []
        ),
        ChatMessage(
            role: .user,
            text: "Summarize my day so far."
        ),
        ChatMessage(
            role: .penlo,
            text: "You reviewed the Q3 roadmap and aligned on shipping Enterprise Sync before the offsite. Later, the standup surfaced blockers on the BLE pairing flow — the hardware team is following up this week.",
            nodes: [
                ExtractedNode(kind: .feature, label: "Enterprise Sync"),
                ExtractedNode(kind: .person, label: "Nolan Carroll"),
                ExtractedNode(kind: .decision, label: "Ship before offsite"),
                ExtractedNode(kind: .question, label: "BLE pairing reliability")
            ]
        ),
        ChatMessage(
            role: .briefing,
            text: "You have a meeting with Nolan Carroll in 15m. Tap to view briefing.",
            briefing: .sample
        )
    ]
}
