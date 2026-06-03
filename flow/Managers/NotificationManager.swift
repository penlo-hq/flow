//
//  NotificationManager.swift
//  flow
//

import EventKit
import UIKit
import UserNotifications

@MainActor
final class NotificationManager {

    static let shared = NotificationManager()

    enum Category {
        static let briefing = "com.getflow.flow.briefing"
        static let dispatch = "com.getflow.flow.dispatch"
        static let sync = "com.getflow.flow.sync"
        static let auth = "com.getflow.flow.auth"
    }

    private static let leadTimeMinutes = 15
    private static let briefingCacheKey = "com.getflow.flow.briefingCache"

    func requestAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            log("Notification auth failed: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Briefing cache

    func cacheBriefingSummary(eventID: String, summary: String) {
        var cache = UserDefaults.standard.dictionary(forKey: Self.briefingCacheKey) as? [String: String] ?? [:]
        cache[eventID] = String(summary.prefix(280))
        UserDefaults.standard.set(cache, forKey: Self.briefingCacheKey)
    }

    private func cachedSummary(for eventID: String) -> String? {
        let cache = UserDefaults.standard.dictionary(forKey: Self.briefingCacheKey) as? [String: String]
        return cache?[eventID]
    }

    // MARK: - Calendar briefing reminders

    func refreshNotifications(for events: [EKEvent]) async {
        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let penloIDs = pending
            .filter { $0.content.categoryIdentifier == Category.briefing }
            .map(\.identifier)
        if !penloIDs.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: penloIDs)
        }

        let now = Date.now
        var scheduled = 0
        for event in events {
            guard let fireDate = Calendar.current.date(byAdding: .minute, value: -Self.leadTimeMinutes, to: event.startDate) else { continue }
            guard fireDate > now else { continue }

            let eventID = event.eventIdentifier ?? UUID().uuidString
            let title = event.title ?? "Upcoming meeting"
            var body = cachedSummary(for: eventID) ?? "Your briefing is ready — tap to open Penlo"
            if body.isEmpty { body = "Meeting in \(Self.leadTimeMinutes) minutes" }

            let content = UNMutableNotificationContent()
            content.title = "Meeting in \(Self.leadTimeMinutes)m"
            content.body = body
            content.sound = .default
            content.categoryIdentifier = Category.briefing
            content.userInfo = ["event_id": eventID, "meeting_title": title]

            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: fireDate)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let id = "\(Category.briefing).\(eventID)"
            let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
            do {
                try await center.add(request)
                scheduled += 1
            } catch {
                log("Failed to schedule briefing: \(error.localizedDescription)")
            }
        }
        log("Scheduled \(scheduled) briefing notifications")
    }

    // MARK: - Immediate local alerts

    func notifyDispatchPending(count: Int, featureLabel: String?, dispatchId: String? = nil) {
        guard !UserDefaults.standard.bool(forKey: "com.getflow.flow.remotePushRegistered") else { return }
        guard UIApplication.shared.applicationState != .active else { return }
        let body = featureLabel.map { "\($0) — approve or queue" } ?? "\(count) dispatch\(count == 1 ? "" : "es") awaiting approval"
        var userInfo: [String: Any] = ["route": "dispatch"]
        if let dispatchId {
            userInfo["dispatch_id"] = dispatchId
        }
        postImmediate(
            id: "dispatch.pending.\(Date().timeIntervalSince1970)",
            title: "New dispatch",
            body: body,
            category: Category.dispatch,
            userInfo: userInfo
        )
    }

    func notifyDispatchComplete(featureLabel: String, prURL: String?) {
        guard UIApplication.shared.applicationState != .active else { return }
        var body = "Build finished for \(featureLabel)"
        if let prURL { body += " — \(prURL)" }
        postImmediate(
            id: "dispatch.complete.\(featureLabel)",
            title: "Dispatch complete",
            body: body,
            category: Category.dispatch,
            userInfo: ["route": "dispatch"]
        )
    }

    func notifyDispatchFailed(featureLabel: String, error: String) {
        guard UIApplication.shared.applicationState != .active else { return }
        postImmediate(
            id: "dispatch.failed.\(featureLabel)",
            title: "Dispatch failed",
            body: "\(featureLabel): \(error.prefix(200))",
            category: Category.dispatch,
            userInfo: ["route": "dispatch"]
        )
    }

    func notifySyncFailed(detail: String) {
        postImmediate(
            id: "sync.failed",
            title: "Brain sync failed",
            body: detail,
            category: Category.sync,
            userInfo: [:]
        )
    }

    func notifyAuthExpired() {
        postImmediate(
            id: "auth.expired",
            title: "Brain authentication expired",
            body: "Update your API key in Settings",
            category: Category.auth,
            userInfo: [:]
        )
    }

    private func postImmediate(
        id: String,
        title: String,
        body: String,
        category: String,
        userInfo: [String: Any]
    ) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = userInfo
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Task { @MainActor in
                    NotificationManager.shared.logImmediateFailure(error.localizedDescription)
                }
            }
        }
    }

    fileprivate func logImmediateFailure(_ message: String) {
        log(message)
    }

    private func log(_ message: String) {
        #if DEBUG
        print("[Penlo Notif] \(message)")
        #endif
    }
}
