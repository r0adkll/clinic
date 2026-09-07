import AppKit
import UserNotifications
import os
import ClinicCore

/// System notifications and dock badge (ADR-033).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "notifications")
    var onActivate: ((SessionID) -> Void)?

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error { Self.log.error("notification auth: \(error, privacy: .public)") }
            Self.log.info("notification auth granted=\(granted)")
        }
    }

    func post(sessionId: SessionID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["sessionId": sessionId.rawValue]
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "\(sessionId.rawValue)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log.error("notification post: \(error, privacy: .public)") }
        }
    }

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard let raw = response.notification.request.content.userInfo["sessionId"] as? String else { return }
        let id = SessionID(raw)
        await MainActor.run {
            NSApp.activate()
            onActivate?(id)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
