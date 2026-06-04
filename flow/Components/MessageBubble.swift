//
//  MessageBubble.swift
//  flow
//
//  Renders a single message in the chat stream. Three visual treatments:
//  - User prompts: right-aligned, Royal Blue background, white text.
//  - Penlo responses: left-aligned, transparent background, primary text,
//    with optional inline entity chips and timestamp.
//  - Briefing injection: left-aligned, muted accent border, tappable
//    to expand the full briefing inline.
//

import SwiftUI

struct MessageBubble: View {
    let message: ChatMessage
    var onBriefingTap: (() -> Void)? = nil
    var onTypingProgress: (() -> Void)? = nil

    @State private var typingComplete = false

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 60) }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 8) {
                bubbleContent

                if typingComplete && !message.nodes.isEmpty {
                    inlineChips
                }

                if message.role == .briefing, message.isBriefingExpanded, let briefing = message.briefing {
                    expandedBriefing(briefing)
                }

                Text(message.formattedTime)
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary.opacity(0.6))
            }

            if message.role != .user { Spacer(minLength: 60) }
        }
        .onAppear {
            if message.role != .penlo || message.isError || !message.shouldAnimateTyping {
                typingComplete = true
            }
        }
        .onChange(of: message.id) { _, _ in
            typingComplete = message.role != .penlo || message.isError || !message.shouldAnimateTyping
        }
    }

    // MARK: - Bubble Content

    @ViewBuilder
    private var bubbleContent: some View {
        switch message.role {
        case .user:
            RichTextView(text: message.text, isUser: true)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.royalBlue, in: BubbleShape(isUser: true))

        case .penlo:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    Image(systemName: message.isError ? "exclamationmark.triangle.fill" : "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(message.isError ? Color.orange : Color.royalBlue)
                    Text("Penlo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }

                if message.isError {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color.orange.opacity(0.2), lineWidth: 0.5)
                        )
                } else if message.shouldAnimateTyping {
                    TypingRichTextView(
                        text: message.text,
                        isUser: false,
                        enabled: true,
                        onProgress: onTypingProgress,
                        onComplete: { typingComplete = true }
                    )
                } else {
                    RichTextView(text: message.text, isUser: false)
                        .onAppear { typingComplete = true }
                }
            }
            .padding(.horizontal, 4)

        case .briefing:
            Button {
                onBriefingTap?()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar.badge.clock")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.royalBlue)
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(Color.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(systemName: message.isBriefingExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(14)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                        .strokeBorder(Color.royalBlue.opacity(0.35), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Inline Chips

    private var inlineChips: some View {
        FlowLayout {
            ForEach(message.nodes) { node in
                Text(node.displayText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.royalBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Color.royalBlue.opacity(0.1),
                        in: Capsule()
                    )
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Expanded Briefing

    private func expandedBriefing(_ briefing: Briefing) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            briefingSection("People to Know", icon: "person.fill", items: briefing.peopleContext)
            briefingSection("Decisions", icon: "checkmark.circle", items: briefing.relevantDecisions)
            briefingSection("Open Questions", icon: "questionmark.circle", items: briefing.openQuestions)
        }
        .padding(14)
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func briefingSection(_ title: String, icon: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.royalBlue)
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Bubble Shape

private struct BubbleShape: Shape {
    let isUser: Bool

    nonisolated func path(in rect: CGRect) -> Path {
        let r: CGFloat = 20
        let corners: UIRectCorner = isUser
            ? [.topLeft, .topRight, .bottomLeft]
            : [.topLeft, .topRight, .bottomRight]
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: r, height: r)
        )
        return Path(path.cgPath)
    }
}

#Preview {
    ScrollView {
        VStack(spacing: 16) {
            ForEach(ChatMessage.sampleConversation) { msg in
                MessageBubble(message: msg)
            }
        }
        .padding()
    }
    .background(Color.canvas)
    .preferredColorScheme(.dark)
}
