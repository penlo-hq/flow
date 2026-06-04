//
//  SyncQueue.swift
//  flow
//
//  SwiftData model + persistence infrastructure for reliable, offline-first
//  syncing. Each `SyncQueue` row is a payload that failed to reach the
//  Enterprise Brain and must be retried — this is the safety net that
//  guarantees no conversation data is ever lost when the network drops.
//

import Foundation
import SwiftData

// MARK: - Model

@Model
final class SyncQueue {
    /// Stable identity for this queued payload.
    @Attribute(.unique) var id: UUID

    /// The `Transcript.id` this payload represents (for de-duplication).
    var transcriptID: UUID

    /// The serialized body that failed to send.
    var payload: Data

    /// When the payload was first enqueued.
    var enqueuedAt: Date

    /// Number of delivery attempts so far (for backoff / give-up policy).
    var retryCount: Int

    /// Timestamp of the most recent delivery attempt, if any.
    var lastAttemptAt: Date?

    /// Last transport error message, for diagnostics.
    var lastError: String?

    init(
        id: UUID = UUID(),
        transcriptID: UUID,
        payload: Data,
        enqueuedAt: Date = .now,
        retryCount: Int = 0,
        lastAttemptAt: Date? = nil,
        lastError: String? = nil
    ) {
        self.id = id
        self.transcriptID = transcriptID
        self.payload = payload
        self.enqueuedAt = enqueuedAt
        self.retryCount = retryCount
        self.lastAttemptAt = lastAttemptAt
        self.lastError = lastError
    }
}

// MARK: - Shared Container

/// Centralized SwiftData configuration so every layer (UI, view models,
/// background actors) talks to the same store.
enum PenloStore {
    /// The full schema for the app.
    static let schema = Schema([
        Transcript.self,
        SyncQueue.self
    ])

    /// Builds a `ModelContainer`. `inMemory` is useful for previews/tests.
    static func makeContainer(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Unable to create Penlo ModelContainer: \(error)")
        }
    }

    // MARK: - Onboarding sample (single labeled memory)

    /// Creates one clearly labeled sample transcript during onboarding vault step only.
    @MainActor
    static func seedOnboardingSampleIfNeeded(in context: ModelContext) {
        guard !SetupState.onboardingSampleCreated else { return }

        let descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.isOnboardingSample }
        )
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            SetupState.markOnboardingSampleCreated()
            return
        }

        let payload = MemoryPayload(
            title: "Sample — onboarding",
            facts: [
                PenloFact(
                    subject: "Penlo Flow",
                    predicate: "demonstrates",
                    object: "approve-before-sync",
                    confidence: 0.95,
                    capturedAt: ""
                ),
                PenloFact(
                    subject: "Staging Vault",
                    predicate: "holds",
                    object: "memories until you approve",
                    confidence: 0.92,
                    capturedAt: ""
                )
            ],
            people: [PenloPerson(name: "You")],
            topicSummary: ["Onboarding", "Privacy"]
        )
        let data = try? JSONEncoder().encode(payload)
        let transcript = Transcript(
            rawText: "This is a labeled sample from onboarding — not a real meeting. Approve to practice sync, or discard to skip.",
            capturedAt: .now,
            isSynced: false,
            isOnboardingSample: true,
            payloadData: data
        )
        context.insert(transcript)
        try? context.save()
        SetupState.markOnboardingSampleCreated()
    }
}

// MARK: - Thread-Safe Persistence Actor

/// All writes go through this actor so SwiftData mutations happen off the
/// main thread and never block the UI. Backed by its own `ModelContext`
/// derived from the shared container (`@ModelActor` synthesizes the
/// `init(modelContainer:)` and the isolated `modelContext`).
@ModelActor
actor PersistenceActor {

    /// Persist a freshly captured transcript.
    @discardableResult
    func insertTranscript(rawText: String, capturedAt: Date = .now, payloadData: Data? = nil) throws -> UUID {
        let transcript = Transcript(rawText: rawText, capturedAt: capturedAt, payloadData: payloadData)
        modelContext.insert(transcript)
        try modelContext.save()
        return transcript.id
    }

    /// Enqueue a payload that failed to send so it can be retried later.
    func enqueueFailedPayload(transcriptID: UUID, payload: Data, error: String?) throws {
        let item = SyncQueue(
            transcriptID: transcriptID,
            payload: payload,
            lastError: error
        )
        modelContext.insert(item)
        try modelContext.save()
    }

    /// Mark a transcript as synced and drop its queued payloads (if any).
    func markSynced(transcriptID: UUID) throws {
        let transcriptDescriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.id == transcriptID }
        )
        for transcript in try modelContext.fetch(transcriptDescriptor) {
            transcript.isSynced = true
        }

        let queueDescriptor = FetchDescriptor<SyncQueue>(
            predicate: #Predicate { $0.transcriptID == transcriptID }
        )
        for queued in try modelContext.fetch(queueDescriptor) {
            modelContext.delete(queued)
        }

        try modelContext.save()
    }

    /// Record a failed retry attempt against an existing queue item.
    func recordRetryFailure(queueItemID: UUID, error: String?) throws {
        let descriptor = FetchDescriptor<SyncQueue>(
            predicate: #Predicate { $0.id == queueItemID }
        )
        guard let item = try modelContext.fetch(descriptor).first else { return }
        item.retryCount += 1
        item.lastAttemptAt = .now
        item.lastError = error
        try modelContext.save()
    }

    /// Permanently delete a queue item (for non-retryable errors like 400/422).
    func deleteQueueItem(id: UUID) throws {
        let descriptor = FetchDescriptor<SyncQueue>(
            predicate: #Predicate { $0.id == id }
        )
        for item in try modelContext.fetch(descriptor) {
            modelContext.delete(item)
        }
        try modelContext.save()
    }

    /// Attach a Claude-extracted MemoryPayload to an existing transcript.
    func attachPayload(transcriptID: UUID, payloadData: Data) throws {
        let descriptor = FetchDescriptor<Transcript>(
            predicate: #Predicate { $0.id == transcriptID }
        )
        guard let transcript = try modelContext.fetch(descriptor).first else { return }
        transcript.payloadData = payloadData
        try modelContext.save()
    }
}
