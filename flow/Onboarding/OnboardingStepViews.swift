//
//  OnboardingStepViews.swift
//  flow
//

import AVFoundation
import SafariServices
import Speech
import SwiftData
import SwiftUI

// MARK: - Welcome

struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            LiquidGlassOrb(size: 120, isActive: false)
                .padding(.bottom, 32)
            VStack(alignment: .leading, spacing: 20) {
                Text("Hear. Review. Sync.")
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(Color.textPrimary)
                bullet("Hear", "Capture conversations on your phone or Penlo wearable.")
                bullet("Review", "Approve facts in your Staging Vault before they leave the device.")
                bullet("Sync", "Approved memories flow to your company's Enterprise Brain.")
            }
            .padding(.horizontal, 24)
            Spacer()
            OnboardingPrimaryButton(title: "Continue", action: onContinue)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
    }

    private func bullet(_ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(Color.royalBlue)
                .frame(width: 56, alignment: .leading)
            Text(detail)
                .font(.body)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

// MARK: - Path

struct OnboardingPathStep: View {
    @Binding var selected: SetupState.UserPath?
    let onContinue: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "How are you joining?",
            subtitle: "We'll tailor setup for invited teammates and company admins.",
            showsBack: false,
            onBack: {}
        ) {
            VStack(spacing: 12) {
                pathCard(
                    path: .invited,
                    title: "My team invited me",
                    detail: "Paste your Brain URL and pb_live_ key from the web dashboard."
                )
                pathCard(
                    path: .selfServe,
                    title: "I'm setting up Penlo for my company",
                    detail: "Create your company on the web, then return here to pair Flow."
                )
            }
            OnboardingPrimaryButton(title: "Continue", disabled: selected == nil, action: onContinue)
        }
    }

    private func pathCard(path: SetupState.UserPath, title: String, detail: String) -> some View {
        let isSelected = selected == path
        return Button {
            Haptics.light()
            selected = path
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isSelected ? Color.royalBlue : Color.textSecondary.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
            .background(isSelected ? Color.royalBlue.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Web signup

struct OnboardingWebSignupStep: View {
    @State private var showSafari = false

    var body: some View {
        OnboardingStepLayout(
            title: "Create your company",
            subtitle: "Open the Penlo web dashboard to sign up. When you have your Connect App key, return to Flow to pair.",
            showsBack: true,
            onBack: {}
        ) {
            OnboardingPrimaryButton(title: "Open web signup") {
                showSafari = true
            }
            Link(destination: PenloConfig.connectURL) {
                Text("Already have a key? Get it on Connect App")
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

struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }
    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

// MARK: - Account

struct OnboardingAccountStep: View {
    @Binding var email: String
    @Binding var displayName: String
    let onContinue: () -> Void

    private var canContinue: Bool {
        email.contains("@") && email.contains(".")
    }

    var body: some View {
        OnboardingStepLayout(
            title: "Your account",
            subtitle: "We attach this email to every memory synced to Enterprise Brain.",
            showsBack: true,
            onBack: {}
        ) {
            TextField("you@company.com", text: $email)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.emailAddress)
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            TextField("Display name (optional)", text: $displayName)
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            OnboardingPrimaryButton(title: "Continue", disabled: !canContinue) {
                KeychainStore.saveUserEmail(email.trimmingCharacters(in: .whitespacesAndNewlines))
                UserDefaults.standard.set(email, forKey: "userEmail")
                let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty {
                    UserDefaults.standard.set(name, forKey: "userName")
                }
                onContinue()
            }
        }
    }
}

// MARK: - Enterprise Brain

struct OnboardingBrainStep: View {
    @Binding var brainURL: String
    @Binding var brainKey: String
    var clipboardKey: String?
    var onApplyClipboard: () -> Void
    var brainSyncer: EnterpriseBrainSyncer
    let onContinue: () -> Void
    let onSkip: () -> Void
    @State private var testState: BrainTestUIState = .idle

    private enum BrainTestUIState: Equatable {
        case idle, testing, success, failure(String)
    }

    var body: some View {
        OnboardingStepLayout(
            title: "Enterprise Brain",
            subtitle: "Paste your ingest URL and pb_live_ API key from the web Connect App.",
            showsBack: true,
            onBack: {}
        ) {
            if let clipboardKey {
                Button {
                    onApplyClipboard()
                    brainKey = clipboardKey
                    Haptics.light()
                } label: {
                    HStack {
                        Image(systemName: "doc.on.clipboard.fill")
                        Text("Paste key from clipboard")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.royalBlue)
                    .frame(maxWidth: .infinity)
                    .padding(12)
                    .background(Color.royalBlue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .buttonStyle(.plain)
            }

            TextField("Brain URL", text: $brainURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            SecureField("pb_live_…", text: $brainKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Link(destination: PenloConfig.connectURL) {
                Text("Get key on web → Connect App")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.royalBlue)
            }

            OnboardingPrimaryButton(
                title: testState == .testing ? "Testing…" : "Test Connection",
                disabled: brainURL.trimmingCharacters(in: .whitespaces).isEmpty
                    || brainKey.trimmingCharacters(in: .whitespaces).isEmpty
                    || testState == .testing
            ) {
                saveBrainConfig()
                testConnection()
            }

            if case .success = testState {
                Label("Connected — Brain accepted test payload.", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if case .failure(let msg) = testState {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            OnboardingPrimaryButton(
                title: "Continue",
                disabled: testState != .success,
                action: onContinue
            )

            OnboardingSecondaryButton(title: "Set up later — sync queued locally") {
                saveBrainConfig()
                SetupState.markBrainSkipped()
                onSkip()
            }
        }
        .onAppear {
            #if DEBUG
            if brainURL.isEmpty {
                if let host = PenloConfig.webBaseURL.host {
                    brainURL = "http://\(host):8000"
                } else {
                    brainURL = "http://localhost:8000"
                }
            }
            #endif
        }
    }

    private func saveBrainConfig() {
        let trimmedURL = brainURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalized = EnterpriseBrainSyncer.normalizedBrainURL(trimmedURL)?.absoluteString {
            KeychainStore.saveBrainURL(normalized)
            brainURL = normalized
        } else {
            KeychainStore.saveBrainURL(trimmedURL)
        }
        KeychainStore.saveBrainKey(brainKey.trimmingCharacters(in: .whitespacesAndNewlines))
        NotificationCenter.default.post(name: .brainCredentialsSaved, object: nil)
    }

    private func testConnection() {
        saveBrainConfig()
        testState = .testing
        Task {
            let result = await brainSyncer.testConnection()
            if result.ok {
                testState = .success
                SetupState.markBrainTestSuccess()
                Haptics.success()
            } else {
                testState = .failure(result.detail)
                Haptics.medium()
            }
        }
    }

}

// MARK: - Claude

struct OnboardingClaudeStep: View {
    @Binding var apiKey: String
    @State private var verifyState: VerifyUIState = .idle

    private enum VerifyUIState: Equatable {
        case idle, verifying, success, failure(String)
    }

    let onVerified: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Claude API key",
            subtitle: "On-device extraction and chat use your Anthropic key. Stored in Keychain on this device.",
            showsBack: true,
            onBack: {}
        ) {
            SecureField("sk-ant-…", text: $apiKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(14)
                .background(Color.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            OnboardingPrimaryButton(
                title: verifyState == .verifying ? "Verifying…" : "Verify key",
                disabled: apiKey.trimmingCharacters(in: .whitespaces).isEmpty || verifyState == .verifying
            ) {
                verify()
            }

            if case .success = verifyState {
                Label("Verified", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            }
            if case .failure(let msg) = verifyState {
                Text(msg).font(.caption).foregroundStyle(.red)
            }

            OnboardingPrimaryButton(title: "Continue", disabled: verifyState != .success, action: onVerified)

            Text("Skipping blocks AI chat and extraction until you add a key in Settings.")
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
        }
    }

    private func verify() {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        verifyState = .verifying
        Task {
            do {
                try KeychainStore.saveAPIKey(trimmed)
                try await ClaudeService.shared.verify(apiKey: trimmed)
                verifyState = .success
                Haptics.success()
            } catch let error as ClaudeService.ServiceError {
                verifyState = .failure(error.userFacingMessage)
            } catch {
                verifyState = .failure(error.localizedDescription)
            }
        }
    }
}

// MARK: - Microphone

struct OnboardingMicrophoneStep: View {
    @State private var permissionGranted = false
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Microphone",
            subtitle: "Penlo only listens when you tap the mic. Speech is processed on-device.",
            showsBack: true,
            onBack: {}
        ) {
            Image(systemName: "mic.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(Color.royalBlue)
                .frame(maxWidth: .infinity)
            OnboardingPrimaryButton(title: "Enable microphone") {
                Task { await requestMic() }
            }
            if permissionGranted {
                OnboardingPrimaryButton(title: "Continue", action: onContinue)
            }
            OnboardingSecondaryButton(title: "Set up later", action: onSkip)
        }
    }

    private func requestMic() async {
        let session = AVAudioSession.sharedInstance()
        let granted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            session.requestRecordPermission { cont.resume(returning: $0) }
        }
        if granted {
            let speechGranted = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    cont.resume(returning: status == .authorized)
                }
            }
            permissionGranted = speechGranted
            if speechGranted {
                Haptics.success()
                onContinue()
            }
        }
    }
}

// MARK: - Practice

struct OnboardingPracticeStep: View {
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Try a quick capture",
            subtitle: "Optional: record ~15 seconds, then see how extraction works. You can skip and capture later from chat.",
            showsBack: true,
            onBack: {}
        ) {
            Text("Tap the mic on the home screen after setup to start your first real capture.")
                .font(.body)
                .foregroundStyle(Color.textSecondary)
            OnboardingSecondaryButton(title: "Skip for now", action: onSkip)
            OnboardingPrimaryButton(title: "Continue", action: onContinue)
        }
    }
}

// MARK: - Vault intro

struct OnboardingVaultIntroStep: View {
    @Environment(\.modelContext) private var modelContext
    @Query(filter: #Predicate<Transcript> { $0.isOnboardingSample && !$0.isSynced })
    private var samples: [Transcript]

    @State private var expandedSampleID: UUID?
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Staging Vault",
            subtitle: "Nothing syncs until you approve. Review extracted facts, edit if needed, then approve or discard.",
            showsBack: true,
            onBack: {}
        ) {
            if let sample = samples.first {
                MemoryBlockCard(
                    transcript: sample,
                    isExpanded: expandedSampleID == sample.id,
                    onToggle: {
                        expandedSampleID = expandedSampleID == sample.id ? nil : sample.id
                    },
                    onSync: {
                        SetupState.markVaultIntroSeen()
                        onContinue()
                    },
                    onDiscard: {
                        modelContext.delete(sample)
                        try? modelContext.save()
                        SetupState.markVaultIntroSeen()
                        onSkip()
                    },
                    onRemoveItem: { _, _ in }
                )
            } else {
                Text("Sample memory will appear here.")
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
            }
            OnboardingSecondaryButton(title: "Skip sample", action: {
                SetupState.markVaultIntroSeen()
                onSkip()
            })
            OnboardingPrimaryButton(title: "Continue", action: {
                SetupState.markVaultIntroSeen()
                onContinue()
            })
        }
        .onAppear {
            PenloStore.seedOnboardingSampleIfNeeded(in: modelContext)
            if let id = samples.first?.id {
                expandedSampleID = id
            }
        }
    }
}

// MARK: - Briefings

struct OnboardingBriefingsStep: View {
    let calendarManager: CalendarManager
    let onContinue: () -> Void
    let onSkip: () -> Void

    var body: some View {
        OnboardingStepLayout(
            title: "Briefings & alerts",
            subtitle: "Optional: calendar access for pre-meeting briefings; notifications for dispatch and sync status.",
            showsBack: true,
            onBack: {}
        ) {
            OnboardingPrimaryButton(title: "Enable") {
                Task {
                    _ = await calendarManager.requestAccess()
                    let granted = await NotificationManager.shared.requestAuthorization()
                    SetupState.setBriefingsOptIn(granted)
                    if granted {
                        await MainActor.run {
                            UIApplication.shared.registerForRemoteNotifications()
                        }
                    }
                    onContinue()
                }
            }
            OnboardingSecondaryButton(title: "Not now", action: {
                SetupState.skipStep("briefings")
                onSkip()
            })
        }
    }
}

// MARK: - Done

struct OnboardingDoneStep: View {
    let onEnter: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.royalBlue)
            Text("You're ready")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(Color.textPrimary)
            VStack(alignment: .leading, spacing: 10) {
                checklistRow("Capture on Flow", done: true)
                checklistRow("Review in Staging Vault", done: SetupState.sawVaultIntro)
                checklistRow("Ask & graph on web", done: SetupState.hasBrainConfigured)
            }
            .padding(.horizontal, 32)
            Link(destination: PenloConfig.webBaseURL) {
                Text("Open Company Brain on web")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.royalBlue)
            }
            Spacer()
            OnboardingPrimaryButton(title: "Enter Penlo", action: onEnter)
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas.ignoresSafeArea())
    }

    private func checklistRow(_ text: String, done: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : Color.textSecondary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Color.textPrimary)
        }
    }
}
