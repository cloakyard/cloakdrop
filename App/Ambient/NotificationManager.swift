import Foundation
import UserNotifications
import DownloadModels

/// Local, on-device notifications for download completion and failure, with actionable
/// buttons. Nothing leaves the machine — this uses the system `UserNotifications` framework.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    struct Action: Sendable {
        enum Kind: Sendable { case open, reveal, retry }
        let kind: Kind
        let downloadID: UUID
    }

    /// Invoked when the user taps a notification action.
    var onAction: (@MainActor (Action) -> Void)?

    private let center = UNUserNotificationCenter.current()
    private let completedCategory = "cloakdrop.completed"
    private let failedCategory = "cloakdrop.failed"

    override init() {
        super.init()
        center.delegate = self
        registerCategories()
    }

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func registerCategories() {
        let open = UNNotificationAction(identifier: "open", title: String(localized: "Open"), options: [.foreground])
        let reveal = UNNotificationAction(identifier: "reveal", title: String(localized: "Reveal in Finder"), options: [])
        let retry = UNNotificationAction(identifier: "retry", title: String(localized: "Retry"), options: [])

        center.setNotificationCategories([
            UNNotificationCategory(identifier: completedCategory, actions: [open, reveal], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: failedCategory, actions: [retry], intentIdentifiers: [], options: [])
        ])
    }

    func notifyCompleted(_ download: Download) {
        post(
            title: String(localized: "Download Complete"),
            body: download.fileName,
            category: completedCategory,
            downloadID: download.id
        )
    }

    func notifyFailed(_ download: Download, reason: String) {
        post(
            title: String(localized: "Download Failed"),
            body: "\(download.fileName) — \(reason)",
            category: failedCategory,
            downloadID: download.id
        )
    }

    private func post(title: String, body: String, category: String, downloadID: UUID) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = category
        content.userInfo = ["downloadID": downloadID.uuidString]

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        center.add(request)
    }

    // MARK: UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let actionID = response.actionIdentifier
        if let idString = info["downloadID"] as? String, let id = UUID(uuidString: idString) {
            let kind: Action.Kind?
            switch actionID {
            case "open": kind = .open
            case "reveal": kind = .reveal
            case "retry": kind = .retry
            case UNNotificationDefaultActionIdentifier: kind = .reveal
            default: kind = nil
            }
            if let kind {
                Task { @MainActor [weak self] in self?.onAction?(Action(kind: kind, downloadID: id)) }
            }
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
