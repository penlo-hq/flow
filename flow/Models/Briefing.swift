//
//  Briefing.swift
//  flow
//
//  Pre-meeting intelligence briefing (Section 6 of the Enterprise Contract).
//  Surfaced from the Home View as a bottom sheet.
//

import Foundation

/// A pre-meeting context briefing.
struct Briefing {
    let meetingTitle: String
    let minutesUntil: Int
    let peopleContext: [String]
    let relevantDecisions: [String]
    let openQuestions: [String]

    /// e.g. "Meeting in 15m"
    var countdownLabel: String {
        "Meeting in \(minutesUntil)m"
    }

    /// One-line summary for notification body cache.
    var summaryLine: String {
        if let first = peopleContext.first, !first.isEmpty { return first }
        if let first = relevantDecisions.first, !first.isEmpty { return first }
        return meetingTitle
    }
}

// MARK: - Sample Data

extension Briefing {
    static let sample = Briefing(
        meetingTitle: "Enterprise Sync Review",
        minutesUntil: 15,
        peopleContext: [
            "Nolan Carroll — VP Eng, owns the ingestion pipeline.",
            "Priya Anand — Design lead, pushing for zero-config pairing.",
            "Marcus Lee — Enterprise customer, blocked on Wi-Fi-only sync."
        ],
        relevantDecisions: [
            "Ship Enterprise Sync before the offsite.",
            "Default to Wi-Fi-only sync for battery.",
            "Batch transcripts to respect ingestion limits."
        ],
        openQuestions: [
            "Is BLE pairing reliable enough for GA?",
            "What is the unsynced-queue ceiling before we warn the user?"
        ]
    )
}
