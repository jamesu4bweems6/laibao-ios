import BackgroundTasks
import SwiftUI
import UIKit
import UserNotifications

/// App delegate registering `UNUserNotificationCenterDelegate` and the `BGTaskScheduler`
/// app-refresh handler at launch before the first scene appears.
@MainActor
final class LaiBaoAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    var onNotificationDeepLink: (@MainActor (String, String?) -> Void)?
    private var pendingDeepLink: (formID: String, userID: String?)?

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

    func attachDeepLinkHandler(_ handler: @escaping @MainActor (String, String?) -> Void) {
        onNotificationDeepLink = handler
        if let pending = pendingDeepLink {
            pendingDeepLink = nil
            handler(pending.formID, pending.userID)
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
        let userID = userInfo["userID"] as? String
        guard !formID.isEmpty else { return }

        await MainActor.run {
            if let handler = self.onNotificationDeepLink {
                handler(formID, userID)
            } else {
                self.pendingDeepLink = (formID: formID, userID: userID)
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
            Group {
                if appState.isUnlocked {
                    RootTabView()
                } else {
                    AuthGateView()
                }
            }
            .environment(appState)
            .onAppear {
                appDelegate.attachDeepLinkHandler { formID, userID in
                    appState.handleNotificationDeepLink(formID: formID, userID: userID)
                }
            }
        }
    }
}
