//
//  SetupProgressBanner.swift
//  flow
//

import SwiftUI

struct SetupProgressBanner: View {
    let onTap: () -> Void

    private var nudges: [SetupState.OptionalNudge] {
        SetupState.incompleteOptionalNudges
    }

    var body: some View {
        if SetupState.isOnboardingComplete, !nudges.isEmpty, let first = nudges.first {
            Button(action: onTap) {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.fill")
                        .foregroundStyle(Color.royalBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bannerTitle(for: first))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        Text("Tap to open setup guide")
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(14)
                .background(Color.royalBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 24)
        }
    }

    private func bannerTitle(for nudge: SetupState.OptionalNudge) -> String {
        switch nudge {
        case .brainConnectionTest: return "Test Enterprise Brain connection"
        case .microphone: return "Enable microphone for capture"
        case .briefings: return "Turn on briefings & notifications"
        case .wearable: return "Connect Penlo wearable (optional)"
        }
    }
}
