//
//  DrawerMenu.swift
//  flow
//
//  ChatGPT-style left-side navigation drawer. Contains a new-chat
//  button, conversation history, Knowledge Vault folder links,
//  profile info, and settings access.
//

import SwiftUI

struct DrawerMenu: View {
    @ObservedObject var bluetooth: BluetoothManager
    var chatVM: ChatViewModel
    @Bindable var graphService: BrainGraphService
    let onFolderTap: (VaultFolder) -> Void
    let onAllCategoriesTap: () -> Void
    let onSettingsTap: () -> Void
    let onNewChat: () -> Void
    let onConversationTap: (ArchivedConversation) -> Void
    let onDispatchTap: () -> Void
    let dispatchBadge: Int   // pending dispatch count; 0 hides the badge

    // Stored credential name — falls back to "Penlo User" if not set
    @AppStorage("userName") private var storedUserName: String = ""
    @AppStorage("userEmail") private var storedUserEmail: String = ""

    private var displayName: String {
        let name = storedUserName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Penlo User" : name
    }

    private var displayEmail: String {
        let email = storedUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? bluetooth.state.label : email
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            profileCard

            newChatButton

            Divider().overlay(Color.textSecondary.opacity(0.15))

            dispatchesButton()

            Divider().overlay(Color.textSecondary.opacity(0.15))

            conversationHistory

            Divider().overlay(Color.textSecondary.opacity(0.15))

            vaultFolders

            Spacer()

            Divider().overlay(Color.textSecondary.opacity(0.15))

            bottomBar
        }
        .frame(width: Metrics.drawerWidth)
        .frame(maxHeight: .infinity)
        .background(Color.surface)
        .onAppear {
            syncProfileFromKeychain()
            Task { await graphService.refresh() }
        }
    }

    private func syncProfileFromKeychain() {
        if let email = KeychainStore.readUserEmail(), !email.isEmpty {
            storedUserEmail = email
        }
    }

    // MARK: Profile Card

    private var profileCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Color.royalBlue.opacity(0.15))
                    .frame(width: 44, height: 44)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(Color.royalBlue)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(displayEmail)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }

            HStack(spacing: 6) {
                Image(systemName: bluetooth.state.hardwareSymbol)
                    .font(.caption2)
                if let battery = bluetooth.batteryLevel {
                    Text("Penlo \(battery)%")
                        .font(.caption)
                } else {
                    Text("Penlo")
                        .font(.caption)
                }
            }
            .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal, Metrics.screenPadding)
        .padding(.top, 60)
        .padding(.bottom, 16)
    }

    // MARK: New Chat Button

    private var newChatButton: some View {
        Button {
            onNewChat()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "plus.bubble")
                    .font(.body.weight(.medium))
                Text("New Chat")
                    .font(.body.weight(.medium))
                Spacer()
            }
            .foregroundStyle(Color.textPrimary)
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Dispatches

    private func dispatchesButton() -> some View {
        Button {
            Haptics.light()
            onDispatchTap()
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .topTrailing) {
                    Image(systemName: "bolt.circle")
                        .font(.body)
                        .foregroundStyle(Color.royalBlue)
                        .frame(width: 22)
                    if dispatchBadge > 0 {
                        Text("\(min(dispatchBadge, 99))")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(3)
                            .background(.red)
                            .clipShape(Circle())
                            .offset(x: 8, y: -8)
                    }
                }
                Text("Dispatches")
                    .font(.body)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Conversation History

    private var conversationHistory: some View {
        VStack(alignment: .leading, spacing: 0) {
            if chatVM.archivedConversations.isEmpty {
                Text("No previous conversations")
                    .font(.caption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.vertical, 16)
            } else {
                Text("RECENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.top, 14)
                    .padding(.bottom, 8)

                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(chatVM.archivedConversations) { conversation in
                            Button {
                                Haptics.light()
                                onConversationTap(conversation)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(conversation.preview)
                                        .font(.subheadline)
                                        .foregroundStyle(Color.textPrimary)
                                        .lineLimit(1)
                                    Text(conversation.relativeDate)
                                        .font(.caption2)
                                        .foregroundStyle(Color.textSecondary)
                                }
                                .padding(.horizontal, Metrics.screenPadding)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    // MARK: Vault Folders

    private var vaultFolders: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("KNOWLEDGE VAULT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.textSecondary)
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.top, 14)
                .padding(.bottom, 8)

            ForEach(VaultFolder.allCases) { folder in
                Button {
                    Haptics.light()
                    onFolderTap(folder)
                } label: {
                    HStack(spacing: 14) {
                        Image(systemName: folder.icon)
                            .font(.body)
                            .foregroundStyle(Color.royalBlue)
                            .frame(width: 22)
                        Text(folder.title)
                            .font(.body)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        if graphService.isConfigured {
                            let count = graphService.count(for: folder.nodeType)
                            if count > 0 {
                                Text("\(min(count, 99))")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.royalBlue)
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Color.royalBlue.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                    }
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            Button {
                Haptics.light()
                onAllCategoriesTap()
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "square.grid.2x2")
                        .font(.body)
                        .foregroundStyle(Color.royalBlue)
                        .frame(width: 22)
                    Text("All Categories")
                        .font(.body)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, Metrics.screenPadding)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Bottom

    private var bottomBar: some View {
        Button {
            Haptics.light()
            onSettingsTap()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "gearshape")
                    .font(.body)
                    .foregroundStyle(Color.textSecondary)
                Text("Settings & Hardware")
                    .font(.subheadline)
                    .foregroundStyle(Color.textPrimary)
            }
            .padding(.horizontal, Metrics.screenPadding)
            .padding(.vertical, 18)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Vault Folder

enum VaultFolder: String, CaseIterable, Identifiable {
    case people, topics, tasks, decisions, features, clients, events

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var icon: String {
        switch self {
        case .people:    return "person.2"
        case .topics:    return "text.bubble"
        case .tasks:     return "checklist"
        case .decisions: return "arrow.triangle.branch"
        case .features:  return "sparkles"
        case .clients:   return "building.2"
        case .events:    return "calendar"
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        DrawerMenu(
            bluetooth: BluetoothManager(),
            chatVM: ChatViewModel(),
            graphService: BrainGraphService.shared,
            onFolderTap: { _ in },
            onAllCategoriesTap: {},
            onSettingsTap: {},
            onNewChat: {},
            onConversationTap: { _ in },
            onDispatchTap: {},
            dispatchBadge: 0
        )
        Spacer()
    }
    .background(Color.canvas)
}
