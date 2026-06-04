//
//  DispatchFormatting.swift
//  flow
//

import Foundation

enum DispatchFormatting {
    static func relativeTime(iso: String) -> String {
        guard let date = ISO8601DateFormatter.penlo.date(from: iso)
            ?? ISO8601DateFormatter.penloFallback.date(from: iso) else {
            return ""
        }
        let seconds = Int(Date.now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    static func expiresLabel(iso: String) -> String {
        guard let date = ISO8601DateFormatter.penlo.date(from: iso)
            ?? ISO8601DateFormatter.penloFallback.date(from: iso) else {
            return ""
        }
        let ms = date.timeIntervalSinceNow
        if ms <= 0 { return "Expired" }
        let totalMin = Int(ms / 60)
        let days = totalMin / (60 * 24)
        let hr = (totalMin - days * 60 * 24) / 60
        if days > 0 { return "Expires in \(days)d \(hr)h" }
        if hr > 0 { return "Expires in \(hr)h" }
        return "Expires in \(totalMin)m"
    }
}

private extension ISO8601DateFormatter {
    static let penlo: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static let penloFallback: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
