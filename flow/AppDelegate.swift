//
//  AppDelegate.swift
//  flow
//

import BackgroundTasks
import UIKit
import UserNotifications

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let bgTaskID = "com.getflow.flow.calendar-refresh"

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = PenloNotificationDelegate.shared

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.bgTaskID, using: nil) { task in
            guard let refresh = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            refresh.expirationHandler = { refresh.setTaskCompleted(success: false) }
            Task {
                let events = await MainActor.run { CalendarManager().upcomingEvents() }
                await NotificationManager.shared.refreshNotifications(for: events)
                self.scheduleBackgroundRefresh()
                refresh.setTaskCompleted(success: true)
            }
        }
        scheduleBackgroundRefresh()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        PushRegistrationService.cacheToken(hex)
        NotificationCenter.default.post(
            name: .apnsTokenReceived,
            object: nil,
            userInfo: ["token": hex]
        )
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        #if DEBUG
        print("[Penlo APNs] Registration failed: \(error.localizedDescription)")
        #endif
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        completionHandler(.noData)
    }

    func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskID)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}

extension Notification.Name {
    static let apnsTokenReceived = Notification.Name("com.getflow.flow.apnsToken")
}

enum PushRegistrationService {
    private static let remotePushRegisteredKey = "com.getflow.flow.remotePushRegistered"
    private(set) static var cachedToken: String?

    static func cacheToken(_ token: String) {
        cachedToken = token
    }

    @MainActor
    static func registerCachedTokenIfPossible() async {
        guard let token = cachedToken else { return }
        await registerTokenWithBrain(token)
    }

    @MainActor
    static func registerTokenWithBrain(_ token: String) async {
        cacheToken(token)
        guard let base = brainBaseURL(),
              let key = KeychainStore.readBrainKey()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else {
            return
        }
        guard let url = URL(string: "/api/v1/notifications/register", relativeTo: base) else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: String] = ["device_token": token, "platform": "ios"]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            if let http = response as? HTTPURLResponse, http.statusCode == 204 {
                UserDefaults.standard.set(true, forKey: remotePushRegisteredKey)
                #if DEBUG
                print("[Penlo APNs] Token registered")
                #endif
            }
        } catch {
            #if DEBUG
            print("[Penlo APNs] Token registration failed: \(error.localizedDescription)")
            #endif
        }
    }

    private static func brainBaseURL() -> URL? {
        guard let raw = KeychainStore.readBrainURL() else { return nil }
        guard var components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        components.path = ""
        components.query = nil
        components.fragment = nil
        return components.url
    }
}
