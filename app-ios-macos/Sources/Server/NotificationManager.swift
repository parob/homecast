import Foundation
import UIKit
import UserNotifications

#if targetEnvironment(macCatalyst)

/// Manages local and remote push notifications for Homecast.
///
/// Local notifications: shown immediately when the relay's automation engine fires a Notify action.
/// Remote notifications: APNs token registration for receiving push from the cloud server.
@MainActor
class NotificationManager: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()

    @Published private(set) var isAuthorized = false
    @Published private(set) var apnsToken: String?

    /// Category identifier for notifications with action buttons
    private static let categoryId = "homecast.automation.notify"

    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Permission

    /// Request notification permission. Call on first automation Notify or from settings.
    func requestPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current().requestAuthorization(
                options: [.alert, .sound, .badge]
            )
            isAuthorized = granted
            if granted {
                registerForRemoteNotifications()
            }
            return granted
        } catch {
            NSLog("[NotificationManager] Permission request failed: %@", error.localizedDescription)
            return false
        }
    }

    /// Check current authorization status.
    func checkAuthorizationStatus() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        isAuthorized = settings.authorizationStatus == .authorized
    }

    // MARK: - Local Notifications (Relay → macOS banner)

    /// Show a local notification immediately. Called when the automation engine fires a Notify action.
    func showLocalNotification(
        title: String?,
        message: String,
        data: [String: Any]? = nil
    ) {
        let content = UNMutableNotificationContent()
        content.title = title ?? "Homecast"
        content.body = message
        content.sound = .default

        // Store data for action handling
        if let data = data {
            content.userInfo = data
        }

        // Register action buttons if present
        if let actions = data?["actions"] as? [[String: String]] {
            let notificationActions = actions.prefix(3).compactMap { action -> UNNotificationAction? in
                guard let actionId = action["action"], let actionTitle = action["title"] else { return nil }
                return UNNotificationAction(
                    identifier: actionId,
                    title: actionTitle,
                    options: .foreground
                )
            }

            if !notificationActions.isEmpty {
                let category = UNNotificationCategory(
                    identifier: Self.categoryId,
                    actions: notificationActions,
                    intentIdentifiers: [],
                    options: []
                )
                UNUserNotificationCenter.current().setNotificationCategories([category])
                content.categoryIdentifier = Self.categoryId
            }
        }

        let request = UNNotificationRequest(
            identifier: "homecast-notify-\(UUID().uuidString)",
            content: content,
            trigger: nil // Deliver immediately
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                NSLog("[NotificationManager] Failed to show notification: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Remote Notifications (APNs)

    /// Register for APNs remote notifications.
    private func registerForRemoteNotifications() {
        DispatchQueue.main.async {
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    /// Called from AppDelegate when APNs token is received.
    func didRegisterForRemoteNotifications(deviceToken: Data) {
        let tokenString = deviceToken.map { String(format: "%02.2hhx", $0) }.joined()
        apnsToken = tokenString
        NSLog("[NotificationManager] APNs token: %@...", String(tokenString.prefix(16)))
        // The web app will read this token via the JS bridge and register it with the server
    }

    /// Called from AppDelegate when APNs registration fails.
    func didFailToRegisterForRemoteNotifications(error: Error) {
        NSLog("[NotificationManager] APNs registration failed: %@", error.localizedDescription)
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Handle notification taps and action button presses.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let actionIdentifier = response.actionIdentifier
        let userInfo = response.notification.request.content.userInfo

        if actionIdentifier != UNNotificationDefaultActionIdentifier &&
           actionIdentifier != UNNotificationDismissActionIdentifier {
            // User tapped an action button — this will be forwarded to the automation engine
            NSLog("[NotificationManager] Action tapped: %@", actionIdentifier)
            NotificationCenter.default.post(
                name: .notificationActionTapped,
                object: nil,
                userInfo: [
                    "action": actionIdentifier,
                    "data": userInfo,
                ]
            )
        }

        completionHandler()
    }

    /// Show notifications even when the app is in the foreground.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

extension Notification.Name {
    static let notificationActionTapped = Notification.Name("homecast.notificationActionTapped")
}

#else

// iOS stub — push notification support will be added when iOS app is ready
@MainActor
class NotificationManager: NSObject, ObservableObject {
    static let shared = NotificationManager()
    var isAuthorized = false
    var apnsToken: String?

    func requestPermission() async -> Bool { false }
    func checkAuthorizationStatus() async {}
    func showLocalNotification(title: String?, message: String, data: [String: Any]? = nil) {}
    func didRegisterForRemoteNotifications(deviceToken: Data) {}
    func didFailToRegisterForRemoteNotifications(error: Error) {}
}

#endif
