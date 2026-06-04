//
//  KnowledgeVaultSheet.swift
//  flow
//
//  Brain-backed category browser — lists company graph nodes for each vault folder.
//  Local SwiftData captures shown separately when the Brain graph is empty.
//

import SwiftData
import SwiftUI

struct KnowledgeVaultSheet: View {
    let folder: VaultFolder
    @Bindable var graphService: BrainGraphService

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL

    @Query(sort: \Transcript.capturedAt, order: .reverse)
    private var transcripts: [Transcript]

    @State private var showLocalCaptures = false

    private var brainNodes: [BrainGraphNode] {
        graphService.nodes(ofType: folder.nodeType)
    }

    var body: some View {
        NavigationStack {
            Group {
                if !graphService.isConfigured {
                    notConfiguredState
                } else if graphService.isLoading && brainNodes.isEmpty {
                    ProgressView("Loading from Enterprise Brain…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if brainNodes.isEmpty && localItems.isEmpty {
                    emptyState
                } else {
                    itemList
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationTitle(folder.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                if graphService.isConfigured {
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            Task { await graphService.refresh() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .foregroundStyle(Color.royalBlue)
                        }
                        .disabled(graphService.isLoading)
                    }
                }
            }
            .task {
                await graphService.refresh()
            }
        }
    }

    // MARK: - List

    private var itemList: some View {
        List {
            if !brainNodes.isEmpty {
                Section {
                    ForEach(brainNodes) { node in
                        brainNodeRow(node)
                    }
                } header: {
                    HStack {
                        Text("Company Brain")
                        Spacer()
                        Text("\(brainNodes.count)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }

            if !localItems.isEmpty {
                Section {
                    if showLocalCaptures || brainNodes.isEmpty {
                        ForEach(localItems) { item in
                            localItemRow(item)
                        }
                    }
                } header: {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showLocalCaptures.toggle()
                        }
                    } label: {
                        HStack {
                            Text("Recent captures on device")
                            Spacer()
                            Image(systemName: showLocalCaptures || brainNodes.isEmpty ? "chevron.down" : "chevron.right")
                                .font(.caption.weight(.semibold))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.textSecondary)
                } footer: {
                    if !brainNodes.isEmpty {
                        Text("Device-only items may not yet appear in Company Brain until synced and approved.")
                            .font(.caption2)
                    }
                }
            }

            if let err = graphService.lastError, brainNodes.isEmpty {
                Section {
                    Text(err)
                        .font(.caption)
                        .foregroundStyle(.red.opacity(0.9))
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private func brainNodeRow(_ node: BrainGraphNode) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(node.label)
                .font(.body.weight(.medium))
                .foregroundStyle(Color.textPrimary)
            if let detail = node.detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.royalBlue.opacity(0.8))
                    .lineLimit(3)
            }
            if let updated = node.updatedAt {
                Text(relativeTime(fromISO: updated))
                    .font(.caption2)
                    .foregroundStyle(Color.textSecondary)
            }
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    private func localItemRow(_ item: VaultItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                Text("Local")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.textSecondary.opacity(0.12))
                    .clipShape(Capsule())
            }
            if let detail = item.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Color.royalBlue.opacity(0.8))
            }
            HStack(spacing: 4) {
                Text(item.source)
                    .lineLimit(1)
                Text("·")
                Text(item.relativeTime)
            }
            .font(.caption)
            .foregroundStyle(Color.textSecondary)
        }
        .padding(.vertical, 4)
        .listRowBackground(Color.clear)
    }

    // MARK: - Local filter (device-only fallback)

    private var localItems: [VaultItem] {
        var items: [VaultItem] = []
        var seen = Set<String>()

        for transcript in transcripts {
            guard let payload = transcript.payload else { continue }
            let source = payload.title
            let time = transcript.capturedAt
            let userEmail = KeychainStore.readUserEmail()

            switch folder {
            case .people:
                for person in payload.people where !PenloVaultFileBuilder.isClientPerson(person, userEmail: userEmail) {
                    let key = person.name.lowercased()
                    if seen.insert(key).inserted {
                        let detail = [person.email, person.notes].compactMap { $0 }.joined(separator: " · ")
                        items.append(VaultItem(label: person.name, detail: detail.isEmpty ? nil : detail, source: source, date: time))
                    }
                }
            case .clients:
                for person in payload.people where PenloVaultFileBuilder.isClientPerson(person, userEmail: userEmail) {
                    let key = person.name.lowercased()
                    if seen.insert(key).inserted {
                        items.append(VaultItem(label: person.name, detail: person.email ?? person.notes, source: source, date: time))
                    }
                }
            case .topics:
                for topic in payload.topicSummary {
                    let key = topic.lowercased()
                    if seen.insert(key).inserted {
                        items.append(VaultItem(label: topic, source: source, date: time))
                    }
                }
            case .tasks, .decisions, .features, .events:
                for fact in payload.facts {
                    let combined = "\(fact.subject) \(fact.predicate) \(fact.object)".lowercased()
                    let matches: Bool
                    switch folder {
                    case .tasks:
                        matches = combined.contains("task") || combined.contains("must") || combined.contains("should")
                    case .decisions:
                        matches = combined.contains("decided") || combined.contains("agreed") || combined.contains("approved")
                    case .features:
                        matches = combined.contains("feature") || combined.contains("build") || combined.contains("ship")
                    case .events:
                        matches = combined.contains("meeting") || combined.contains("event") || combined.contains("calendar")
                    default:
                        matches = false
                    }
                    guard matches else { continue }
                    let key = fact.displayText.lowercased()
                    if seen.insert(key).inserted {
                        items.append(VaultItem(label: fact.displayText, detail: fact.confidenceLabel, source: source, date: time))
                    }
                }
            }
        }
        return items
    }

    // MARK: - Empty / not configured

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: folder.icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.textSecondary.opacity(0.35))
            Text("No \(folder.title) Yet")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
            Text("Approve memories in Staging Vault to sync \(folder.title.lowercased()) to Company Brain.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary.opacity(0.6))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var notConfiguredState: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "link.badge.plus")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(Color.royalBlue.opacity(0.5))
            Text("Connect Enterprise Brain")
                .font(.title3.weight(.semibold))
            Text("Add your Brain URL and API key in Settings, or pair Flow from the web dashboard.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Open Connect App") {
                openURL(PenloConfig.connectURL)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.royalBlue)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func relativeTime(fromISO iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso)
        }
        guard let date else { return "updated" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "updated just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "updated \(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "updated \(hours)h ago" }
        return "updated \(hours / 24)d ago"
    }
}

// MARK: - Vault Item

private struct VaultItem: Identifiable {
    let id = UUID()
    let label: String
    var detail: String? = nil
    let source: String
    let date: Date

    var relativeTime: String {
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
