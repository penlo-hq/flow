//
//  DispatchView.swift
//  flow
//
//  Sheet presenting the dispatch approval inbox. Polls the shared
//  `DispatchService` at 5s while visible so building/completed/failed
//  transitions appear live. The service is owned by `ContentView` and injected
//  so the drawer badge stays in sync with this view.
//

import SwiftUI

struct DispatchView: View {
    @ObservedObject var service: DispatchService

    var body: some View {
        NavigationStack {
            Group {
                if service.authError != nil {
                    authErrorState
                } else if service.cards.isEmpty && !service.isLoading {
                    emptyState
                } else {
                    cardList
                }
            }
            .navigationTitle("Dispatches")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear { service.startPolling() }
        .onDisappear { service.stopPolling() }
    }

    private var cardList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 10) {
                    if let err = service.lastActionError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Metrics.screenPadding)
                    }
                    ForEach(service.cards) { card in
                        DispatchCardView(
                            card: card,
                            showAutoBuild: service.executorEnabled,
                            onApprove: { mode in
                                Task { await service.approve(id: card.id, mode: mode) }
                            },
                            onDiscard: {
                                Task { await service.discard(id: card.id) }
                            },
                            onRetryAsQueue: {
                                Task { await service.approve(id: card.id, mode: "mcp") }
                            }
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(
                                    service.highlightDispatchId == card.id.uuidString.lowercased()
                                        ? Color.royalBlue : Color.clear,
                                    lineWidth: 2
                                )
                        )
                        .id(card.id.uuidString.lowercased())
                    }
                }
                .padding(Metrics.screenPadding)
            }
            .background(Color.canvas)
            .onChange(of: service.highlightDispatchId) { _, newId in
                guard let newId else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation {
                        proxy.scrollTo(newId, anchor: .center)
                    }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    if service.highlightDispatchId == newId {
                        service.highlightDispatchId = nil
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(Color.textSecondary)
            Text("No pending dispatches")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }

    private var authErrorState: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(service.authError ?? "")
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.canvas)
    }
}
