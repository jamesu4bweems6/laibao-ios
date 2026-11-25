import SwiftUI

/// Native iOS 26 / iOS 27 `TabView` root shell with `.sidebarAdaptable` and
/// `.tabBarMinimizeBehavior(.onScrollDown)` so the floating Liquid Glass tab bar
/// refracts cleanly above system content layers.
struct RootTabView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        TabView(selection: $state.selectedTab) {
            Tab("账号", systemImage: "person.crop.circle", value: AppTab.accounts) {
                AccountsView()
            }
            .badge(appState.accounts.isEmpty ? Text("!") : nil)

            Tab("填报", systemImage: "checkmark.circle", value: AppTab.checkin) {
                CheckinView()
            }

            Tab("记录", systemImage: "list.bullet.rectangle", value: AppTab.records) {
                RecordsView()
            }

            Tab("提醒", systemImage: "bell.badge", value: AppTab.reminders) {
                RemindersView()
            }

            Tab("点位", systemImage: "mappin.and.ellipse", value: AppTab.pois) {
                POIsView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let message = appState.toastMessage {
                GlassToastBanner(
                    message: message,
                    isError: appState.toastIsError,
                    onDismiss: {
                        appState.dismissToast()
                    }
                )
                .padding(.top, 6)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(10)
            }
        }
        .animation(.snappy(duration: 0.28), value: appState.toastMessage)
        .sensoryFeedback(trigger: appState.toastToken) { _, _ in
            guard appState.toastMessage != nil else { return nil }
            return appState.toastIsError ? .error : .success
        }
    }
}
