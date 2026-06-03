//
//  ContentView.swift
//  flow
//
//  Root container. ChatGPT-style sliding drawer + the main
//  conversational chat canvas. Owns BluetoothManager, AppStateManager,
//  ChatViewModel, and AudioEngineManager.
//

import Combine
import SwiftData
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var bluetooth = BluetoothManager()
    @State private var chatVM = ChatViewModel()
    @State private var appState = AppStateManager()
    @State private var audioEngine = AudioEngineManager()
    @State private var briefingScheduler = BriefingScheduler()
    @State private var brainSyncer = EnterpriseBrainSyncer()
    @StateObject private var dispatchService = DispatchService()

    @Environment(\.modelContext) private var modelContext

    @State private var drawerOpen = false
    @State private var dragOffset: CGFloat = 0
    @State private var showSettings = false
    @State private var selectedFolder: VaultFolder?
    @State private var showDispatches = false

    private let openWidth: CGFloat = Metrics.drawerWidth

    /// Normalized progress 0...1 (0 = closed, 1 = fully open).
    private var progress: CGFloat {
        let base: CGFloat = drawerOpen ? openWidth : 0
        let raw = base + dragOffset
        return max(0, min(1, raw / openWidth))
    }

    private var mainOffset: CGFloat { progress * openWidth }
    private var mainScale: CGFloat { 1.0 - (progress * 0.05) }
    private var mainCornerRadius: CGFloat { progress * 20 }
    private var scrimOpacity: Double { Double(progress) * 0.35 }
    private var drawerSlide: CGFloat { -openWidth * 0.3 * (1.0 - progress) }

    private static let drawerSpring = Animation.interpolatingSpring(
        mass: 1.0,
        stiffness: 280,
        damping: 28,
        initialVelocity: 0
    )

    var body: some View {
        ZStack(alignment: .leading) {
            DrawerMenu(
                bluetooth: bluetooth,
                chatVM: chatVM,
                onFolderTap: { folder in
                    closeDrawer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        selectedFolder = folder
                    }
                },
                onSettingsTap: {
                    closeDrawer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showSettings = true
                    }
                },
                onNewChat: {
                    chatVM.startNewChat()
                    closeDrawer()
                },
                onConversationTap: { archived in
                    chatVM.restoreConversation(archived)
                    closeDrawer()
                },
                onDispatchTap: {
                    closeDrawer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showDispatches = true
                    }
                },
                dispatchBadge: dispatchService.pendingCount
            )
            .offset(x: drawerSlide)
            .opacity(0.6 + (progress * 0.4))

            mainContent
                .scaleEffect(mainScale, anchor: .trailing)
                .offset(x: mainOffset)
                .clipShape(RoundedRectangle(cornerRadius: mainCornerRadius, style: .continuous))
                .shadow(color: .black.opacity(scrimOpacity * 0.5), radius: 20, x: -8)
                .gesture(dragGesture)

            Color.black.opacity(scrimOpacity)
                .ignoresSafeArea()
                .offset(x: mainOffset)
                .allowsHitTesting(drawerOpen)
                .onTapGesture { closeDrawer() }
        }
        .ignoresSafeArea(.keyboard)
        .animation(Self.drawerSpring, value: drawerOpen)
        .animation(Self.drawerSpring, value: dragOffset)
        .sheet(isPresented: $showSettings) {
            HardwareManagementSheet(bluetooth: bluetooth, brainSyncer: brainSyncer)
        }
        .sheet(item: $selectedFolder) { folder in
            KnowledgeVaultSheet(folder: folder)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showDispatches) {
            DispatchView(service: dispatchService)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDispatch)) { note in
            showDispatches = true
            if let id = note.userInfo?["dispatch_id"] as? String {
                dispatchService.highlightDispatchId = id.lowercased()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openBriefing)) { _ in
            briefingScheduler.start()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettings)) { _ in
            showSettings = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .brainCredentialsSaved)) { _ in
            Task {
                await PushRegistrationService.registerCachedTokenIfPossible()
                await MainActor.run {
                    UIApplication.shared.registerForRemoteNotifications()
                }
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            // DispatchView polls at 5s while open; only top up the badge here
            // when the sheet is closed.
            guard !showDispatches else { return }
            Task { await dispatchService.fetchCards() }
        }
        .onAppear {
            bluetooth.onStateChange = { [appState] wearableState in
                appState.handleWearableStateChange(wearableState)
            }
            audioEngine.configure(
                modelContainer: modelContext.container
            )
            audioEngine.onTranscribingChange = { [appState] isActive in
                appState.handleTranscribingChange(isActive)
            }
            bluetooth.onHardwareAudio = { [audioEngine] data in
                audioEngine.appendHardwareAudio(data: data)
            }
            bluetooth.onHardwareAction = { [audioEngine] in
                audioEngine.injectHardwareActionFlag()
            }
            chatVM.modelContext = modelContext
            briefingScheduler.configure(chatVM: chatVM, modelContext: modelContext)
            briefingScheduler.start()
            brainSyncer.configure(modelContainer: modelContext.container)
            brainSyncer.drainQueue(modelContext: modelContext)
            PenloStore.seedDemoTranscripts(in: modelContext)
            Task { await dispatchService.fetchCards() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            brainSyncer.drainQueue(modelContext: modelContext)
        }
    }

    // MARK: Main Content

    private var mainContent: some View {
        HomeChatView(
            bluetooth: bluetooth,
            chatVM: chatVM,
            audioEngine: audioEngine,
            brainSyncer: brainSyncer,
            onMenuTap: { toggleDrawer() },
            onNewChat: {
                chatVM.startNewChat()
                if drawerOpen { closeDrawer() }
            }
        )
    }

    // MARK: Drawer Control

    private func toggleDrawer() {
        Haptics.light()
        withAnimation(Self.drawerSpring) {
            drawerOpen.toggle()
        }
    }

    private func closeDrawer() {
        Haptics.light()
        withAnimation(Self.drawerSpring) {
            drawerOpen = false
        }
    }

    // MARK: Drag Gesture

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 12, coordinateSpace: .global)
            .onChanged { value in
                let horizontal = value.translation.width
                withAnimation(.interactiveSpring) {
                    if drawerOpen {
                        dragOffset = min(0, horizontal)
                    } else {
                        dragOffset = max(0, horizontal)
                    }
                }
            }
            .onEnded { value in
                let velocity = value.predictedEndTranslation.width
                let threshold: CGFloat = openWidth * 0.35
                let currentOffset = (drawerOpen ? openWidth : 0) + dragOffset

                withAnimation(Self.drawerSpring) {
                    if drawerOpen {
                        drawerOpen = currentOffset > threshold || velocity > 200
                    } else {
                        drawerOpen = currentOffset > threshold || velocity > 500
                    }
                    dragOffset = 0
                }

                if drawerOpen != (currentOffset > threshold) {
                    Haptics.light()
                }
            }
    }
}


#Preview("Dark") {
    ContentView()
        .modelContainer(PenloStore.makeContainer(inMemory: true))
        .preferredColorScheme(.dark)
}

#Preview("Light") {
    ContentView()
        .modelContainer(PenloStore.makeContainer(inMemory: true))
        .preferredColorScheme(.light)
}
