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
    @State private var showAllCategories = false
    private var graphService = BrainGraphService.shared
    private enum RootScreen {
        case chat
        case dispatches
    }

    @State private var rootScreen: RootScreen = .chat
    @State private var showOnboarding = !SetupState.isOnboardingComplete
    @State private var onboardingCoordinator = OnboardingCoordinator()

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
                graphService: graphService,
                onFolderTap: { folder in
                    closeDrawer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        selectedFolder = folder
                    }
                },
                onAllCategoriesTap: {
                    closeDrawer()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        showAllCategories = true
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
                    openDispatches()
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
        .fullScreenCover(isPresented: $showOnboarding) {
            OnboardingFlowView(
                coordinator: onboardingCoordinator,
                brainSyncer: brainSyncer,
                onFinished: {
                    showOnboarding = false
                    onboardingCoordinator.isReplayFromSettings = false
                }
            )
        }
        .sheet(isPresented: $showSettings) {
            HardwareManagementSheet(
                bluetooth: bluetooth,
                brainSyncer: brainSyncer,
                onSetupGuide: { presentSetupGuide() }
            )
        }
        .onOpenURL { url in
            onboardingCoordinator.applyDeepLink(url)
            if !SetupState.isOnboardingComplete {
                showOnboarding = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .reopenOnboarding)) { _ in
            presentSetupGuide()
        }
        .sheet(item: $selectedFolder) { folder in
            KnowledgeVaultSheet(folder: folder, graphService: graphService)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAllCategories) {
            BrainCategoriesSheet(graphService: graphService) { folder in
                selectedFolder = folder
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
        ) { _ in
            Task { await graphService.refresh() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .openDispatch)) { note in
            openDispatches()
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
            guard rootScreen != .dispatches else { return }
            Task { await dispatchService.fetchCards(silent: true) }
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
            audioEngine.onFault = { [appState] message in
                appState.enterFault(message: message)
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
            Task { await dispatchService.fetchCards() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            brainSyncer.drainQueue(modelContext: modelContext)
        }
    }

    // MARK: Main Content

    private var mainContent: some View {
        Group {
            switch rootScreen {
            case .chat:
                HomeChatView(
                    bluetooth: bluetooth,
                    chatVM: chatVM,
                    audioEngine: audioEngine,
                    brainSyncer: brainSyncer,
                    appStateManager: appState,
                    onMenuTap: { toggleDrawer() },
                    onNewChat: {
                        chatVM.startNewChat()
                        if drawerOpen { closeDrawer() }
                    },
                    onSetupGuide: { presentSetupGuide() }
                )
            case .dispatches:
                DispatchView(
                    service: dispatchService,
                    onBack: { closeDispatches() },
                    onOpenSettings: {
                        showSettings = true
                    }
                )
            }
        }
    }

    private func openDispatches() {
        closeDrawer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            withAnimation(.easeInOut(duration: 0.25)) {
                rootScreen = .dispatches
            }
        }
    }

    private func closeDispatches() {
        dispatchService.stopPolling()
        withAnimation(.easeInOut(duration: 0.25)) {
            rootScreen = .chat
        }
    }

    private func presentSetupGuide() {
        onboardingCoordinator.isReplayFromSettings = true
        onboardingCoordinator.stepIndex = 0
        onboardingCoordinator.rebuildSteps()
        showOnboarding = true
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
