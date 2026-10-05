import AppKit
import Observation
import UserNotifications

/// macOS notifications (Settings → Animations): one per session, replaced when it changes,
/// withdrawn once you have answered. Clicking one opens the session.
@MainActor
@Observable
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Whether macOS lets Halo post notifications; nil until asked.
    private(set) var allowed: Bool?
    /// Opens a session from its Desktop id (`local_…`).
    @ObservationIgnored var onOpen: ((String) -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    func setUp() {
        center.delegate = self
        Task { await refresh() }
    }

    func refresh() async {
        let status = await center.notificationSettings().authorizationStatus
        allowed = status == .notDetermined ? nil : (status == .authorized || status == .provisional)
    }

    /// Asks macOS once (its own dialog); afterwards the choice lives in System Settings.
    func requestPermission() async {
        _ = try? await center.requestAuthorization(options: [.alert])
        await refresh()
    }

    func post(sessionId: String, title: String, subtitle: String, body: String?, host: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        if let body { content.body = body }
        if let host { content.userInfo = ["host": host] }
        content.threadIdentifier = sessionId
        // Same id per session: a new state replaces the previous notification.
        center.add(UNNotificationRequest(identifier: Self.identifier(sessionId), content: content, trigger: nil))
    }

    func withdraw(sessionId: String) {
        center.removeDeliveredNotifications(withIdentifiers: [Self.identifier(sessionId)])
    }

    private static func identifier(_ sessionId: String) -> String { "halo.session.\(sessionId)" }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler:
                                            @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let host = response.notification.request.content.userInfo["host"] as? String
        Task { @MainActor in
            if let host { Notifier.shared.onOpen?(host) }
        }
        completionHandler()
    }
}
