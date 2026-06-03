//
//  DispatchCardView.swift
//  flow
//
//  Reusable card for a single dispatch. Renders all lifecycle states
//  (pending → approved/building → completed/failed) and surfaces the approve /
//  discard / retry actions for pending cards.
//

import SwiftUI

struct DispatchCardView: View {
    let card: DispatchCard
    let showAutoBuild: Bool
    let onApprove: (String) -> Void   // "auto" or "mcp"
    let onDiscard: () -> Void
    let onRetryAsQueue: () -> Void

    @Environment(\.openURL) private var openURL
    @State private var actionInFlight = false

    /// Complexity hint for which approve action to emphasise. Visual only — the
    /// user can always pick either action.
    private var primaryHighlight: String? { card.complexity }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.featureLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.textPrimary)

            if let summary = card.featureSummary, !summary.isEmpty {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }

            statusRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.screenPadding)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .shadow(color: .black.opacity(0.04), radius: 4, x: 0, y: 2)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch card.status {
        case "pending":
            pendingButtons

        case "approved" where card.mode == "mcp":
            Label("Queued for developer", systemImage: "clock")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

        case "approved":
            Label("Approved", systemImage: "checkmark")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)

        case "building":
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Building…")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

        case "completed":
            HStack(spacing: 10) {
                Label("PR opened", systemImage: "checkmark.circle.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                if let urlStr = card.prUrl,
                   urlStr.hasPrefix("http://") || urlStr.hasPrefix("https://"),
                   let url = URL(string: urlStr) {
                    Button("View PR") {
                        Haptics.light()
                        openURL(url)
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.royalBlue)
                }
            }

        case "failed":
            VStack(alignment: .leading, spacing: 6) {
                if let err = card.error, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(2)
                }
                Button {
                    Haptics.light()
                    onRetryAsQueue()
                } label: {
                    Text("Retry as queue")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.royalBlue)
                }
            }

        default:
            EmptyView()
        }
    }

    private var pendingButtons: some View {
        HStack(spacing: 8) {
            if showAutoBuild {
                actionButton(
                    label: "Auto-build",
                    icon: "bolt.fill",
                    highlighted: primaryHighlight == "simple" || primaryHighlight == nil
                ) {
                    onApprove("auto")
                }
            }

            actionButton(
                label: "Queue",
                icon: "tray.and.arrow.down",
                highlighted: !showAutoBuild || primaryHighlight == "complex"
            ) {
                onApprove("mcp")
            }

            Spacer()

            Button {
                Haptics.light()
                actionInFlight = true
                onDiscard()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .frame(width: 28, height: 28)
                    .background(Color.textSecondary.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(actionInFlight)
        }
    }

    private func actionButton(
        label: String,
        icon: String,
        highlighted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            Haptics.light()
            actionInFlight = true
            action()
        } label: {
            Label(label, systemImage: icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(highlighted ? .white : Color.royalBlue)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(highlighted ? Color.royalBlue : Color.royalBlue.opacity(0.1))
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(actionInFlight)
    }
}
