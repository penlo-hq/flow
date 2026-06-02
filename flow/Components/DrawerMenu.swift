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
    let onFolderTap: (VaultFolder) -> Void
    let onSettingsTap: () -> Void
    let onNewChat: () -> Void
    let onConversationTap: (ArchivedConversation) -> Void
    let onDispatchTap: () -> Void
    let dispatchBadge: Int   // pending dispatch count; 0 hides the badge

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
                    Text("Penlo User")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.textPrimary)
                    Text(bluetooth.state.label)
                        .font(.caption)
                        .foregroundStyle(Color.textSecondary)
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
                    }
                    .padding(.horizontal, Metrics.screenPadding)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
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
    case people, topics, tasks, decisions, features, clients

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
        }
    }
}

#Preview {
    HStack(spacing: 0) {
        DrawerMenu(
            bluetooth: BluetoothManager(),
            chatVM: ChatViewModel(),
            onFolderTap: { _ in },
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
