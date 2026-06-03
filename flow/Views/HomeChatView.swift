//
//  HomeChatView.swift
//  flow
//
//  The main conversational chat canvas — mirroring the ChatGPT iOS
//  app. Empty state shows a pulsing orb + contextual status message;
//  populated state shows a vertical message stream with
//  ScrollViewReader auto-scrolling to the latest bubble.
//
//  Keyboard avoidance is handled manually because the parent
//  ContentView uses a ZStack + offset drawer layout that breaks
//  SwiftUI's built-in keyboard safe-area propagation.
//

import SwiftData
import SwiftUI

struct HomeChatView: View {
    @ObservedObject var bluetooth: BluetoothManager
    var chatVM: ChatViewModel
    var audioEngine: AudioEngineManager
    var brainSyncer: EnterpriseBrainSyncer
    let onMenuTap: () -> Void
    let onNewChat: () -> Void

    @Query(filter: #Predicate<Transcript> { !$0.isSynced })
    private var unsyncedTranscripts: [Transcript]

    @State private var inputText = ""
    @State private var showSettings = false
    @State private var showVault = false
    @State private var keyboardHeight: CGFloat = 0
    @State private var scrollAnchor = UUID()
    @State private var inputFocusTrigger = 0
    @State private var isListening = false
    @State private var partialTranscript = ""
    @State private var listeningSourceLabel = "iPhone mic"

    private var keyboardPadding: CGFloat {
        guard keyboardHeight > 0 else { return 0 }
        let bottomInset = (UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }
            .first?.safeAreaInsets.bottom) ?? 0
        return max(0, keyboardHeight - bottomInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar

            if chatVM.messages.isEmpty {
                emptyState
            } else {
                chatStream
            }

            if isListening {
                listeningBanner
            }

            ChatInputBar(
                text: $inputText,
                suggestions: chatVM.messages.isEmpty && !isListening ? chatVM.suggestions : [],
                onSend: sendMessage,
                onSuggestion: { chatVM.sendSuggestion($0) },
                focusTrigger: inputFocusTrigger,
                isListening: isListening,
                onMicTap: toggleListening
            )
        }
        .padding(.bottom, keyboardPadding)
        .background(Color.canvas.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)
        ) { notification in
            guard let frame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = frame.height
            }
            scrollAnchor = UUID()
        }
        .onReceive(
            NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)
        ) { notification in
            let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double) ?? 0.25
            withAnimation(.easeOut(duration: duration)) {
                keyboardHeight = 0
            }
        }
        .sheet(isPresented: $showSettings) {
            HardwareManagementSheet(bluetooth: bluetooth, brainSyncer: brainSyncer)
        }
        .sheet(isPresented: $showVault) {
            StagingVaultSheet(brainSyncer: brainSyncer)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                Haptics.light()
                onMenuTap()
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Spacer()

            WearableStatusPill(
                bluetooth: bluetooth,
                unsyncedCount: unsyncedTranscripts.count,
                isPhoneListening: isListening
            ) {
                if isListening {
                    stopListening()
                } else if unsyncedTranscripts.isEmpty {
                    showSettings = true
                } else {
                    showVault = true
                }
            }

            Spacer()

            Button {
                Haptics.medium()
                inputText = ""
                onNewChat()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    inputFocusTrigger += 1
                }
            } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.medium))
                    .foregroundStyle(Color.textPrimary)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 24) {
            Spacer()
            LiquidGlassOrb(size: 110, isActive: bluetooth.state.isLive || isListening)
            Text(emptyStateMessage)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)

            if !ClaudeService.hasAPIKey {
                apiKeyBanner
            } else if bluetooth.state == .disconnected && !isListening {
                VStack(spacing: 12) {
                    Button {
                        showSettings = true
                    } label: {
                        Text("Connect Penlo")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.royalBlue)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.royalBlue.opacity(0.1), in: Capsule())
                    }
                    .buttonStyle(.plain)

                    Button {
                        startListening()
                    } label: {
                        Label("Use Phone Mic", systemImage: "mic.fill")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var apiKeyBanner: some View {
        Button {
            showSettings = true
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "key.fill")
                    .font(.body)
                    .foregroundStyle(Color.royalBlue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add your Claude API key")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text("Enable AI-powered chat and transcription analysis")
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(16)
            .background(Color.royalBlue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 24)
    }

    private var emptyStateMessage: String {
        if !ClaudeService.hasAPIKey {
            return "Welcome to Penlo."
        }
        if isListening {
            return "Listening via phone mic..."
        }
        switch bluetooth.state {
        case .recording:    return "Listening..."
        case .connected:    return "Penlo connected.\nAsk me anything."
        case .searching:    return "Searching for Penlo..."
        case .disconnected: return "Welcome to Penlo."
        }
    }

    // MARK: - Chat Stream

    private var chatStream: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 18) {
                    ForEach(chatVM.messages) { message in
                        MessageBubble(message: message) {
                            withAnimation(.snappy(duration: 0.3)) {
                                chatVM.toggleBriefingExpansion(for: message.id)
                            }
                        }
                        .id(message.id)
                    }

                    if chatVM.isThinking {
                        thinkingIndicator
                            .id("thinking")
                    }
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: chatVM.messages.count) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: chatVM.isThinking) { _, _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: scrollAnchor) { _, _ in
                scrollToBottom(proxy: proxy)
            }
        }
    }

    // MARK: - Thinking Indicator

    private var thinkingIndicator: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.royalBlue)
                    Text("Penlo")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.textSecondary)
                }

                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        ThinkingDot(delay: Double(i) * 0.2)
                    }
                }
            }
            .padding(.horizontal, 4)
            Spacer()
        }
    }

    // MARK: - Listening Banner

    private var listeningBanner: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 8, height: 8)
                .opacity(isListening ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 2) {
                Text(listeningSourceLabel)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.royalBlue)
                Text(partialTranscript.isEmpty ? "Listening…" : partialTranscript)
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.screenPadding + 8)
        .padding(.vertical, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.snappy(duration: 0.2), value: partialTranscript)
    }

    // MARK: - Mic Toggle

    private func toggleListening() {
        if isListening {
            stopListening()
        } else {
            startListening()
        }
    }

    private func startListening() {
        Task {
            let source: AudioSource = bluetooth.state.isLive ? .hardwareBLE : .internalMic
            listeningSourceLabel = source == .hardwareBLE ? "Penlo wearable" : "iPhone mic"

            let granted: Bool
            if source == .hardwareBLE {
                granted = await audioEngine.requestSpeechPermission()
            } else {
                granted = await audioEngine.requestPermissions()
            }
            guard granted else {
                showSettings = true
                return
            }

            audioEngine.onPartialResult = { text in
                partialTranscript = text
            }
            audioEngine.onAutoStopped = {
                withAnimation(.snappy(duration: 0.25)) {
                    isListening = false
                    partialTranscript = ""
                }
            }

            withAnimation(.snappy(duration: 0.25)) {
                isListening = true
                partialTranscript = ""
            }
            audioEngine.startTranscribing(source: source)
            Haptics.success()
        }
    }

    private func stopListening() {
        audioEngine.stopTranscribing()
        withAnimation(.snappy(duration: 0.25)) {
            isListening = false
            partialTranscript = ""
        }
        Haptics.light()
    }

    // MARK: - Helpers

    private func sendMessage() {
        let msg = inputText
        inputText = ""
        chatVM.send(msg)
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) {
            if chatVM.isThinking {
                proxy.scrollTo("thinking", anchor: .bottom)
            } else if let last = chatVM.messages.last {
                proxy.scrollTo(last.id, anchor: .bottom)
            }
        }
    }
}

// MARK: - Thinking Dot

private struct ThinkingDot: View {
    let delay: Double
    @State private var animate = false

    var body: some View {
        Circle()
            .fill(Color.textSecondary.opacity(0.5))
            .frame(width: 7, height: 7)
            .scaleEffect(animate ? 1.0 : 0.5)
            .opacity(animate ? 1.0 : 0.3)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true).delay(delay)) {
                    animate = true
                }
            }
    }
}

#Preview("Empty") {
    HomeChatView(
        bluetooth: BluetoothManager(),
        chatVM: ChatViewModel(),
        audioEngine: AudioEngineManager(),
        brainSyncer: EnterpriseBrainSyncer(),
        onMenuTap: {},
        onNewChat: {}
    )
    .modelContainer(PenloStore.makeContainer(inMemory: true))
    .preferredColorScheme(.dark)
}

#Preview("Conversation") {
    HomeChatView(
        bluetooth: BluetoothManager(),
        chatVM: {
            let v = ChatViewModel()
            v.messages = ChatMessage.sampleConversation
            return v
        }(),
        audioEngine: AudioEngineManager(),
        brainSyncer: EnterpriseBrainSyncer(),
        onMenuTap: {},
        onNewChat: {}
    )
    .modelContainer(PenloStore.makeContainer(inMemory: true))
    .preferredColorScheme(.dark)
}
