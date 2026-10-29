import Foundation
import UserNotifications

/// macOS notifications; authorization is requested on first use.
@MainActor
enum Notifier {
    private static var authorized: Bool?

    static func post(id: String, title: String, body: String) {
        Task {
            let center = UNUserNotificationCenter.current()
            if authorized == nil {
                authorized = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }
}
