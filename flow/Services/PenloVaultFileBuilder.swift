//
//  PenloVaultFileBuilder.swift
//  flow
//
//  Builds penlo-brain vaultFiles[] from an approved MemoryPayload so folder → node type
//  mapping matches brain/backend/api/routes/ingest.py _FOLDER_TYPE_MAP.
//

import CryptoKit
import Foundation

enum PenloVaultFileBuilder {

    private static let buildSignals: [String] = [
        "build", "ship", "implement", "develop", "launch", "create", "creation",
        "deliver", "design", "add", "deploy", "release", "integrate", "website",
    ]
    private static let taskSignals: [String] = [
        "needs to", "must", "should", "assigned", "action item", "todo", "deadline",
        "blocked by", "fix", "resolve",
    ]
    private static let decisionSignals: [String] = [
        "decided", "agreed", "approved", "chose", "chosen", "committed to", "will ship",
        "is shipping", "concluded", "resolved to", "picked", "selected", "signed off",
        "went with", "opted for",
    ]
    private static let eventSignals: [String] = [
        "meeting", "conference", "workshop", "offsite", "calendar", "scheduled", "event",
    ]
    private static let clientSignals: [String] = [
        "client", "customer", "prospect", "account", "vendor",
    ]

    static func build(from payload: MemoryPayload, userEmail: String?) -> [VaultFile] {
        var files: [VaultFile] = []
        var seenKeys = Set<String>()
        let syncedAt = payload.syncedAt.isEmpty ? PenloTimestamp.now() : payload.syncedAt
        let deviceID = payload.deviceID

        func append(
            title: String,
            folder: String,
            content: String,
            tags: [String] = []
        ) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            let key = "\(folder)|\(trimmed.lowercased())"
            guard seenKeys.insert(key).inserted else { return }
            let id = stableVaultID(deviceID: deviceID, syncedAt: syncedAt, title: trimmed, folder: folder)
            files.append(VaultFile(
                id: id,
                title: trimmed,
                folder: folder,
                content: String(content.prefix(10_000)),
                tags: tags,
                lastModified: syncedAt
            ))
        }

        for topic in payload.topicSummary {
            let content = vaultContent(title: payload.title, body: topic)
            append(title: topic, folder: "topics", content: content)
        }

        for person in payload.people {
            let name = person.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { continue }
            var body = [person.email, person.phone, person.notes]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            if body.isEmpty { body = payload.title }
            if isClientPerson(person, userEmail: userEmail) {
                append(title: name, folder: "clients", content: body, tags: ["client"])
            } else {
                append(title: name, folder: "people", content: body)
            }
        }

        for fact in payload.facts {
            let label = fact.displayText
            guard !label.isEmpty else { continue }
            let combined = "\(fact.subject) \(fact.predicate) \(fact.object)".lowercased()
            let folder: String
            if matchesAny(combined, decisionSignals) {
                folder = "decisions"
            } else if matchesAny(combined, eventSignals) {
                folder = "events"
            } else if combined.contains("feature") || matchesAny(combined, buildSignals) {
                folder = "features"
            } else if combined.contains("task") || matchesAny(combined, taskSignals) {
                folder = "tasks"
            } else {
                continue
            }
            let content = vaultContent(title: payload.title, body: label)
            append(title: label, folder: folder, content: content, tags: [fact.subject])
        }

        return files
    }

    // MARK: - Helpers

    private static func vaultContent(title: String, body: String) -> String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return b }
        if b.isEmpty { return t }
        return "\(t)\n\n\(b)"
    }

    private static func stableVaultID(deviceID: String, syncedAt: String, title: String, folder: String) -> String {
        let input = "\(deviceID)|\(syncedAt)|\(folder)|\(title)"
        let digest = SHA256.hash(data: Data(input.utf8))
        let hex = digest.prefix(12).map { String(format: "%02x", $0) }.joined()
        return "vault/\(folder)/\(hex).md"
    }

    private static func matchesAny(_ text: String, _ signals: [String]) -> Bool {
        signals.contains { text.contains($0) }
    }

    static func isClientPerson(_ person: PenloPerson, userEmail: String?) -> Bool {
        let notes = (person.notes ?? "").lowercased()
        if clientSignals.contains(where: { notes.contains($0) }) { return true }

        guard let email = person.email?.lowercased(),
              let domain = email.split(separator: "@").last else {
            return false
        }
        if let userDomain = userEmail?.lowercased().split(separator: "@").last,
           domain != userDomain {
            return true
        }
        return false
    }
}
