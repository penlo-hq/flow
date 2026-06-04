//
//  StagingVaultSheet.swift
//  flow
//
//  The Privacy Review screen. Captured conversations are held here
//  until the user explicitly approves them. Clear, intuitive UX that
//  explains what's happening and gives full control.
//

import SwiftData
import SwiftUI

struct StagingVaultSheet: View {
    var brainSyncer: EnterpriseBrainSyncer

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query(
        filter: #Predicate<Transcript> { !$0.isSynced },
        sort: \Transcript.capturedAt,
        order: .reverse
    )
    private var blocks: [Transcript]

    @State private var expandedID: UUID?
    @State private var syncingAll = false
    @State private var syncingID: UUID?
    @State private var syncError: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if blocks.isEmpty {
                    emptyState
                } else {
                    headerExplanation
                    blockList
                }
            }
            .background(Color.canvas.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Review Memories")
                        .font(.headline.weight(.bold))
                        .foregroundStyle(Color.textPrimary)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textSecondary)
                    }
                }
            }
            .toolbarBackground(Color.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        }
        
        .onAppear {
            purgeExpired()
            if expandedID == nil, let first = blocks.first {
                expandedID = first.id
            }
        }
        .alert("Sync Failed", isPresented: Binding(
            get: { syncError != nil },
            set: { if !$0 { syncError = nil } }
        )) {
            Button("OK", role: .cancel) { syncError = nil }
        } message: {
            Text(syncError ?? "Could not reach Enterprise Brain.")
        }
        .onChange(of: blocks.count) { old, new in
            if new == 0 && old > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    dismiss()
                }
            }
        }
    }

    // MARK: - Header

    private var headerExplanation: some View {
        VStack(spacing: 16) {
            if !brainSyncer.isConfigured {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "link.badge.plus")
                        .foregroundStyle(Color.royalBlue)
                    Text("Set Enterprise Brain URL and your pb_live_ API key in Settings before approving.")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.royalBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                Image(systemName: "shield.lefthalf.filled")
                    .font(.title3)
                    .foregroundStyle(Color.royalBlue)

                VStack(alignment: .leading, spacing: 2) {
                    Text("\(blocks.count) captured \(blocks.count == 1 ? "conversation" : "conversations")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Review what Penlo heard. Approve to keep, swipe to discard.")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                Spacer()
            }

            if blocks.count > 1 {
                Button {
                    syncAllBlocks()
                } label: {
                    HStack(spacing: 8) {
                        if syncingAll {
                            ProgressView()
                                .tint(.white)
                                .scaleEffect(0.75)
                        } else {
                            Image(systemName: "checkmark.circle")
                                .font(.subheadline.weight(.semibold))
                            Text("Approve All \(blocks.count) Memories")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .foregroundStyle(Color.textPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        Color.royalBlue.opacity(syncingAll ? 0.5 : 1.0),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
                .disabled(syncingAll)
            }
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.vertical, 16)
        .background(Color.canvas)
    }

    // MARK: - Block List

    private var blockList: some View {
        List {
            ForEach(blocks) { transcript in
                MemoryBlockCard(
                    transcript: transcript,
                    isExpanded: expandedID == transcript.id,
                    onToggle: { toggleExpansion(transcript.id) },
                    onSync: { syncBlock(transcript) },
                    onDiscard: { deleteBlock(transcript) },
                    onRemoveItem: { kind, index in
                        removeItem(from: transcript, kind: kind, at: index)
                    }
                )
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .listRowInsets(
                    EdgeInsets(
                        top: 8,
                        leading: Metrics.screenPadding,
                        bottom: 8,
                        trailing: Metrics.screenPadding
                    )
                )
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(role: .destructive) {
                        deleteBlock(transcript)
                    } label: {
                        Label("Discard", systemImage: "trash")
                    }
                }
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        syncBlock(transcript)
                    } label: {
                        Label("Approve", systemImage: "checkmark")
                    }
                    .tint(.royalBlue)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 52, weight: .light))
                .foregroundStyle(Color.royalBlue.opacity(0.6))
            Text("All Caught Up")
                .font(.title3.weight(.bold))
                .foregroundStyle(Color.textPrimary)
            Text("No conversations waiting for review.\nNew captures will appear here.")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Actions

    private func toggleExpansion(_ id: UUID) {
        withAnimation(.spring(response: 0.4, dampingFraction: 0.85)) {
            expandedID = expandedID == id ? nil : id
        }
    }

    private func deleteBlock(_ transcript: Transcript) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
            modelContext.delete(transcript)
            try? modelContext.save()
            Haptics.medium()
        }
    }

    private func syncBlock(_ transcript: Transcript) {
        syncingID = transcript.id
        Task {
            defer { syncingID = nil }
            guard brainSyncer.isConfigured else {
                syncError = "Configure Enterprise Brain URL and API key in Settings first."
                Haptics.medium()
                return
            }
            let result = await brainSyncer.enqueueAndSync(transcript: transcript)
            if result.ok {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    transcript.isSynced = true
                    try? modelContext.save()
                    Haptics.success()
                }
            } else {
                syncError = result.detail
                Haptics.medium()
            }
        }
    }

    private func syncAllBlocks() {
        syncingAll = true
        Task {
            defer { syncingAll = false }
            guard brainSyncer.isConfigured else {
                syncError = "Configure Enterprise Brain URL and API key in Settings first."
                Haptics.medium()
                return
            }
            var failures: [String] = []
            for block in blocks {
                let result = await brainSyncer.enqueueAndSync(transcript: block)
                if result.ok {
                    block.isSynced = true
                } else {
                    failures.append(result.detail)
                }
            }
            try? modelContext.save()
            if failures.isEmpty {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.9)) {
                    Haptics.success()
                }
            } else {
                syncError = failures.first ?? "Some memories failed to sync."
                Haptics.medium()
            }
        }
    }

    private func removeItem(from transcript: Transcript, kind: String, at index: Int) {
        guard var payload = transcript.payload else { return }

        switch kind {
        case "facts":  guard index < payload.facts.count else { return };  payload.facts.remove(at: index)
        case "people": guard index < payload.people.count else { return }; payload.people.remove(at: index)
        case "topics": guard index < payload.topicSummary.count else { return }; payload.topicSummary.remove(at: index)
        default: return
        }

        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            if payload.isEmpty {
                modelContext.delete(transcript)
            } else {
                transcript.payload = payload
            }
            try? modelContext.save()
            Haptics.light()
        }
    }

    // MARK: - 72h TTL Purge

    private func purgeExpired() {
        let cutoff = Date.now.addingTimeInterval(-72 * 60 * 60)
        let expired = blocks.filter { $0.capturedAt < cutoff }
        guard !expired.isEmpty else { return }
        for t in expired { modelContext.delete(t) }
        try? modelContext.save()
    }
}

#Preview {
    StagingVaultSheet(brainSyncer: EnterpriseBrainSyncer())
        .modelContainer(PenloStore.makeContainer(inMemory: true))
}
