import UserNotifications
import AppReferNotifications

/// The whole extension: AppRefer images for AppRefer notifications, everything else untouched.
final class NotificationService: UNNotificationServiceExtension {
    private let appRefer = AppReferNotificationService(configuration: .init(
        allowedImageHosts: ["assets.example.com"],
        appGroup: "group.com.apprefer.sample.engagementhost"))

    override func didReceive(_ request: UNNotificationRequest, withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void) {
        if appRefer.didReceive(request, withContentHandler: contentHandler) { return }
        contentHandler(request.content)
    }

    override func serviceExtensionTimeWillExpire() {
        appRefer.serviceExtensionTimeWillExpire()
    }
}
