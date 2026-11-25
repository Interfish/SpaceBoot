import Foundation
import UserNotifications

/// Delivers native macOS UserNotifications under SpaceBoot's own bundle identity and App Icon
/// (avoiding `osascript`, which displays Apple's default Script Editor icon).
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    private var isAvailable: Bool {
        Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil
    }

    /// Registers the notification delegate at launch; authorization is requested lazily on the
    /// first `post(title:body:)` call so users have clear context and don't dismiss an early prompt.
    func configure() {
        guard isAvailable else {
            SpaceBootLogger.log("Notifications unavailable: process is not running inside an .app bundle")
            return
        }

        UNUserNotificationCenter.current().delegate = self
    }

    func post(title: String, body: String) {
        guard isAvailable else {
            SpaceBootLogger.log("Notification (no bundle): \(title) — \(body)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional:
                self?.enqueue(title: title, body: body, center: center)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        SpaceBootLogger.log("Notification authorization error: \(error.localizedDescription)")
                        return
                    }
                    SpaceBootLogger.log("Notification authorization granted=\(granted)")
                    if granted {
                        self?.enqueue(title: title, body: body, center: center)
                    } else {
                        SpaceBootLogger.log("Notification suppressed (permission declined): \(title) — \(body)")
                    }
                }
            case .denied:
                SpaceBootLogger.log("Notification suppressed (denied in System Settings): \(title) — \(body)")
            @unknown default:
                self?.enqueue(title: title, body: body, center: center)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Ensure banners still appear even while SpaceBoot's menu or floating window is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    // MARK: - Private Helpers

    private func enqueue(title: String, body: String, center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error {
                SpaceBootLogger.log("Failed to deliver notification '\(title)': \(error.localizedDescription)")
            }
        }
    }
}
