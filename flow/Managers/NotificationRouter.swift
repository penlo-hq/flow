//
//  NotificationRouter.swift
//  flow
//

import Foundation
import UserNotifications

extension Notification.Name {
    static let openDispatch = Notification.Name("com.getflow.flow.openDispatch")
    static let openBriefing = Notification.Name("com.getflow.flow.openBriefing")
    static let openSettings = Notification.Name("com.getflow.flow.openSettings")
    static let brainCredentialsSaved = Notification.Name("com.getflow.flow.brainCredentialsSaved")
    static let reopenOnboarding = Notification.Name("com.getflow.flow.reopenOnboarding")
}

enum NotificationRouter {
    static func handle(response: UNNotificationResponse) {
        let userInfo = response.notification.request.content.userInfo
        let category = response.notification.request.content.categoryIdentifier

        if let dispatchId = userInfo["dispatch_id"] as? String {
            NotificationCenter.default.post(
                name: .openDispatch,
                object: nil,
                userInfo: ["dispatch_id": dispatchId]
            )
            return
        }

        switch category {
        case NotificationManager.Category.dispatch:
            NotificationCenter.default.post(name: .openDispatch, object: nil, userInfo: userInfo)
        case NotificationManager.Category.briefing:
            NotificationCenter.default.post(name: .openBriefing, object: nil, userInfo: userInfo)
        case NotificationManager.Category.sync, NotificationManager.Category.auth:
            NotificationCenter.default.post(name: .openSettings, object: nil)
        default:
            if userInfo["route"] as? String == "dispatch" {
                NotificationCenter.default.post(name: .openDispatch, object: nil, userInfo: userInfo)
            }
        }
    }
}

final class PenloNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = PenloNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .badge]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        NotificationRouter.handle(response: response)
    }
}
