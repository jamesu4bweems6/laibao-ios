import Foundation
import Observation
import SwiftUI

/// Primary navigation destinations in `RootTabView`.
enum AppTab: String, Hashable, Sendable, CaseIterable {
    case accounts
    case checkin
    case records
    case reminders
    case pois
    case admin
}

/// Central application state coordinator owning local auth, per-user isolated workspace data,
/// cross-tab deep links, and toast feedback.
@Observable
@MainActor
final class AppState {
    // MARK: - Core Stores

    let authStore: LocalAuthStore
    let workspaceStore: UserWorkspaceStore
    let startupErrorMessage: String?

    // MARK: - Auth & Session State

    var currentUser: PublicLocalUser?
    var isUnlocked: Bool = false
    var needsSetup: Bool = false
    var biometricCandidateUser: PublicLocalUser?

    // MARK: - Navigation & Deep-Link Handoff

    var selectedTab: AppTab = .checkin
    var pendingFormID: String?
    var pendingEditFID: String?
    var pendingEditCatalogs: [CatalogValue]?
    var pendingCheckinRequestToken: UUID = UUID()

    private var deferredDeepLinkFormID: String?
    private var deferredDeepLinkUserID: String?

    // MARK: - Active User Workspace Cache

    var settings: UserWorkspaceSettings = UserWorkspaceSettings()
    var accounts: [LaiBaoAccount] = []
    var pois: [POIItem] = []
    var reminders: [ReminderPlan] = []
    var runLogs: [CheckinRunLog] = []

    // MARK: - Toast Feedback

    var toastMessage: String?
    var toastIsError: Bool = false
    private var toastDismissTask: Task<Void, Never>?

    // MARK: - Initialization

    init(
        authStore: LocalAuthStore? = nil,
        workspaceStore: UserWorkspaceStore? = nil
    ) {
        if let authStore {
            self.authStore = authStore
            self.startupErrorMessage = nil
        } else {
            do {
                self.authStore = try LocalAuthStore()
                self.startupErrorMessage = nil
            } catch {
                let fallbackDir = FileManager.default.temporaryDirectory
                    .appendingPathComponent("LaiBaoFallback-\(UUID().uuidString)", isDirectory: true)
                self.authStore = try! LocalAuthStore(rootDirectory: fallbackDir)
                self.startupErrorMessage = "读取本地认证文件失败：\(error.localizedDescription)"
            }
        }
        self.workspaceStore = workspaceStore ?? UserWorkspaceStore()
        refreshAuthGateState()
    }

    // MARK: - Auth Gate Helpers

    func refreshAuthGateState() {
        needsSetup = authStore.needsSetup
        if !needsSetup,
           BiometricAuthenticator.isAvailable,
           let candidate = authStore.mostRecentActiveUser(),
           let candidateSettings = try? workspaceStore.loadSettings(for: candidate.id),
           candidateSettings.biometricUnlockEnabled {
            biometricCandidateUser = candidate
        } else {
            biometricCandidateUser = nil
        }
    }

    func setupAdmin(username: String, displayName: String, password: String) async throws {
        let store = authStore
        let user = try await Task.detached(priority: .userInitiated) {
            try store.setupAdmin(username: username, displayName: displayName, password: password)
        }.value
        completeUnlock(for: user, preferAccountsWhenEmpty: true)
    }

    func login(username: String, password: String) async throws {
        let store = authStore
        let user = try await Task.detached(priority: .userInitiated) {
            try store.authenticate(username: username, password: password)
        }.value
        completeUnlock(for: user, preferAccountsWhenEmpty: false)
    }

    func unlockWithBiometrics() async throws {
        guard let candidate = biometricCandidateUser else {
            throw AuthSecurityError.biometricUnavailable("未找到已启用生物识别的本地账号")
        }
        let kind = BiometricAuthenticator.availableBiometry()
        let reason = "使用\(kind.displayName)解锁「\(candidate.displayName)」的来宝接龙工作区"
        let passed = try await BiometricAuthenticator.authenticate(reason: reason)
        guard passed else {
            throw AuthSecurityError.biometricFailed("身份验证未通过")
        }
        let store = authStore
        let userID = candidate.id
        let user = try await Task.detached(priority: .userInitiated) {
            try store.recordBiometricUnlock(userID: userID)
        }.value
        completeUnlock(for: user, preferAccountsWhenEmpty: false)
    }

    func logout() {
        currentUser = nil
        isUnlocked = false
        settings = UserWorkspaceSettings()
        accounts = []
        pois = []
        reminders = []
        runLogs = []
        pendingFormID = nil
        pendingEditFID = nil
        pendingEditCatalogs = nil
        selectedTab = .checkin
        refreshAuthGateState()
    }

    private func completeUnlock(for user: PublicLocalUser, preferAccountsWhenEmpty: Bool) {
        currentUser = user
        isUnlocked = true
        needsSetup = false
        refreshWorkspace()

        if let deferredForm = deferredDeepLinkFormID {
            let matchesUser = deferredDeepLinkUserID == nil || deferredDeepLinkUserID == user.id
            deferredDeepLinkFormID = nil
            deferredDeepLinkUserID = nil
            if matchesUser {
                openFormInCheckin(formID: deferredForm)
                return
            }
        }

        if preferAccountsWhenEmpty || accounts.isEmpty {
            selectedTab = .accounts
        } else {
            selectedTab = .checkin
        }
    }

    // MARK: - Workspace Loading & API Client Factory

    func refreshWorkspace() {
        guard let user = currentUser else { return }
        do {
            settings = try workspaceStore.loadSettings(for: user.id)
            accounts = try workspaceStore.loadAccounts(for: user.id)
            pois = try workspaceStore.loadPOIs(for: user.id)
            reminders = try workspaceStore.loadReminders(for: user.id)
            runLogs = try workspaceStore.loadRunLogs(for: user.id)
        } catch {
            showToast("加载本地工作区失败：\(error.localizedDescription)", isError: true)
        }
    }

    var activeAccount: LaiBaoAccount? {
        accounts.first(where: { $0.name == settings.activeAccount }) ?? accounts.first
    }

    func makeAPIClient(accountName: String? = nil) throws -> LaiBaoAPIClient {
        guard let user = currentUser else {
            throw AuthSecurityError.userNotFound
        }
        return try workspaceStore.makeAPIClient(accountName: accountName, for: user.id)
    }

    func saveSettings(_ updated: UserWorkspaceSettings) throws {
        guard let user = currentUser else {
            throw AuthSecurityError.userNotFound
        }
        try workspaceStore.saveSettings(updated, for: user.id)
        settings = updated
    }

    // MARK: - Deep-Link & Cross-Tab Handoff

    func openFormInCheckin(
        formID: String,
        editFID: String? = nil,
        editCatalogs: [CatalogValue]? = nil
    ) {
        let trimmedFormID = formID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFormID.isEmpty else { return }
        pendingFormID = trimmedFormID
        pendingEditFID = editFID?.trimmingCharacters(in: .whitespacesAndNewlines)
        pendingEditCatalogs = editCatalogs
        pendingCheckinRequestToken = UUID()
        selectedTab = .checkin
    }

    func consumePendingCheckinHandoff() -> (formID: String, editFID: String?, editCatalogs: [CatalogValue]?)? {
        guard let formID = pendingFormID, !formID.isEmpty else { return nil }
        let fid = pendingEditFID
        let catalogs = pendingEditCatalogs
        pendingFormID = nil
        pendingEditFID = nil
        pendingEditCatalogs = nil
        return (formID: formID, editFID: fid, editCatalogs: catalogs)
    }

    func handleNotificationDeepLink(formID: String, userID: String?) {
        let trimmed = formID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isUnlocked, let current = currentUser {
            if let userID, !userID.isEmpty, userID != current.id {
                showToast("该提醒属于其他本地账号，请切换账号后填报表单 \(trimmed)", isError: false)
                return
            }
            openFormInCheckin(formID: trimmed)
            showToast("已从提醒定位到表单 \(trimmed)")
        } else {
            deferredDeepLinkFormID = trimmed
            deferredDeepLinkUserID = userID
        }
    }

    // MARK: - Reminder One-Tap Execution

    func executeReminderPlan(
        _ plan: ReminderPlan,
        dryRun: Bool = false
    ) async throws -> (result: SubmitResult?, payload: SubmitPayload, warnings: [String]) {
        guard let user = currentUser else {
            throw AuthSecurityError.userNotFound
        }
        let client = try makeAPIClient(accountName: plan.accountName)
        let parsed = try await FormLinkParser.resolveFormID(plan.formID)
        let form = try await client.formDetail(formID: parsed.formID)
        let userPOIs = (try? workspaceStore.loadPOIs(for: user.id)) ?? pois

        let draft = CheckinDraft(
            formID: parsed.formID,
            lat: plan.lat,
            lng: plan.lng,
            addr: plan.addr,
            title: plan.title,
            wgs84: plan.wgs84,
            jitterMeters: plan.jitterMeters,
            usePOIPool: plan.usePOIPool,
            pois: plan.usePOIPool ? userPOIs : [],
            dryRun: dryRun
        )
        let built = try PayloadBuilder.build(form: form, draft: draft)

        var submitResult: SubmitResult?
        var statusText = dryRun ? "预览成功" : "提交成功"
        var success = true

        if !dryRun {
            do {
                let res = try await client.submit(formID: parsed.formID, payload: built.payload)
                submitResult = res
                if !res.fid.isEmpty {
                    statusText = "成功 (fid: \(res.fid))"
                }
            } catch {
                success = false
                statusText = "失败: \(error.localizedDescription)"
                let failLog = CheckinRunLog(
                    planID: plan.id,
                    formID: parsed.formID,
                    formTitle: form.displayTitle,
                    accountName: plan.accountName,
                    dryRun: false,
                    success: false,
                    fid: "",
                    message: error.localizedDescription
                )
                try? workspaceStore.appendRunLog(failLog, for: user.id)
                var updatedPlan = plan
                updatedPlan.lastTriggeredAt = Date()
                updatedPlan.lastRunStatus = statusText
                _ = try? workspaceStore.upsertReminder(updatedPlan, for: user.id)
                refreshWorkspace()
                throw error
            }
        }

        let log = CheckinRunLog(
            planID: plan.id,
            formID: parsed.formID,
            formTitle: form.displayTitle,
            accountName: plan.accountName,
            dryRun: dryRun,
            success: success,
            fid: submitResult?.fid ?? "",
            message: built.warnings.isEmpty ? statusText : "\(statusText)；提示：\(built.warnings.joined(separator: "；"))"
        )
        try? workspaceStore.appendRunLog(log, for: user.id)

        if !dryRun {
            var updatedPlan = plan
            updatedPlan.lastTriggeredAt = Date()
            updatedPlan.lastRunStatus = statusText
            _ = try? workspaceStore.upsertReminder(updatedPlan, for: user.id)
        }
        refreshWorkspace()
        return (result: submitResult, payload: built.payload, warnings: built.warnings)
    }

    // MARK: - Toast Presentation

    func showToast(_ message: String, isError: Bool = false) {
        toastDismissTask?.cancel()
        withAnimation(.snappy(duration: 0.28)) {
            toastMessage = message
            toastIsError = isError
        }
        toastDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3.5))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    self?.toastMessage = nil
                }
            }
        }
    }

    func dismissToast() {
        toastDismissTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            toastMessage = nil
        }
    }
}
