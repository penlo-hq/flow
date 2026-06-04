//
//  DispatchView.swift
//  flow
//
//  Full-screen dispatch inbox — approve agent-proposed work, track builds,
//  and open PRs when complete.
//

import SwiftUI

enum DispatchInboxFilter: String, CaseIterable, Identifiable {
    case inbox
    case active
    case done
    case all

    var id: String { rawValue }

    var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .active: return "Active"
        case .done: return "Done"
        case .all: return "All"
        }
    }
}

struct DispatchView: View {
    @ObservedObject var service: DispatchService
    let onBack: () -> Void
    var onOpenSettings: (() -> Void)?

    @State private var filter: DispatchInboxFilter = .inbox
    @State private var githubPanelExpanded = false
    @State private var githubRepoDraft = ""
    @State private var githubBranchDraft = "main"
    @State private var githubSaveError: String?
    @State private var githubSaving = false

    private var filteredCards: [DispatchCard] {
        switch filter {
        case .inbox:
            return service.cards.filter { $0.status == "pending" }
        case .active:
            return service.cards.filter { ["approved", "building"].contains($0.status) }
        case .done:
            return service.cards.filter { ["completed", "failed"].contains($0.status) }
        case .all:
            return service.cards
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            filterBar

            if let reason = service.autoBuildDisabledReason, service.executorEnabled, filter != .done {
                autoBuildHint(reason)
            }

            Group {
                if service.authError != nil {
                    authErrorState
                } else if service.isLoading && service.cards.isEmpty {
                    skeletonState
                } else if service.networkError != nil && service.cards.isEmpty && !service.isLoading {
                    networkErrorState
                } else if filteredCards.isEmpty && !service.isLoading {
                    emptyState
                } else {
                    cardList
                }
            }
        }
        .background(Color.canvas.ignoresSafeArea())
        .onAppear {
            service.startPolling()
            Task {
                await service.fetchCards()
                syncGitHubDrafts()
            }
        }
        .onDisappear {
            service.stopPolling()
        }
        .onChange(of: service.githubSettings) { _, _ in
            syncGitHubDrafts()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                Haptics.light()
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to chat")

            VStack(alignment: .leading, spacing: 2) {
                Text("Dispatch")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(Color.textPrimary)
                Text("Approve agent work for your company")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
            }

            Spacer()

            if service.pendingCount > 0 {
                Text("\(service.pendingCount)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.royalBlue, in: Capsule())
            }

            Button {
                Task { await service.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.royalBlue)
                    .frame(width: 44, height: 44)
                    .rotationEffect(.degrees(service.isRefreshing ? 360 : 0))
                    .animation(
                        service.isRefreshing
                            ? .linear(duration: 1).repeatForever(autoreverses: false)
                            : .default,
                        value: service.isRefreshing
                    )
            }
            .buttonStyle(.plain)
            .disabled(service.isRefreshing)
            .accessibilityLabel("Refresh")
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(DispatchInboxFilter.allCases) { item in
                    filterChip(item)
                }
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 10)
        }
    }

    private func filterChip(_ item: DispatchInboxFilter) -> some View {
        let selected = filter == item
        let count: Int? = {
            switch item {
            case .inbox: return service.pendingCount > 0 ? service.pendingCount : nil
            case .active: return service.cards.filter { ["approved", "building"].contains($0.status) }.count
            case .done: return nil
            case .all: return service.cards.isEmpty ? nil : service.cards.count
            }
        }()
        return Button {
            Haptics.light()
            withAnimation(.easeInOut(duration: 0.2)) {
                filter = item
            }
        } label: {
            HStack(spacing: 6) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(selected ? Color.white.opacity(0.25) : Color.royalBlue.opacity(0.15))
                        .clipShape(Capsule())
                }
            }
            .foregroundStyle(selected ? .white : Color.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(selected ? Color.royalBlue : Color.surface, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - GitHub hint

    private func autoBuildHint(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle.fill")
                .foregroundStyle(Color.royalBlue)
            Text(text)
                .font(.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.royalBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.bottom, 8)
    }

    // MARK: - List

    private var cardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    if filter == .inbox || filter == .all {
                        if service.executorEnabled && !service.githubSettingsAdminOnly {
                            githubDefaultsPanel
                        }
                    }

                    if let err = service.lastActionError {
                        actionErrorBanner(err)
                    }

                    ForEach(filteredCards) { card in
                        DispatchCardView(
                            card: card,
                            showAutoBuild: service.executorEnabled,
                            autoBuildDisabledReason: service.autoBuildDisabledReason,
                            performingAction: service.cardActions[card.id] ?? .idle,
                            onApprove: { mode in
                                Task { await service.approve(id: card.id, mode: mode) }
                            },
                            onDiscard: {
                                Task { await service.discard(id: card.id) }
                            },
                            onRetryAsQueue: {
                                Task { await service.approve(id: card.id, mode: "mcp") }
                            },
                            onRetryAuto: {
                                Task { await service.approve(id: card.id, mode: "auto") }
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                                .stroke(
                                    service.highlightDispatchId == card.id.uuidString.lowercased()
                                        ? Color.royalBlue : Color.clear,
                                    lineWidth: 2
                                )
                        )
                        .id(card.id.uuidString.lowercased())
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.bottom, 24)
            }
            .refreshable {
                await service.refresh()
            }
            .onChange(of: service.highlightDispatchId) { _, newId in
                guard let newId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation { proxy.scrollTo(newId, anchor: .center) }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    if service.highlightDispatchId == newId {
                        service.highlightDispatchId = nil
                    }
                }
            }
        }
    }

    // MARK: - GitHub panel

    private var githubDefaultsPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    githubPanelExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "link")
                        .foregroundStyle(Color.royalBlue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("GitHub defaults")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.textPrimary)
                        if githubRepoDraft.isEmpty {
                            Text("Required for auto-build PRs")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                        } else {
                            Text("\(githubRepoDraft) · \(githubBranchDraft)")
                                .font(.caption)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: githubPanelExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }
                .padding(14)
            }
            .buttonStyle(.plain)

            if githubPanelExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("owner/repository", text: $githubRepoDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    TextField("Base branch", text: $githubBranchDraft)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(12)
                        .background(Color.canvas, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if let githubSaveError {
                        Text(githubSaveError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        githubSaving = true
                        githubSaveError = nil
                        Task {
                            let err = await service.saveGitHubSettings(
                                repo: githubRepoDraft,
                                baseBranch: githubBranchDraft
                            )
                            githubSaveError = err
                            githubSaving = false
                        }
                    } label: {
                        HStack {
                            if githubSaving {
                                ProgressView().tint(.white)
                            }
                            Text(githubSaving ? "Saving…" : "Save defaults")
                                .font(.subheadline.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(
                            githubRepoDraft.trimmingCharacters(in: .whitespaces).isEmpty
                                ? Color.textSecondary.opacity(0.4)
                                : Color.royalBlue,
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(githubSaving || githubRepoDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(Color.surface, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }

    private func syncGitHubDrafts() {
        githubRepoDraft = service.githubSettings?.repo ?? ""
        githubBranchDraft = service.githubSettings?.baseBranch ?? "main"
    }

    // MARK: - States

    private func actionErrorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            Button("Dismiss") {
                service.lastActionError = nil
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.royalBlue)
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var skeletonState: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                ForEach(0..<3, id: \.self) { _ in
                    DispatchSkeletonCard()
                }
            }
            .padding(Metrics.screenPadding)
        }
    }

    private var networkErrorState: some View {
        stateContainer(
            icon: "wifi.slash",
            title: "Couldn't load dispatches",
            message: service.networkError ?? "Check your connection and Brain URL.",
            actionTitle: "Try Again",
            action: { Task { await service.refresh() } }
        )
    }

    private var emptyState: some View {
        let (title, message) = emptyCopy
        return stateContainer(
            icon: filter == .inbox ? "tray" : "checkmark.circle",
            title: title,
            message: message,
            actionTitle: nil,
            action: nil
        )
    }

    private var emptyCopy: (String, String) {
        switch filter {
        case .inbox:
            return (
                "Inbox clear",
                "When the brain proposes features or tasks, they'll appear here for your approval."
            )
        case .active:
            return (
                "Nothing in progress",
                "Approved and building dispatches show up here while work runs."
            )
        case .done:
            return (
                "No finished dispatches",
                "Completed PRs and failed builds appear here."
            )
        case .all:
            return (
                "No dispatches yet",
                "Sync memories to Enterprise Brain — high-importance work becomes dispatch cards."
            )
        }
    }

    private var authErrorState: some View {
        stateContainer(
            icon: "key.fill",
            title: "Can't access Dispatch",
            message: service.authError ?? "Check your Brain credentials.",
            actionTitle: onOpenSettings != nil ? "Open Settings" : nil,
            action: onOpenSettings
        )
    }

    private func stateContainer(
        icon: String,
        title: String,
        message: String,
        actionTitle: String?,
        action: (() -> Void)?
    ) -> some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color.textSecondary.opacity(0.8))
            VStack(spacing: 8) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(Color.royalBlue, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Skeleton

private struct DispatchSkeletonCard: View {
    @State private var animating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).frame(height: 16).frame(maxWidth: 200)
            RoundedRectangle(cornerRadius: 6).frame(height: 12).frame(maxWidth: .infinity)
            RoundedRectangle(cornerRadius: 8).frame(width: 100, height: 32)
        }
        .padding(16)
        .background(Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        .opacity(animating ? 0.55 : 1)
        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: animating)
        .onAppear { animating = true }
    }
}
