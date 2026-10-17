import SwiftUI
import UserNotifications
import AppRefer

/// Sample host: the app owns the notification delegate and forwards to AppRefer, keeps
/// Support's handling, asks for permission itself, and navigates when AppRefer says so.
@main
struct EngagementHostApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var router = Router.shared
    var body: some Scene {
        WindowGroup {
            VStack(spacing: 12) {
                Text("Engagement host").font(.headline)
                Text(router.lastEvent).accessibilityIdentifier("lastEvent")
                Button("Allow notifications") { Task { await AppDelegate.askPermission() } }
            }
        }
    }
}

@MainActor
final class Router: ObservableObject {
    static let shared = Router()
    @Published var lastEvent = "none"
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    static let group = "group.com.apprefer.sample.engagementhost"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        // Simulator checks: quiet (provisional) delivery needs no prompt.
        if ProcessInfo.processInfo.arguments.contains("--provisional-notifications") {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .provisional]) { _, _ in }
        }
        Task { @MainActor in
            AppRefer.engagement.onNotificationEvent = { event in
                Router.shared.lastEvent = "\(event.kind.rawValue) \(event.destination ?? "-")"
            }
            // A sample host has no signed-in state to wait for.
            AppRefer.engagement.setNavigationReady(true)
        }
        Task {
            // No network calls happen unless a real SDK key is set here.
            guard let key = ProcessInfo.processInfo.environment["APPREFER_SAMPLE_KEY"] else { return }
            await AppRefer.configure(apiKey: key)
            await AppRefer.engagement.start(options: .init(appGroup: Self.group, notificationServiceExtension: true))
        }
        return true
    }

    static func askPermission() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        await AppRefer.engagement.refreshDeviceState()
        await MainActor.run { UIApplication.shared.registerForRemoteNotifications() }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await AppRefer.engagement.setDeviceToken(deviceToken) }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let options = await AppRefer.engagement.presentationOptions(for: notification) { return options }
        return [.banner, .list, .sound]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if await AppRefer.engagement.handle(response) { return }
        _ = await MainActor.run { AppRefer.support.handleNotification(response.notification.request.content.userInfo) }
    }
}
