import Foundation
import UserNotifications

/// Local notifications for download start/finish. Uses `UNUserNotificationCenter`
/// (no APNs / paid entitlement). Best-effort: failures are ignored so they never
/// block the download pipeline.
struct NotificationService: Sendable {
    private var center: UNUserNotificationCenter { .current() }

    /// Ask once for permission. Safe to call repeatedly.
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func notifyDownloadStarted(title: String) async {
        await post(title: "Downloading", body: title)
    }

    func notifyDownloadFinished(title: String) async {
        await post(title: "Download complete", body: title)
    }

    private func post(title: String, body: String) async {
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        try? await center.add(request)
    }
}
