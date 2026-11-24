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
}

/// Central application state coordinator owning single-user local workspace data,
/// Keychain-backed API client creation, cross-tab deep links, and toast feedback.
@Observable
@MainActor
final class AppState {
    // MARK: - Core Store

    let workspaceStore: UserWorkspaceStore

    // MARK: - Navigation & Deep-Link Handoff

    var selectedTab: AppTab = .checkin
    var pendingFormID: String?
    var pendingEditFID: String?
    var pendingEditCatalogs: [CatalogValue]?
    var pendingCheckinRequestToken: UUID = UUID()

    // MARK: - Local Workspace Cache

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

    init(workspaceStore: UserWorkspaceStore? = nil) {
        self.workspaceStore = workspaceStore ?? UserWorkspaceStore()
        refreshWorkspace()
        if accounts.isEmpty {
            selectedTab = .accounts
        }
    }

    // MARK: - Workspace Loading & API Client Factory

    func refreshWorkspace() {
        do {
            settings = try workspaceStore.loadSettings()
            accounts = try workspaceStore.loadAccounts()
            pois = try workspaceStore.loadPOIs()
            reminders = try workspaceStore.loadReminders()
            runLogs = try workspaceStore.loadRunLogs()
        } catch {
            showToast("加载本地工作区失败：\(error.localizedDescription)", isError: true)
        }
    }

    var activeAccount: LaiBaoAccount? {
        accounts.first(where: { $0.name == settings.activeAccount }) ?? accounts.first
    }

    func makeAPIClient(accountName: String? = nil) throws -> LaiBaoAPIClient {
        try workspaceStore.makeAPIClient(accountName: accountName)
    }

    func saveSettings(_ updated: UserWorkspaceSettings) throws {
        try workspaceStore.saveSettings(updated)
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

    func handleNotificationDeepLink(formID: String) {
        let trimmed = formID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        openFormInCheckin(formID: trimmed)
        showToast("已从提醒定位到表单 \(trimmed)")
    }

    // MARK: - Reminder One-Tap Execution

    func executeReminderPlan(
        _ plan: ReminderPlan,
        dryRun: Bool = false
    ) async throws -> (result: SubmitResult?, payload: SubmitPayload, warnings: [String]) {
        let client = try makeAPIClient(accountName: plan.accountName)
        let parsed = try await FormLinkParser.resolveFormID(plan.formID)
        let form = try await client.formDetail(formID: parsed.formID)
        let currentPOIs = (try? workspaceStore.loadPOIs()) ?? pois

        let draft = CheckinDraft(
            formID: parsed.formID,
            lat: plan.lat,
            lng: plan.lng,
            addr: plan.addr,
            title: plan.title,
            wgs84: plan.wgs84,
            jitterMeters: plan.jitterMeters,
            usePOIPool: plan.usePOIPool,
            pois: plan.usePOIPool ? currentPOIs : [],
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
                try? workspaceStore.appendRunLog(failLog)
                var updatedPlan = plan
                updatedPlan.lastTriggeredAt = Date()
                updatedPlan.lastRunStatus = statusText
                _ = try? workspaceStore.upsertReminder(updatedPlan)
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
        try? workspaceStore.appendRunLog(log)

        if !dryRun {
            var updatedPlan = plan
            updatedPlan.lastTriggeredAt = Date()
            updatedPlan.lastRunStatus = statusText
            _ = try? workspaceStore.upsertReminder(updatedPlan)
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
