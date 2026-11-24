import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

/// App delegate registering `UNUserNotificationCenterDelegate` and the `BGTaskScheduler`
/// app-refresh handler at launch before the first scene appears.
@MainActor
final class LaiBaoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onNotificationDeepLink: (@MainActor (String) -> Void)?
    private var pendingDeepLinkFormID: String?

    nonisolated override init() {
        super.init()
    }

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        registerBackgroundRefreshTask()
        return true
    }

    func attachDeepLinkHandler(_ handler: @escaping @MainActor (String) -> Void) {
        onNotificationDeepLink = handler
        if let pending = pendingDeepLinkFormID {
            pendingDeepLinkFormID = nil
            handler(pending)
        }
    }

    private nonisolated func registerBackgroundRefreshTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: ReminderScheduler.backgroundRefreshTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            refreshTask.expirationHandler = { [weak refreshTask] in
                refreshTask?.setTaskCompleted(success: false)
            }
            // Reschedule the next best-effort refresh window and complete cleanly.
            try? ReminderScheduler.scheduleBackgroundRefresh()
            refreshTask.setTaskCompleted(success: true)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let formID = (userInfo["formID"] as? String) ?? ""
        guard !formID.isEmpty else { return }

        await MainActor.run {
            if let handler = self.onNotificationDeepLink {
                handler(formID)
            } else {
                self.pendingDeepLinkFormID = formID
            }
        }
    }
}

@main
struct LaiBaoApp: App {
    @UIApplicationDelegateAdaptor(LaiBaoAppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(appState)
                .onAppear {
                    appDelegate.attachDeepLinkHandler { formID in
                        appState.handleNotificationDeepLink(formID: formID)
                    }
                }
        }
    }
}
