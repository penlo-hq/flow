//
//  flowApp.swift
//  flow
//

import SwiftUI
import SwiftData
import UIKit

@main
struct flowApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private let calendarManager = CalendarManager()
    private let modelContainer = PenloStore.makeContainer()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .modelContainer(modelContainer)
                .onReceive(NotificationCenter.default.publisher(for: .apnsTokenReceived)) { note in
                    if let token = note.userInfo?["token"] as? String {
                        Task { await PushRegistrationService.registerTokenWithBrain(token) }
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    Task { await Self.refreshBriefingNotificationsIfAllowed(calendarManager: calendarManager) }
                }
        }
    }

    @Sendable
    private static func refreshBriefingNotificationsIfAllowed(calendarManager: CalendarManager) async {
        guard SetupState.briefingsOptIn else { return }
        let events = await MainActor.run { calendarManager.upcomingEvents() }
        await NotificationManager.shared.refreshNotifications(for: events)
    }
}
