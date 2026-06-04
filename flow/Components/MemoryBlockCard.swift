//
//  MemoryBlockCard.swift
//  flow
//
//  A single captured conversation in the Privacy Review.
//

import SwiftUI

struct MemoryBlockCard: View {
    let transcript: Transcript
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSync: () -> Void
    let onDiscard: () -> Void
    let onRemoveItem: (_ kind: String, _ index: Int) -> Void

    @State private var isSyncing = false
    @State private var showRawTranscript = false

    private var payload: MemoryPayload {
        transcript.payload ?? MemoryPayload(
            title: transcript.displayTitle
        )
    }

    private var hasStructuredContent: Bool {
        !payload.facts.isEmpty || !payload.people.isEmpty || !payload.topicSummary.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            cardHeader
            if isExpanded { expandedContent }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isExpanded ? Color.royalBlue.opacity(0.35) : Color.textPrimary.opacity(0.08),
                    lineWidth: 1
                )
        )
        .onChange(of: isExpanded) { _, expanded in
            if expanded && !hasStructuredContent && !transcript.rawText.isEmpty {
                showRawTranscript = true
            }
        }
    }

    // MARK: - Card Header (Collapsed State)

    private var cardHeader: some View {
        Button {
            onToggle()
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Text(payload.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(isExpanded ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 8)

                    Text(transcript.relativeTimeLabel)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }

                if !isExpanded {
                    collapsedSummary
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Collapsed Summary

    private var collapsedSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                confidenceDot
                Text(summaryLine)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            if let firstFact = payload.facts.first {
                Text(firstFact.displayText)
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            } else if !transcript.rawText.isEmpty {
                Text(transcript.rawText)
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(3)
            }

            if payload.facts.count > 1 {
                Text(payload.facts[1].displayText)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if !payload.facts.isEmpty {
            parts.append("\(payload.facts.count) fact\(payload.facts.count == 1 ? "" : "s")")
        }
        if !payload.people.isEmpty {
            parts.append("\(payload.people.count) \(payload.people.count == 1 ? "person" : "people")")
        }
        if !payload.topicSummary.isEmpty {
            parts.append("\(payload.topicSummary.count) topic\(payload.topicSummary.count == 1 ? "" : "s")")
        }
        if parts.isEmpty, !transcript.rawText.isEmpty {
            return "Transcript captured"
        }
        return parts.isEmpty ? "No extracted details yet" : parts.joined(separator: ", ")
    }

    private var averageConfidence: Float {
        guard !payload.facts.isEmpty else { return 0.75 }
        return payload.facts.reduce(Float(0)) { $0 + $1.confidence } / Float(payload.facts.count)
    }

    private var confidenceDot: some View {
        let color: Color = averageConfidence >= 0.75 ? .green :
                           averageConfidence >= 0.65 ? .yellow : .orange
        let label = averageConfidence >= 0.75 ? "High" :
                    averageConfidence >= 0.65 ? "Moderate" : "Low"
        return HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color.opacity(0.9))
        }
    }

    // MARK: - Expanded Content

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider().overlay(Color.textPrimary.opacity(0.08))
                .padding(.top, 12)

            if !transcript.rawText.isEmpty {
                conversationSection
            }

            if hasStructuredContent {
                syncSectionHeader

                if !payload.facts.isEmpty {
                    factsSection
                }
                if !payload.people.isEmpty {
                    peopleSection
                }
                if !payload.topicSummary.isEmpty {
                    topicsSection
                }
            }

            rawTranscriptSection

            syncFooter
            actionButtons
        }
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
    }

    private var conversationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "text.quote")
                    .font(.caption2)
                    .foregroundStyle(Color.royalBlue)
                Text("What Penlo heard")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            Text(transcript.rawText)
                .font(.subheadline)
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color.textPrimary.opacity(0.04))
                )
        }
    }

    private var syncSectionHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.subheadline)
                .foregroundStyle(Color.royalBlue)
            Text("What will be synced")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.textPrimary)
        }
    }

    // MARK: - Facts Section

    private var factsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "lightbulb.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.royalBlue)
                Text("Facts")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            ForEach(Array(payload.facts.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(fact.displayText)
                            .font(.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)

                        confidenceBadge(for: fact.confidence)
                    }

                    Spacer(minLength: 8)

                    Button {
                        onRemoveItem("facts", index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.textSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func confidenceBadge(for confidence: Float) -> some View {
        let color: Color = confidence >= 0.75 ? .green :
                           confidence >= 0.65 ? .yellow : .orange
        let percent = Int(confidence * 100)
        return Text("\(percent)% confidence")
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - People Section

    private var peopleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "person.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.royalBlue)
                Text("People")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            ForEach(Array(payload.people.enumerated()), id: \.offset) { index, person in
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(person.name)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.textPrimary)

                        if let notes = person.notes, !notes.isEmpty {
                            Text(notes)
                                .font(.caption2)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    Spacer(minLength: 8)

                    Button {
                        onRemoveItem("people", index)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.textSecondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 3)
            }
        }
    }

    // MARK: - Topics Section

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "tag.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.royalBlue)
                Text("Topics")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }

            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                ForEach(Array(payload.topicSummary.enumerated()), id: \.offset) { index, topic in
                    HStack(spacing: 4) {
                        Text(topic)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.royalBlue)

                        Button {
                            onRemoveItem("topics", index)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.royalBlue.opacity(0.6))
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.royalBlue.opacity(0.12), in: Capsule())
                }
            }
        }
    }

    // MARK: - Raw Transcript (Collapsible)

    private var rawTranscriptSection: some View {
        Group {
            if !transcript.rawText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                            showRawTranscript.toggle()
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "doc.text")
                                .font(.caption2)
                                .foregroundStyle(Color.textSecondary)
                            Text("Full transcript")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                            Image(systemName: showRawTranscript ? "chevron.up" : "chevron.down")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(Color.textSecondary.opacity(0.6))
                        }
                    }
                    .buttonStyle(.plain)

                    if showRawTranscript {
                        Text(transcript.rawText)
                            .font(.caption)
                            .foregroundStyle(Color.textPrimary)
                            .padding(10)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.textPrimary.opacity(0.04))
                            )
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
            }
        }
    }

    // MARK: - Sync Footer

    private var syncFooter: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.caption2)
                .foregroundStyle(Color.textSecondary.opacity(0.8))
            Text("This will be sent to your Enterprise Brain")
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                onDiscard()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.caption.weight(.semibold))
                    Text("Discard")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.red.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Color.red.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)

            Button {
                guard !isSyncing else { return }
                isSyncing = true
                Haptics.light()
                onSync()
            } label: {
                HStack(spacing: 6) {
                    if isSyncing {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.75)
                    } else {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                        Text("Approve")
                            .font(.subheadline.weight(.bold))
                    }
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(
                    Color.royalBlue.opacity(isSyncing ? 0.5 : 1.0),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }
            .buttonStyle(.plain)
            .disabled(isSyncing)
        }
        .padding(.top, 4)
    }
}

#Preview {
    let payload = MemoryPayload(
        title: "Standup with Nolan",
        facts: [
            PenloFact(subject: "Enterprise Sync", predicate: "is shipping", object: "before offsite", confidence: 0.82, capturedAt: ""),
            PenloFact(subject: "BLE pairing", predicate: "has", object: "reliability issues", confidence: 0.68, capturedAt: "")
        ],
        people: [PenloPerson(name: "Nolan Carroll", notes: "Product lead"), PenloPerson(name: "Marcus Lee")],
        topicSummary: ["Q3 Roadmap", "BLE Reliability"]
    )
    ZStack {
        Color.canvas.ignoresSafeArea()
        VStack(spacing: 20) {
            MemoryBlockCard(
                transcript: {
                    let t = Transcript(
                        rawText: "Reviewed the Q3 roadmap and aligned on shipping Enterprise Sync before the offsite. BLE pairing has reliability issues on v2.1 firmware.",
                        payloadData: try? JSONEncoder().encode(payload)
                    )
                    return t
                }(),
                isExpanded: false,
                onToggle: {},
                onSync: {},
                onDiscard: {},
                onRemoveItem: { _, _ in }
            )
            MemoryBlockCard(
                transcript: {
                    let t = Transcript(
                        rawText: "Reviewed the Q3 roadmap and aligned on shipping Enterprise Sync before the offsite. BLE pairing has reliability issues on v2.1 firmware.",
                        payloadData: try? JSONEncoder().encode(payload)
                    )
                    return t
                }(),
                isExpanded: true,
                onToggle: {},
                onSync: {},
                onDiscard: {},
                onRemoveItem: { _, _ in }
            )
        }
        .padding()
    }
}
