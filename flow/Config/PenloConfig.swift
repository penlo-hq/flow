//
//  PenloConfig.swift
//  flow
//
//  Build-time web dashboard URLs (Debug vs Release via Info.plist).
//

import Foundation

enum PenloConfig {
    private static func string(for key: String, fallback: String) -> String {
        guard let raw = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fallback
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Web dashboard origin, e.g. http://localhost:5173
    static var webBaseURL: URL {
        URL(string: string(for: "PENLO_WEB_BASE_URL", fallback: defaultWebBase))!
    }

    static var connectURL: URL {
        webBaseURL.appending(path: "connect")
    }

    static var signupURL: URL {
        webBaseURL.appending(path: "signup")
    }

    static var onboardingWebURL: URL {
        webBaseURL.appending(path: "onboarding")
    }

    #if DEBUG
    private static let defaultWebBase = "http://localhost:5173"
    #else
    private static let defaultWebBase = "https://app.penlo.ai"
    #endif
}
