//
//  OnboardingCoordinator.swift
//  flow
//

import Observation
import SwiftUI
import UIKit

enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case pathPicker
    case webSignup
    case account
    case enterpriseBrain
    case claude
    case microphone
    case practiceCapture
    case vaultIntro
    case briefings
    case done

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Welcome"
        case .pathPicker: return "Your path"
        case .webSignup: return "Create account"
        case .account: return "Account"
        case .enterpriseBrain: return "Enterprise Brain"
        case .claude: return "Claude"
        case .microphone: return "Microphone"
        case .practiceCapture: return "Practice"
        case .vaultIntro: return "Staging Vault"
        case .briefings: return "Briefings"
        case .done: return "Ready"
        }
    }
}

@Observable
@MainActor
final class OnboardingCoordinator {

    var steps: [OnboardingStep] = [.welcome]
    var stepIndex: Int = 0
    var userPath: SetupState.UserPath?
    var clipboardKeyOffer: String?
    var isReplayFromSettings = false

    var currentStep: OnboardingStep {
        guard stepIndex >= 0, stepIndex < steps.count else { return .welcome }
        return steps[stepIndex]
    }

    var progressFraction: Double {
        guard steps.count > 1 else { return 0 }
        return Double(stepIndex) / Double(steps.count - 1)
    }

    var progressLabel: String {
        "\(min(stepIndex + 1, steps.count)) of \(steps.count)"
    }

    func rebuildSteps() {
        var list: [OnboardingStep] = [.welcome, .pathPicker]
        if userPath == .selfServe {
            list.append(.webSignup)
        }
        list += [.account, .enterpriseBrain, .claude, .microphone, .practiceCapture, .vaultIntro, .briefings, .done]
        steps = list
        stepIndex = min(stepIndex, max(0, steps.count - 1))
    }

    func selectPath(_ path: SetupState.UserPath) {
        userPath = path
        SetupState.setUserPath(path)
        rebuildSteps()
        if currentStep == .pathPicker {
            advance()
        }
    }

    func advance() {
        guard stepIndex < steps.count - 1 else { return }
        stepIndex += 1
        if currentStep == .enterpriseBrain {
            scanClipboardForKey()
        }
    }

    func goBack() {
        guard stepIndex > 0 else { return }
        stepIndex -= 1
    }

    func skipCurrentStep() {
        switch currentStep {
        case .enterpriseBrain:
            SetupState.markBrainSkipped()
        case .microphone:
            SetupState.skipStep("microphone")
        case .practiceCapture:
            SetupState.skipStep("practiceCapture")
        case .vaultIntro:
            SetupState.markVaultIntroSeen()
        case .briefings:
            SetupState.skipStep("briefings")
        default:
            break
        }
        advance()
    }

    func finishOnboarding() {
        SetupState.markOnboardingComplete()
    }

    func scanClipboardForKey() {
        #if os(iOS)
        let pasteboard = UIPasteboard.general.string
        clipboardKeyOffer = SetupState.extractLiveKey(from: pasteboard)
        #endif
    }

    func applyClipboardKey(to binding: inout String) {
        if let key = clipboardKeyOffer {
            binding = key
            clipboardKeyOffer = nil
        }
    }

    /// Deep link: penlo://setup?url=...&key=...&email=...
    func applyDeepLink(_ url: URL) {
        guard url.scheme?.lowercased() == "penlo" else { return }
        let host = (url.host ?? "").lowercased()
        guard host == "setup" || host.isEmpty else { return }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let value = item.value else { return nil }
                return (item.name, value)
            }
        )
        if let urlValue = items["url"] ?? items["brain_url"] {
            guard urlValue.hasPrefix("https://") else { return }
            KeychainStore.saveBrainURL(urlValue)
        }
        if let key = items["key"] ?? items["brain_key"] {
            guard key.hasPrefix("pb_live_") else { return }
            KeychainStore.saveBrainKey(key)
        }
        if let email = items["email"] {
            KeychainStore.saveUserEmail(email)
            UserDefaults.standard.set(email, forKey: "userEmail")
        }
        NotificationCenter.default.post(name: .brainCredentialsSaved, object: nil)
    }
}
