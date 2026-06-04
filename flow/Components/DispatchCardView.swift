//
//  DispatchCardView.swift
//  flow
//
//  Single dispatch card — all lifecycle states and actions.
//

import SwiftUI

struct DispatchCardView: View {
    let card: DispatchCard
    let showAutoBuild: Bool
    var autoBuildDisabledReason: String? = nil
    let performingAction: DispatchCardAction
    let onApprove: (String) -> Void
    let onDiscard: () -> Void
    let onRetryAsQueue: () -> Void
    let onRetryAuto: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var contextExpanded = false
    @State private var briefExpanded = false
    @State private var traceExpanded = false

    private var isBusy: Bool {
        performingAction != .idle
    }

    private var primaryHighlight: String? { card.complexity }

    private var hasContext: Bool {
        (card.detail != nil && !(card.detail?.isEmpty ?? true))
        || !(card.acceptanceCriteria?.isEmpty ?? true)
        || !(card.relatedPeople?.isEmpty ?? true)
        || !(card.relatedDecisions?.isEmpty ?? true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            metaRow

            if let summary = card.featureSummary, !summary.isEmpty {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let repo = card.githubRepo, !repo.isEmpty, card.status != "pending" {
                Label("\(repo) · \(card.githubBaseBranch ?? "main")", systemImage: "link")
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
            }

            if card.status == "pending" && hasContext {
                contextSection
            }

            if card.status == "pending", let brief = card.buildBriefPreview, !brief.isEmpty {
                buildBriefSection(brief)
            }

            if isBusy, let label = busyLabel {
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.85)
                    Text(label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                }
            }

            statusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.screenPadding)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 6, x: 0, y: 2)
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(card.featureLabel)
                .font(.headline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            statusBadge
        }
    }

    private var statusBadge: some View {
        let (label, color, icon): (String, Color, String) = {
            switch card.status {
            case "pending": return ("Needs approval", .orange, "tray.fill")
            case "approved" where card.mode == "mcp": return ("Queued", .royalBlue, "clock.fill")
            case "approved": return ("Approved", .royalBlue, "checkmark")
            case "building": return ("Building", .purple, "hammer.fill")
            case "completed": return ("Done", .green, "checkmark.circle.fill")
            case "failed": return ("Failed", .red, "xmark.circle.fill")
            default: return (card.status, Color.textSecondary, "circle")
            }
        }()
        return Label(label, systemImage: icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var metaRow: some View {
        HStack(spacing: 12) {
            if let nodeType = card.nodeType, !nodeType.isEmpty {
                typeBadge(nodeType)
            }
            if let source = card.source, !source.isEmpty {
                Text(source)
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
            Spacer()
            Text(DispatchFormatting.relativeTime(iso: card.createdAt))
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private var busyLabel: String? {
        switch performingAction {
        case .approving("auto"): return "Starting auto-build…"
        case .approving: return "Submitting…"
        case .discarding: return "Discarding…"
        case .idle: return nil
        }
    }

    // MARK: - Type badge

    private func typeBadge(_ nodeType: String) -> some View {
        let label = nodeType.prefix(1).uppercased() + nodeType.dropFirst()
        let isTask = nodeType == "task"
        return Label(label, systemImage: isTask ? "bolt.fill" : "sparkles")
            .font(.caption2.weight(.medium))
            .foregroundStyle(isTask ? Color.orange : Color.purple)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((isTask ? Color.orange : Color.purple).opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    // MARK: - Collapsible context

    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    contextExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(contextExpanded ? "Hide context" : "Show context")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                    Image(systemName: contextExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                }
            }
            .buttonStyle(.plain)

            if contextExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    if let detail = card.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if let criteria = card.acceptanceCriteria, !criteria.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("ACCEPTANCE CRITERIA")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                                .tracking(0.5)

                            ForEach(Array(criteria.enumerated()), id: \.offset) { _, criterion in
                                HStack(alignment: .top, spacing: 6) {
                                    Circle()
                                        .fill(Color.royalBlue)
                                        .frame(width: 4, height: 4)
                                        .padding(.top, 5)
                                    Text(criterion)
                                        .font(.caption)
                                        .foregroundStyle(Color.textSecondary)
                                }
                            }
                        }
                    }

                    if let people = card.relatedPeople, !people.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("PEOPLE INVOLVED")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                                .tracking(0.5)

                            FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                                ForEach(Array(people.enumerated()), id: \.offset) { _, person in
                                    Label(person.label, systemImage: "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(Color.textSecondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color.textSecondary.opacity(0.08))
                                        .clipShape(Capsule())
                                }
                            }
                        }
                    }

                    if let decisions = card.relatedDecisions, !decisions.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("RELATED DECISIONS")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                                .tracking(0.5)

                            ForEach(Array(decisions.enumerated()), id: \.offset) { _, decision in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(decision.label)
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(Color.textSecondary)
                                    if let detail = decision.detail, !detail.isEmpty {
                                        Text(detail)
                                            .font(.caption2)
                                            .foregroundStyle(Color.textSecondary.opacity(0.7))
                                            .lineLimit(3)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(Color.royalBlue.opacity(0.2))
                        .frame(width: 2)
                }
            }
        }
    }

    private func buildBriefSection(_ brief: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    briefExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                    Text(briefExpanded ? "Hide build plan" : "What the agent will build")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                    Image(systemName: briefExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                }
            }
            .buttonStyle(.plain)

            if briefExpanded {
                Text(brief)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 8)
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(Color.royalBlue.opacity(0.2))
                            .frame(width: 2)
                    }
            }
        }
    }

    // MARK: - Status row

    @ViewBuilder
    private var statusRow: some View {
        if card.status == "pending" {
            Text(DispatchFormatting.expiresLabel(iso: card.expiresAt))
                .font(.caption2)
                .foregroundStyle(Color.textSecondary)
        }

        switch card.status {
        case "pending":
            pendingButtons

        case "approved" where card.mode == "mcp":
            Label("Waiting for developer pickup", systemImage: "person.fill")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

        case "approved":
            Label("Approved — awaiting build", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

        case "building":
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("Agent is building…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.textSecondary)
            }

        case "completed":
            HStack(spacing: 12) {
                Label("Pull request opened", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                if let url = prURL {
                    Button {
                        Haptics.light()
                        openURL(url)
                    } label: {
                        Label("View PR", systemImage: "arrow.up.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.royalBlue)
                    }
                    .buttonStyle(.plain)
                }
            }

        case "failed":
            failedSection

        default:
            EmptyView()
        }
    }

    private var prURL: URL? {
        guard let urlStr = card.prUrl,
              urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://") else { return nil }
        return URL(string: urlStr)
    }

    private var failedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let err = card.error, !err.isEmpty {
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let trace = card.executionTrace, !trace.isEmpty {
                traceSection(trace)
            }

            if !isBusy {
                HStack(spacing: 10) {
                    Button {
                        Haptics.light()
                        onRetryAsQueue()
                    } label: {
                        Label("Retry as queue", systemImage: "tray.and.arrow.down")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.royalBlue)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color.royalBlue.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    if showAutoBuild {
                        Button {
                            Haptics.light()
                            onRetryAuto()
                        } label: {
                            Label("Retry auto-build", systemImage: "bolt.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .background(Color.royalBlue, in: Capsule())
                        }
                        .buttonStyle(.plain)
                        .disabled(autoBuildDisabledReason != nil)
                    }
                }
            }
        }
    }

    private func traceSection(_ trace: [DispatchExecutionTraceEntry]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    traceExpanded.toggle()
                }
            } label: {
                HStack(spacing: 4) {
                    Text(traceExpanded ? "Hide execution trace" : "Show execution trace")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.textSecondary)
                    Image(systemName: traceExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .buttonStyle(.plain)

            if traceExpanded {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(trace.enumerated()), id: \.offset) { _, entry in
                        HStack(alignment: .top, spacing: 4) {
                            Text(entry.tool)
                                .font(.system(.caption2, design: .monospaced).weight(.medium))
                                .foregroundStyle(Color.textSecondary)
                            Text(entry.result ?? "")
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(Color.textSecondary.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                }
                .padding(.leading, 8)
            }
        }
    }

    // MARK: - Pending actions

    private var pendingButtons: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if showAutoBuild {
                    actionButton(
                        label: "Auto-build",
                        icon: "bolt.fill",
                        highlighted: primaryHighlight != "complex",
                        enabled: !isBusy && autoBuildDisabledReason == nil
                    ) {
                        onApprove("auto")
                    }
                }

                actionButton(
                    label: "Queue for dev",
                    icon: "tray.and.arrow.down",
                    highlighted: !showAutoBuild || primaryHighlight == "complex",
                    enabled: !isBusy
                ) {
                    onApprove("mcp")
                }

                Spacer()

                Button {
                    Haptics.light()
                    onDiscard()
                } label: {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.textSecondary)
                        .frame(width: 36, height: 36)
                        .background(Color.textSecondary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .accessibilityLabel("Discard")
            }

            if showAutoBuild, let reason = autoBuildDisabledReason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func actionButton(
        label: String,
        icon: String,
        highlighted: Bool,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlighted && enabled ? .white : Color.royalBlue)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(
                    highlighted && enabled
                        ? Color.royalBlue
                        : Color.royalBlue.opacity(enabled ? 0.12 : 0.06),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}
