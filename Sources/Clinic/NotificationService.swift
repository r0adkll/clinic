import AppKit
import UserNotifications
import os
import ClinicCore

/// System notifications and dock badge (ADR-033).
@MainActor
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    nonisolated private static let log = Logger(subsystem: "com.r0adkll.clinic", category: "notifications")
    /// Clicked: which session, and the pull request the notification was about, when it was about one
    /// (ADR-128).
    var onActivate: ((SessionID, PullRequestRef?) -> Void)?
    /// Approve or Deny pressed on a "needs permission" notification (ADR-180).
    var onPermissionAnswer: ((SessionID, Bool) -> Void)?

    static let permissionCategory = "clinic.permission"
    static let approveAction = "clinic.permission.approve"
    static let denyAction = "clinic.permission.deny"

    func requestAuthorization() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // A "needs permission" notification carries the two answers the CLI's prompt takes (ADR-180).
        let approve = UNNotificationAction(identifier: Self.approveAction, title: "Approve", options: [])
        let deny = UNNotificationAction(identifier: Self.denyAction, title: "Deny", options: [.destructive])
        center.setNotificationCategories([UNNotificationCategory(identifier: Self.permissionCategory, actions: [approve, deny], intentIdentifiers: [])])
        center.requestAuthorization(options: [.alert, .badge]) { granted, error in
            if let error { Self.log.error("notification auth: \(error, privacy: .public)") }
            Self.log.info("notification auth granted=\(granted)")
        }
    }

    /// `silent` when Clinic has already played the sound itself, or sound is off (ADR-097).
    func post(sessionId: SessionID, title: String, body: String, silent: Bool, pullRequest: URL? = nil, answerable: Bool = false) {
        let content = UNMutableNotificationContent()
        if answerable { content.categoryIdentifier = Self.permissionCategory }
        content.title = title
        content.body = body
        content.userInfo = ["sessionId": sessionId.rawValue]
        if let pullRequest { content.userInfo["pullRequest"] = pullRequest.absoluteString }
        content.interruptionLevel = .timeSensitive
        if !silent { content.sound = .default }
        let request = UNNotificationRequest(identifier: "\(sessionId.rawValue)-\(Date().timeIntervalSince1970)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { Self.log.error("notification post: \(error, privacy: .public)") }
        }
    }

    func setBadge(_ count: Int) {
        NSApp.dockTile.badgeLabel = count > 0 ? String(count) : nil
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let raw = info["sessionId"] as? String else { return }
        let id = SessionID(raw)
        let ref = (info["pullRequest"] as? String).flatMap(URL.init(string:)).flatMap { PullRequestRef(url: $0) }
        let action = response.actionIdentifier
        await MainActor.run {
            // Approve and Deny answer from the notification, without bringing Clinic forward (ADR-180).
            if action == Self.approveAction || action == Self.denyAction {
                onPermissionAnswer?(id, action == Self.approveAction)
                return
            }
            NSApp.activate()
            onActivate?(id, ref)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }
}
