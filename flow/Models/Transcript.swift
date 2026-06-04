//
//  Transcript.swift
//  flow
//
//  SwiftData model for a single captured conversation transcript.
//  This is the durable, on-device source of truth: if the network
//  drops, transcripts persist locally until they can be synced to
//  the Enterprise Brain.
//

import Foundation
import SwiftData

@Model
final class Transcript {
    @Attribute(.unique) var id: UUID

    var rawText: String

    var capturedAt: Date

    var isSynced: Bool

    /// Labeled sample created during onboarding only (not real capture).
    var isOnboardingSample: Bool = false

    /// JSON-encoded Pydantic v1.1 extraction payload (facts, people, topics).
    /// Decoded on-demand via the `payload` computed property.
    var payloadData: Data?

    init(
        id: UUID = UUID(),
        rawText: String,
        capturedAt: Date = .now,
        isSynced: Bool = false,
        isOnboardingSample: Bool = false,
        payloadData: Data? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.capturedAt = capturedAt
        self.isSynced = isSynced
        self.isOnboardingSample = isOnboardingSample
        self.payloadData = payloadData
    }

    // MARK: - Payload Access

    /// Decodes stored payload data. Handles both v1.1 (PenloPayload) and
    /// legacy flat-array format transparently via MemoryPayload's custom decoder.
    var payload: MemoryPayload? {
        get {
            guard let data = payloadData else { return nil }
            return try? JSONDecoder().decode(MemoryPayload.self, from: data)
        }
        set {
            payloadData = try? JSONEncoder().encode(newValue)
        }
    }

    /// Returns the full PenloPayload for Enterprise Brain sync.
    var penloPayload: PenloPayload? {
        payload?.toPenloPayload()
    }

    // MARK: - Display Helpers

    var displayTitle: String {
        if isOnboardingSample {
            return "Sample — onboarding"
        }
        return payload?.title ?? String(rawText.prefix(60))
    }

    var relativeTimeLabel: String {
        let seconds = Int(Date().timeIntervalSince(capturedAt))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
