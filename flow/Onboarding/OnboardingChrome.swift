//
//  OnboardingChrome.swift
//  flow
//

import SwiftUI

struct OnboardingProgressBar: View {
    let fraction: Double
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.textSecondary)
                    .accessibilityLabel("Setup progress \(label)")
                Spacer()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.textSecondary.opacity(0.15))
                    Capsule()
                        .fill(Color.royalBlue)
                        .frame(width: max(4, geo.size.width * fraction))
                }
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
    }
}

struct OnboardingStepLayout<Content: View>: View {
    let title: String
    let subtitle: String
    var showsBack: Bool = true
    let onBack: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color.textPrimary)
                    Text(subtitle)
                        .font(.body)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                content
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .safeAreaInset(edge: .top) {
            if showsBack {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, 8)
            }
        }
    }
}

struct OnboardingPrimaryButton: View {
    let title: String
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.headline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .foregroundStyle(.white)
                .background(disabled ? Color.textSecondary.opacity(0.35) : Color.royalBlue, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}

struct OnboardingSecondaryButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}

private let onboardingSpring = Animation.spring(response: 0.45, dampingFraction: 0.86)

extension Animation {
    static var onboardingStep: Animation { onboardingSpring }
}
