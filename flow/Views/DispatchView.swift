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
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(service.cards) { card in
                    DispatchCardView(
                        card: card,
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
                }
            }
            .padding(Metrics.screenPadding)
        }
        .background(Color.canvas)
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
