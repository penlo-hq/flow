//
//  OnboardingFlowView.swift
//  flow
//

import SwiftData
import SwiftUI

struct OnboardingFlowView: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var coordinator: OnboardingCoordinator
    var brainSyncer: EnterpriseBrainSyncer
    let onFinished: () -> Void

    @State private var selectedPath: SetupState.UserPath?
    @State private var email = ""
    @State private var displayName = ""
    @State private var brainURL = ""
    @State private var brainKey = ""
    @State private var apiKey = ""

    private let calendarManager = CalendarManager()

    var body: some View {
        VStack(spacing: 0) {
            if coordinator.currentStep != .welcome && coordinator.currentStep != .done {
                OnboardingProgressBar(
                    fraction: coordinator.progressFraction,
                    label: coordinator.progressLabel
                )
            }

            stepContent
                .id(coordinator.currentStep.id)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .leading).combined(with: .opacity)
                ))
        }
        .animation(.onboardingStep, value: coordinator.stepIndex)
        .background(Color.canvas.ignoresSafeArea())
        .onAppear {
            loadInitialValues()
            coordinator.rebuildSteps()
            if coordinator.isReplayFromSettings {
                coordinator.stepIndex = 0
            }
        }
        .onChange(of: coordinator.currentStep) { _, step in
            if step == .enterpriseBrain {
                coordinator.scanClipboardForKey()
            }
        }
    }

    @ViewBuilder
    private var stepContent: some View {
        switch coordinator.currentStep {
        case .welcome:
            OnboardingWelcomeStep { coordinator.advance() }

        case .pathPicker:
            OnboardingPathStep(selected: $selectedPath) {
                guard let path = selectedPath else { return }
                coordinator.selectPath(path)
            }

        case .webSignup:
            OnboardingWebSignupStepWithBack(onBack: coordinator.goBack) {
                coordinator.advance()
            }

        case .account:
            OnboardingAccountStep(
                email: $email,
                displayName: $displayName,
                onContinue: { coordinator.advance() }
            )
            .onAppear { /* back wired below */ }

        case .enterpriseBrain:
            OnboardingBrainStep(
                brainURL: $brainURL,
                brainKey: $brainKey,
                clipboardKey: coordinator.clipboardKeyOffer,
                onApplyClipboard: { coordinator.applyClipboardKey(to: &brainKey) },
                brainSyncer: brainSyncer,
                onContinue: { coordinator.advance() },
                onSkip: { coordinator.skipCurrentStep() }
            )

        case .claude:
            OnboardingClaudeStep(apiKey: $apiKey, onVerified: { coordinator.advance() })

        case .microphone:
            OnboardingMicrophoneStep(
                onContinue: { coordinator.advance() },
                onSkip: { coordinator.skipCurrentStep() }
            )

        case .practiceCapture:
            OnboardingPracticeStep(
                onContinue: { coordinator.advance() },
                onSkip: { coordinator.skipCurrentStep() }
            )

        case .vaultIntro:
            OnboardingVaultIntroStep(
                onContinue: { coordinator.advance() },
                onSkip: { coordinator.skipCurrentStep() }
            )

        case .briefings:
            OnboardingBriefingsStep(
                calendarManager: calendarManager,
                onContinue: { coordinator.advance() },
                onSkip: { coordinator.skipCurrentStep() }
            )

        case .done:
            OnboardingDoneStep {
                coordinator.finishOnboarding()
                onFinished()
            }
        }
    }

    private func loadInitialValues() {
        email = KeychainStore.readUserEmail() ?? ""
        displayName = UserDefaults.standard.string(forKey: "userName") ?? ""
        brainURL = KeychainStore.readBrainURL() ?? ""
        brainKey = KeychainStore.readBrainKey() ?? ""
        apiKey = KeychainStore.readAPIKey() ?? ""
        selectedPath = SetupState.userPath
        coordinator.userPath = selectedPath
    }
}

/// Web signup with back navigation wired to coordinator.
private struct OnboardingWebSignupStepWithBack: View {
    let onBack: () -> Void
    let onContinue: () -> Void
    @State private var showSafari = false

    var body: some View {
        OnboardingStepLayout(
            title: "Create your company",
            subtitle: "Open the Penlo web dashboard to sign up. When you have your Connect App key, return to Flow to pair.",
            showsBack: true,
            onBack: onBack
        ) {
            OnboardingPrimaryButton(title: "Open web signup") { showSafari = true }
            OnboardingPrimaryButton(title: "I've created my account", action: onContinue)
            OnboardingSecondaryButton(title: "Skip for now", action: onContinue)
            Link(destination: PenloConfig.connectURL) {
                Text("Get key on Connect App")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.royalBlue)
            }
        }
        .sheet(isPresented: $showSafari) {
            SafariView(url: PenloConfig.signupURL)
                .ignoresSafeArea()
        }
    }
}
