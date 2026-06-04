//
//  BrainCategoriesSheet.swift
//  flow
//
//  Read-only overview of all 13 Company Brain node types and counts (web parity).
//

import SwiftUI

struct BrainCategoriesSheet: View {
    @Bindable var graphService: BrainGraphService
    let onSelectFolder: (VaultFolder) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if !graphService.isConfigured {
                    Text("Connect Enterprise Brain in Settings to view category counts.")
                        .font(.subheadline)
                        .foregroundStyle(Color.textSecondary)
                } else if graphService.isLoading && graphService.snapshot == nil {
                    HStack {
                        Spacer()
                        ProgressView()
                        Spacer()
                    }
                } else {
                    Section("Company Brain") {
                        ForEach(PenloNodeType.displayOrder) { nodeType in
                            row(for: nodeType)
                        }
                    }
                    if let err = graphService.lastError {
                        Section {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.85))
                        }
                    }
                }
            }
            .navigationTitle("All Categories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await graphService.refresh() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(graphService.isLoading)
                }
            }
            .task { await graphService.refresh() }
        }
    }

    @ViewBuilder
    private func row(for nodeType: PenloNodeType) -> some View {
        let count = graphService.count(for: nodeType)
        if let folder = vaultFolder(for: nodeType) {
            Button {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    onSelectFolder(folder)
                }
            } label: {
                categoryLabel(nodeType: nodeType, count: count, tappable: true)
            }
        } else {
            categoryLabel(nodeType: nodeType, count: count, tappable: false)
        }
    }

    private func categoryLabel(nodeType: PenloNodeType, count: Int, tappable: Bool) -> some View {
        HStack {
            Text(nodeType.displayLabel)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Text("\(count)")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(count > 0 ? Color.royalBlue : Color.textSecondary)
            if tappable {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
        }
    }

    private func vaultFolder(for nodeType: PenloNodeType) -> VaultFolder? {
        switch nodeType {
        case .person: return .people
        case .topic: return .topics
        case .task: return .tasks
        case .decision: return .decisions
        case .feature: return .features
        case .client: return .clients
        case .event: return .events
        default: return nil
        }
    }
}
