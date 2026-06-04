//
//  MemoryPayload.swift
//  flow
//
//  Penlo Contract v1.1 — the validated data schema for extracted intelligence.
//
//  Mirrors the Python pipeline's schema.py: SPO fact triples with confidence,
//  structured people with contact info, and ontology-aligned topic summaries.
//
//  Includes backward-compatible decoding for legacy payloads (flat string arrays)
//  stored in SwiftData from earlier app versions.
//

import Foundation
import UIKit

// MARK: - Shared UTC Formatter

enum PenloTimestamp {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    static func now() -> String {
        formatter.string(from: Date())
    }

    static func from(_ date: Date) -> String {
        formatter.string(from: date)
    }
}

// MARK: - Device Identity

enum PenloDevice {
    static var identifier: String {
        UIDevice.current.identifierForVendor?.uuidString ?? "UNKNOWN_DEVICE"
    }
}

// MARK: - Penlo Contract v1.1

struct PenloFact: Sendable, Equatable, Identifiable {
    let id = UUID()
    var subject: String
    var predicate: String
    var object: String
    var confidence: Float
    var capturedAt: String

    var displayText: String {
        "\(subject) \(predicate) \(object)"
    }

    var confidenceLabel: String {
        String(format: "%.0f%%", confidence * 100)
    }
}

extension PenloFact: Codable {
    enum CodingKeys: String, CodingKey {
        case subject, predicate, object, confidence, capturedAt
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subject    = try c.decode(String.self, forKey: .subject)
        predicate  = try c.decode(String.self, forKey: .predicate)
        object     = try c.decode(String.self, forKey: .object)
        confidence = try c.decode(Float.self, forKey: .confidence)
        capturedAt = try c.decodeIfPresent(String.self, forKey: .capturedAt) ?? ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(subject,    forKey: .subject)
        try c.encode(predicate,  forKey: .predicate)
        try c.encode(object,     forKey: .object)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(capturedAt, forKey: .capturedAt)
    }
}

struct PenloPerson: Sendable, Equatable, Identifiable, Codable {
    let id = UUID()
    var name: String
    var email: String?
    var phone: String?
    var notes: String?

    enum CodingKeys: String, CodingKey {
        case name, email, phone, notes
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name  = try c.decode(String.self, forKey: .name)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        phone = try c.decodeIfPresent(String.self, forKey: .phone)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(name,  forKey: .name)
        try c.encode(email, forKey: .email)
        try c.encode(phone, forKey: .phone)
        try c.encode(notes, forKey: .notes)
    }

    init(name: String, email: String? = nil, phone: String? = nil, notes: String? = nil) {
        self.name = name
        self.email = email
        self.phone = phone
        self.notes = notes
    }
}

// MARK: - Vault File (Contract Section 4)

struct VaultFile: Sendable, Equatable, Codable {
    var id: String
    var title: String
    var folder: String
    var content: String
    var tags: [String]
    var lastModified: String
    var wikiLinks: [String]

    init(id: String, title: String, folder: String, content: String, tags: [String] = [], lastModified: String = "", wikiLinks: [String] = []) {
        self.id = id
        self.title = title
        self.folder = folder
        self.content = String(content.prefix(10_000))
        self.tags = tags
        self.lastModified = lastModified.isEmpty ? PenloTimestamp.now() : lastModified
        self.wikiLinks = wikiLinks
    }
}

/// The full Penlo Contract v1.1 payload — the single source of truth for
/// extracted intelligence from a transcript segment.
struct PenloPayload: Sendable, Equatable {
    var schemaVersion: String = "1.1"
    var deviceID: String = PenloDevice.identifier
    var userEmail: String?
    var syncedAt: String
    var facts: [PenloFact]
    var people: [PenloPerson]
    var topicSummary: [String]
    var vaultFiles: [VaultFile]

    var totalEntityCount: Int {
        facts.count + people.count + topicSummary.count
    }

    var isEmpty: Bool {
        facts.isEmpty && people.isEmpty && topicSummary.isEmpty
    }
}

extension PenloPayload: Codable {
    enum CodingKeys: String, CodingKey {
        case schemaVersion, deviceID, userEmail, syncedAt, facts, people, topicSummary, vaultFiles
    }

    nonisolated init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(String.self, forKey: .schemaVersion) ?? "1.1"
        deviceID      = try c.decodeIfPresent(String.self, forKey: .deviceID) ?? PenloDevice.identifier
        userEmail     = try c.decodeIfPresent(String.self, forKey: .userEmail)
        syncedAt      = try c.decodeIfPresent(String.self, forKey: .syncedAt) ?? ""
        facts         = try c.decodeIfPresent([PenloFact].self, forKey: .facts) ?? []
        people        = try c.decodeIfPresent([PenloPerson].self, forKey: .people) ?? []
        topicSummary  = try c.decodeIfPresent([String].self, forKey: .topicSummary) ?? []
        vaultFiles    = try c.decodeIfPresent([VaultFile].self, forKey: .vaultFiles) ?? []
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(deviceID,      forKey: .deviceID)
        try c.encode(userEmail,     forKey: .userEmail)
        try c.encode(syncedAt,      forKey: .syncedAt)
        try c.encode(facts,         forKey: .facts)
        try c.encode(people,        forKey: .people)
        try c.encode(topicSummary,  forKey: .topicSummary)
        try c.encode(vaultFiles,    forKey: .vaultFiles)
    }
}

// MARK: - Legacy MemoryPayload (backward-compatible alias)

/// Retained as a typealias concept for backward compat decoding of older
/// payloads stored with flat string arrays.
struct LegacyMemoryPayload: Codable, Sendable {
    var title: String
    var facts: [String]
    var people: [String]
    var topics: [String]
}

// MARK: - MemoryPayload (Unified Access Layer)

/// Provides a unified interface over both v1.1 PenloPayload and legacy formats.
/// This is what the UI and extraction layers primarily interact with.
struct MemoryPayload: Equatable, Sendable {
    var title: String
    var facts: [PenloFact]
    var people: [PenloPerson]
    var topicSummary: [String]

    // Envelope metadata
    var schemaVersion: String = "1.1"
    var deviceID: String = PenloDevice.identifier
    var syncedAt: String = ""

    var totalEntityCount: Int {
        facts.count + people.count + topicSummary.count
    }

    var entitySummary: String {
        var parts: [String] = []
        if !facts.isEmpty {
            parts.append("\(facts.count) Fact\(facts.count == 1 ? "" : "s")")
        }
        if !people.isEmpty {
            parts.append("\(people.count) \(people.count == 1 ? "Person" : "People")")
        }
        if !topicSummary.isEmpty {
            parts.append("\(topicSummary.count) Topic\(topicSummary.count == 1 ? "" : "s")")
        }
        return parts.joined(separator: ", ")
    }

    var isEmpty: Bool {
        facts.isEmpty && people.isEmpty && topicSummary.isEmpty
    }

    /// Flat people names for preview chips and backward-compat UI.
    var peopleNames: [String] {
        people.map(\.name)
    }

    /// Flat fact display strings for simple views.
    var factStrings: [String] {
        facts.map(\.displayText)
    }

    /// Convenience init for creating from extraction results.
    init(
        title: String,
        facts: [PenloFact] = [],
        people: [PenloPerson] = [],
        topicSummary: [String] = [],
        capturedAt: Date = .now
    ) {
        self.title = title
        self.facts = facts
        self.people = people
        self.topicSummary = topicSummary
        self.deviceID = PenloDevice.identifier
        self.syncedAt = PenloTimestamp.from(capturedAt)
    }

    /// Convert to PenloPayload for Enterprise Brain sync.
    /// syncedAt will be overridden at actual POST time by EnterpriseBrainSyncer.
    func toPenloPayload(userEmail: String? = nil) -> PenloPayload {
        let email = userEmail ?? KeychainStore.readUserEmail()
        let vaultFiles = PenloVaultFileBuilder.build(from: self, userEmail: email)
        return PenloPayload(
            schemaVersion: schemaVersion,
            deviceID: PenloDevice.identifier,
            userEmail: email,
            syncedAt: PenloTimestamp.now(),
            facts: facts,
            people: people,
            topicSummary: topicSummary,
            vaultFiles: vaultFiles
        )
    }
}

// MARK: - Codable with Backward Compat

extension MemoryPayload: Codable {
    enum CodingKeys: String, CodingKey {
        case title, facts, people, topicSummary, schemaVersion, deviceID, syncedAt
    }

    /// Legacy keys for older format.
    private enum LegacyKeys: String, CodingKey {
        case title, facts, people, topics
    }

    nonisolated init(from decoder: Decoder) throws {
        // Try v1.1 format first
        if let c = try? decoder.container(keyedBy: CodingKeys.self),
           let title = try? c.decode(String.self, forKey: .title) {
            self.title = title
            self.schemaVersion = (try? c.decode(String.self, forKey: .schemaVersion)) ?? "1.1"
            self.deviceID = (try? c.decode(String.self, forKey: .deviceID)) ?? "PENLO_IOS_APP"
            self.syncedAt = (try? c.decode(String.self, forKey: .syncedAt)) ?? ""

            // Try decoding facts as [PenloFact]
            if let richFacts = try? c.decode([PenloFact].self, forKey: .facts) {
                self.facts = richFacts
            } else if let flatFacts = try? c.decode([String].self, forKey: .facts) {
                self.facts = flatFacts.map { text in
                    PenloFact(subject: text, predicate: "noted", object: "", confidence: 0.70, capturedAt: "")
                }
            } else {
                self.facts = []
            }

            // Try decoding people as [PenloPerson]
            if let richPeople = try? c.decode([PenloPerson].self, forKey: .people) {
                self.people = richPeople
            } else if let flatPeople = try? c.decode([String].self, forKey: .people) {
                self.people = flatPeople.map { PenloPerson(name: $0) }
            } else {
                self.people = []
            }

            self.topicSummary = (try? c.decode([String].self, forKey: .topicSummary)) ?? []
            return
        }

        // Fall back to legacy format
        let c = try decoder.container(keyedBy: LegacyKeys.self)
        self.title = try c.decode(String.self, forKey: .title)
        let flatFacts = (try? c.decode([String].self, forKey: .facts)) ?? []
        self.facts = flatFacts.map { text in
            PenloFact(subject: text, predicate: "noted", object: "", confidence: 0.70, capturedAt: "")
        }
        let flatPeople = (try? c.decode([String].self, forKey: .people)) ?? []
        self.people = flatPeople.map { PenloPerson(name: $0) }
        self.topicSummary = (try? c.decode([String].self, forKey: .topics)) ?? []
        self.schemaVersion = "1.0"
        self.deviceID = "PENLO_IOS_APP"
        self.syncedAt = ""
    }

    nonisolated func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title,         forKey: .title)
        try c.encode(facts,         forKey: .facts)
        try c.encode(people,        forKey: .people)
        try c.encode(topicSummary,  forKey: .topicSummary)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(deviceID,      forKey: .deviceID)
        try c.encode(syncedAt,      forKey: .syncedAt)
    }
}
