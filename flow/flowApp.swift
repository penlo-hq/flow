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
                .task { await requestPermissionsOnce() }
                .onReceive(NotificationCenter.default.publisher(for: .apnsTokenReceived)) { note in
                    if let token = note.userInfo?["token"] as? String {
                        Task { await PushRegistrationService.registerTokenWithBrain(token) }
                    }
                }
                .onReceive(
                    NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
                ) { _ in
                    Task { await refreshBriefingNotifications() }
                }
        }
    }

    private func requestPermissionsOnce() async {
        _ = await calendarManager.requestAccess()
        let granted = await NotificationManager.shared.requestAuthorization()
        if granted {
            await MainActor.run {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
        await refreshBriefingNotifications()
    }

    @Sendable
    private func refreshBriefingNotifications() async {
        let events = await MainActor.run { calendarManager.upcomingEvents() }
        await NotificationManager.shared.refreshNotifications(for: events)
    }
}
