//
//  ChatViewModel.swift
//  flow
//
//  Manages the conversational message stream. Handles user prompts,
//  Claude-powered Penlo responses with local transcript context,
//  and automatic briefing injection 15 minutes before a meeting.
//

import Observation
import SwiftData
import SwiftUI

@Observable
@MainActor
final class ChatViewModel {

    var messages: [ChatMessage] = []
    var isThinking = false

    let suggestions = [
        "Summarize my day",
        "Any open action items?",
        "Brief me for the next meeting"
    ]

    /// Conversation identifier — changes on "New Chat".
    private(set) var conversationID = UUID()

    /// Archived conversations for the drawer history list.
    var archivedConversations: [ArchivedConversation] = []

    private let claude = ClaudeService.shared

    /// Set by ContentView on appear so the VM can query local transcripts.
    var modelContext: ModelContext?

    // MARK: - Send

    func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isThinking else { return }

        Haptics.light()

        messages.append(ChatMessage(role: .user, text: trimmed))
        isThinking = true

        Task {
            defer { isThinking = false }
            let response = await fetchClaudeResponse()
            messages.append(response)
            Haptics.light()
        }
    }

    func sendSuggestion(_ suggestion: String) {
        send(suggestion)
    }

    // MARK: - New Chat

    func startNewChat() {
        archiveCurrentConversation()
        messages = []
        isThinking = false
        conversationID = UUID()
        Haptics.medium()
    }

    /// Restore a previously archived conversation.
    func restoreConversation(_ archived: ArchivedConversation) {
        archiveCurrentConversation()
        messages = archived.messages.map { msg in
            var copy = msg
            copy.shouldAnimateTyping = false
            return copy
        }
        conversationID = archived.id
        isThinking = false
        Haptics.light()
    }

    private func archiveCurrentConversation() {
        guard !messages.isEmpty else { return }
        let preview = messages.first(where: { $0.role == .user })?.text
            ?? messages.first?.text
            ?? "Conversation"
        let truncated = String(preview.prefix(50))

        if let idx = archivedConversations.firstIndex(where: { $0.id == conversationID }) {
            archivedConversations[idx] = ArchivedConversation(
                id: conversationID,
                preview: truncated,
                date: .now,
                messages: messages
            )
        } else {
            archivedConversations.insert(
                ArchivedConversation(
                    id: conversationID,
                    preview: truncated,
                    date: .now,
                    messages: messages
                ),
                at: 0
            )
        }
    }

    // MARK: - Briefing Injection

    func injectBriefing(_ briefing: Briefing) {
        let text = "You have a meeting — \(briefing.meetingTitle) — in \(briefing.minutesUntil)m. Tap to view briefing."
        let message = ChatMessage(
            role: .briefing,
            text: text,
            briefing: briefing
        )
        messages.append(message)
        Haptics.success()
    }

    func toggleBriefingExpansion(for messageID: UUID) {
        guard let idx = messages.firstIndex(where: { $0.id == messageID }) else { return }
        messages[idx].isBriefingExpanded.toggle()
        Haptics.light()
    }

    // MARK: - Claude API

    private func fetchClaudeResponse() async -> ChatMessage {
        let turns = buildConversationTurns()
        let context = buildTranscriptContext()
        do {
            let result = try await claude.send(messages: turns, transcriptContext: context)
            return ChatMessage(
                role: .penlo,
                text: result.text,
                nodes: result.nodes
            )
        } catch let error as ClaudeService.ServiceError {
            return ChatMessage(role: .penlo, text: error.userFacingMessage, isError: true)
        } catch {
            return ChatMessage(
                role: .penlo,
                text: "Something went wrong. Please try again.",
                isError: true
            )
        }
    }

    private func buildConversationTurns() -> [ClaudeService.Turn] {
        messages.compactMap { message in
            switch message.role {
            case .user:
                return ClaudeService.Turn(role: "user", content: message.text)
            case .penlo:
                return ClaudeService.Turn(role: "assistant", content: message.text)
            case .briefing:
                return nil
            }
        }
    }

    /// Fetches up to 10 recent transcripts from SwiftData and formats them
    /// as context for Claude. Gives Penlo actual knowledge of the user's day.
    private func buildTranscriptContext() -> String? {
        guard let context = modelContext else { return nil }

        var descriptor = FetchDescriptor<Transcript>(
            sortBy: [SortDescriptor(\.capturedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 10

        guard let transcripts = try? context.fetch(descriptor),
              !transcripts.isEmpty else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"

        var lines: [String] = []
        for t in transcripts {
            let time = formatter.string(from: t.capturedAt)
            if let payload = t.payload {
                var entry = "[\(time)] \(payload.title)"
                if !payload.facts.isEmpty {
                    entry += "\n  Facts: " + payload.facts.map(\.displayText).joined(separator: "; ")
                }
                if !payload.people.isEmpty {
                    entry += "\n  People: " + payload.peopleNames.joined(separator: ", ")
                }
                if !payload.topicSummary.isEmpty {
                    entry += "\n  Topics: " + payload.topicSummary.joined(separator: ", ")
                }
                lines.append(entry)
            } else {
                lines.append("[\(time)] \(t.rawText)")
            }
        }

        return lines.joined(separator: "\n\n")
    }
}

// MARK: - Archived Conversation

struct ArchivedConversation: Identifiable {
    let id: UUID
    let preview: String
    let date: Date
    let messages: [ChatMessage]

    var relativeDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: .now)
    }
}
