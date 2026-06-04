//
//  SetupState.swift
//  flow
//
//  Persistent first-run setup requirements and optional nudges.
//

import Foundation

enum SetupState {

    /// Bump when onboarding flow or completion criteria change.
    static let currentOnboardingVersion = 1

    private static let completedVersionKey = "penlo.onboarding.completedVersion"
    private static let skippedStepsKey = "penlo.onboarding.skippedSteps"
    private static let userPathKey = "penlo.onboarding.userPath"
    private static let sawVaultIntroKey = "penlo.onboarding.sawVaultIntro"
    private static let brainSkippedKey = "penlo.onboarding.brainSkipped"
    private static let brainTestSuccessKey = "penlo.onboarding.brainTestSuccessAt"
    private static let briefingsOptInKey = "penlo.onboarding.briefingsOptIn"
    private static let sampleCreatedKey = "penlo.onboarding.sampleCreated"

    enum UserPath: String {
        case invited
        case selfServe
    }

    enum Requirement: String, CaseIterable {
        case accountEmail
        case claudeKey
        case enterpriseBrain
        case vaultIntro
    }

    enum OptionalNudge: String, CaseIterable {
        case brainConnectionTest
        case microphone
        case briefings
        case wearable
    }

    // MARK: - Persistence accessors

    static var completedVersion: Int {
        UserDefaults.standard.integer(forKey: completedVersionKey)
    }

    static func markOnboardingComplete() {
        UserDefaults.standard.set(currentOnboardingVersion, forKey: completedVersionKey)
    }

    static var skippedSteps: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: skippedStepsKey) ?? [])
    }

    static func skipStep(_ id: String) {
        var steps = UserDefaults.standard.stringArray(forKey: skippedStepsKey) ?? []
        if !steps.contains(id) { steps.append(id) }
        UserDefaults.standard.set(steps, forKey: skippedStepsKey)
    }

    static var userPath: UserPath? {
        guard let raw = UserDefaults.standard.string(forKey: userPathKey) else { return nil }
        return UserPath(rawValue: raw)
    }

    static func setUserPath(_ path: UserPath) {
        UserDefaults.standard.set(path.rawValue, forKey: userPathKey)
    }

    static var sawVaultIntro: Bool {
        UserDefaults.standard.bool(forKey: sawVaultIntroKey)
    }

    static func markVaultIntroSeen() {
        UserDefaults.standard.set(true, forKey: sawVaultIntroKey)
    }

    static var brainExplicitlySkipped: Bool {
        UserDefaults.standard.bool(forKey: brainSkippedKey)
    }

    static func markBrainSkipped() {
        UserDefaults.standard.set(true, forKey: brainSkippedKey)
        skipStep(Requirement.enterpriseBrain.rawValue)
    }

    static var brainTestSucceeded: Bool {
        UserDefaults.standard.object(forKey: brainTestSuccessKey) as? Date != nil
    }

    static func markBrainTestSuccess() {
        UserDefaults.standard.set(Date.now, forKey: brainTestSuccessKey)
        UserDefaults.standard.set(false, forKey: brainSkippedKey)
    }

    static var briefingsOptIn: Bool {
        UserDefaults.standard.bool(forKey: briefingsOptInKey)
    }

    static func setBriefingsOptIn(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: briefingsOptInKey)
    }

    static var onboardingSampleCreated: Bool {
        UserDefaults.standard.bool(forKey: sampleCreatedKey)
    }

    static func markOnboardingSampleCreated() {
        UserDefaults.standard.set(true, forKey: sampleCreatedKey)
    }

    /// Re-open full onboarding from settings without clearing credentials.
    static func resetOnboardingPresentationOnly() {
        UserDefaults.standard.removeObject(forKey: completedVersionKey)
    }

    // MARK: - Requirement checks

    static var hasAccountEmail: Bool {
        let email = KeychainStore.readUserEmail() ?? ""
        return !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    static var hasClaudeKey: Bool {
        ClaudeService.hasAPIKey
    }

    static var hasBrainConfigured: Bool {
        KeychainStore.hasBrainConfig
    }

    static var brainRequirementSatisfied: Bool {
        hasBrainConfigured && (brainTestSucceeded || brainExplicitlySkipped)
    }

    static var coreRequirementsMet: Bool {
        hasAccountEmail && hasClaudeKey && brainRequirementSatisfied && sawVaultIntro
    }

    static var isOnboardingComplete: Bool {
        completedVersion >= currentOnboardingVersion && coreRequirementsMet
    }

    /// Fraction of core requirements complete (0...1).
    static var coreProgressFraction: Double {
        let met = Requirement.allCases.filter { isRequirementMet($0) }.count
        return Double(met) / Double(Requirement.allCases.count)
    }

    static func isRequirementMet(_ requirement: Requirement) -> Bool {
        switch requirement {
        case .accountEmail: return hasAccountEmail
        case .claudeKey: return hasClaudeKey
        case .enterpriseBrain: return brainRequirementSatisfied
        case .vaultIntro: return sawVaultIntro
        }
    }

    static var incompleteOptionalNudges: [OptionalNudge] {
        OptionalNudge.allCases.filter { nudge in
            switch nudge {
            case .brainConnectionTest:
                return hasBrainConfigured && !brainTestSucceeded && !brainExplicitlySkipped
            case .microphone:
                return skippedSteps.contains("microphone")
            case .briefings:
                return !briefingsOptIn && !skippedSteps.contains("briefings")
            case .wearable:
                return false // optional; connect from Settings → Setup guide
            }
        }
    }

    /// Clipboard-detected pb_live_ key (48 hex chars after prefix).
    static func extractLiveKey(from pasteboard: String?) -> String? {
        guard let text = pasteboard?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty else { return nil }
        let pattern = #"pb_live_[0-9a-fA-F]{48}"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else {
            return nil
        }
        return String(text[range])
    }
}
