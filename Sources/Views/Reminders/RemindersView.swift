import SwiftUI
import UserNotifications

/// Local scheduled check-in reminder plans + `UNUserNotificationCenter` calendar trigger sync
/// + one-tap immediate execution + sanitized run log history.
struct RemindersView: View {
    @Environment(AppState.self) private var appState

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var editingPlan: ReminderPlan?
    @State private var isCreatingNew: Bool = false
    @State private var runningPlanID: String?
    @State private var showClearLogsConfirm: Bool = false

    var body: some View {
        NavigationStack {
            List {
                sandboxNoticeSection
                plansSection
                runLogsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("本地提醒")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isCreatingNew = true
                    } label: {
                        Label("新建提醒", systemImage: "plus")
                    }
                }
            }
            .task {
                await refreshNotificationStatus()
            }
            .sheet(isPresented: $isCreatingNew) {
                ReminderEditorSheet(existingPlan: nil) { saved in
                    saveAndSync(plan: saved)
                }
            }
            .sheet(item: $editingPlan) { plan in
                ReminderEditorSheet(existingPlan: plan) { saved in
                    saveAndSync(plan: saved)
                }
            }
            .confirmationDialog(
                "清空所有本地执行日志？",
                isPresented: $showClearLogsConfirm,
                titleVisibility: .visible
            ) {
                Button("清空日志", role: .destructive) {
                    clearLogs()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // MARK: - Sections

    private var sandboxNoticeSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    GlassStatusPill(
                        title: notificationStatusTitle,
                        systemImage: notificationStatusIcon,
                        tint: notificationStatusTint
                    )
                    Spacer()
                    if authStatus == .notDetermined {
                        Button("开启通知权限") {
                            requestNotificationPermission()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    } else {
                        Button("重新同步通知") {
                            syncAllNotifications()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }

                Text("受 iOS 沙盒机制限制，定时计划采用本地日历通知（UNUserNotificationCenter）准点推送提醒，轻点通知可直接打开对应表单一键打卡；后台应用刷新（BGAppRefreshTask）由系统按电量与习惯动态调度，不保证准点静默执行。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("iOS 本地提醒与后台说明")
        }
    }

    private var plansSection: some View {
        Section("打卡提醒计划（\(appState.reminders.count)）") {
            if appState.reminders.isEmpty {
                ContentUnavailableView(
                    "暂无提醒计划",
                    systemImage: "bell.slash",
                    description: Text("点击右上角「+」创建多时间点 / 星期循环打卡提醒。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(appState.reminders) { plan in
                    reminderRow(plan)
                }
            }
        }
    }

    private func reminderRow(_ plan: ReminderPlan) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(plan.name.isEmpty ? "未命名提醒" : plan.name)
                        .font(.headline)
                    Text("表单：\(plan.formID) · 账号：\(plan.accountName)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { plan.enabled },
                    set: { next in
                        var updated = plan
                        updated.enabled = next
                        saveAndSync(plan: updated)
                    }
                ))
                .labelsHidden()
            }

            HStack(spacing: 8) {
                GlassStatusPill(
                    title: plan.clocks.joined(separator: ", "),
                    systemImage: "clock",
                    tint: plan.enabled ? .accentColor : .gray
                )
                GlassStatusPill(
                    title: weekdaySummary(plan.weekdays),
                    systemImage: "calendar",
                    tint: .secondary
                )
            }

            if plan.enabled,
               let nextDate = try? ReminderScheduler.nextTriggerDate(clocks: plan.clocks, weekdays: plan.weekdays) {
                Text("下次提醒：\(nextDate.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(plan.usePOIPool
                 ? "定位：从 POI 点位池随机抽取 · 抖动 \(Int(plan.jitterMeters))m"
                 : "定位：\(plan.title.isEmpty ? (plan.addr.isEmpty ? String(format: "%.6f,%.6f", plan.lat, plan.lng) : plan.addr) : plan.title) · 抖动 \(Int(plan.jitterMeters))m")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !plan.lastRunStatus.isEmpty {
                let timeText = plan.lastTriggeredAt?.formatted(date: .omitted, time: .shortened) ?? ""
                Text("最近执行\(timeText.isEmpty ? "" : "（\(timeText)）")：\(plan.lastRunStatus)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 10) {
                Button {
                    runPlanNow(plan)
                } label: {
                    HStack(spacing: 6) {
                        if runningPlanID == plan.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("立即执行一次")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(runningPlanID != nil)

                Button {
                    appState.openFormInCheckin(formID: plan.formID)
                } label: {
                    Label("打开填报", systemImage: "arrow.up.forward.app")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    editingPlan = plan
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                deletePlan(plan)
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var runLogsSection: some View {
        Section {
            if appState.runLogs.isEmpty {
                Text("暂无执行日志（提交成功、失败或立即执行提醒计划后会自动脱敏记录）。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(appState.runLogs.prefix(30)) { log in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Image(systemName: log.success ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(log.success ? .green : .red)
                            Text(log.formTitle.isEmpty ? log.formID : log.formTitle)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Spacer()
                            Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text(log.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if !log.fid.isEmpty || !log.accountName.isEmpty {
                            Text([
                                log.accountName.isEmpty ? nil : "账号: \(log.accountName)",
                                log.fid.isEmpty ? nil : "fid: \(log.fid)"
                            ].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            HStack {
                Text("脱敏执行日志（\(appState.runLogs.count)）")
                Spacer()
                if !appState.runLogs.isEmpty {
                    Button("清空") {
                        showClearLogsConfirm = true
                    }
                    .font(.caption)
                }
            }
        }
    }

    // MARK: - Helpers & Actions

    private var notificationStatusTitle: String {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: return "通知已授权"
        case .denied: return "通知已拒绝（请在系统设置开启）"
        case .notDetermined: return "尚未申请通知权限"
        @unknown default: return "通知状态未知"
        }
    }

    private var notificationStatusIcon: String {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: return "bell.badge.fill"
        case .denied: return "bell.slash.fill"
        default: return "bell"
        }
    }

    private var notificationStatusTint: Color {
        switch authStatus {
        case .authorized, .provisional, .ephemeral: return .green
        case .denied: return .red
        default: return .orange
        }
    }

    private func weekdaySummary(_ weekdays: [Int]) -> String {
        let sorted = Set(weekdays).filter { (1...7).contains($0) }.sorted()
        if sorted.isEmpty || sorted.count == 7 { return "每天" }
        if sorted == [1, 2, 3, 4, 5] { return "工作日" }
        if sorted == [6, 7] { return "周末" }
        let names = ["", "一", "二", "三", "四", "五", "六", "日"]
        return "周" + sorted.map { names[$0] }.joined(separator: "、")
    }

    private func refreshNotificationStatus() async {
        authStatus = await ReminderScheduler.notificationAuthorizationStatus()
    }

    private func requestNotificationPermission() {
        Task {
            do {
                let granted = try await ReminderScheduler.requestNotificationAuthorization()
                await refreshNotificationStatus()
                if granted {
                    syncAllNotifications()
                    appState.showToast("通知权限已开启并同步提醒")
                } else {
                    appState.showToast("通知权限未授予", isError: true)
                }
            } catch {
                appState.showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func saveAndSync(plan: ReminderPlan) {
        guard let user = appState.currentUser else { return }
        do {
            let updatedList = try appState.workspaceStore.upsertReminder(plan, for: user.id)
            appState.refreshWorkspace()
            Task {
                if plan.enabled && authStatus == .notDetermined {
                    _ = try? await ReminderScheduler.requestNotificationAuthorization()
                    await refreshNotificationStatus()
                }
                do {
                    try await ReminderScheduler.syncNotifications(for: updatedList, userID: user.id)
                    if updatedList.contains(where: \.enabled) {
                        try? ReminderScheduler.scheduleBackgroundRefresh()
                    }
                    appState.showToast("提醒计划「\(plan.name)」已保存并同步系统通知")
                } catch {
                    appState.showToast("计划已保存，但通知同步失败：\(error.localizedDescription)", isError: true)
                }
            }
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func syncAllNotifications() {
        guard let user = appState.currentUser else { return }
        let plans = appState.reminders
        Task {
            do {
                try await ReminderScheduler.syncNotifications(for: plans, userID: user.id)
                if plans.contains(where: \.enabled) {
                    try? ReminderScheduler.scheduleBackgroundRefresh()
                }
                appState.showToast("已重新同步 \(plans.filter(\.enabled).count) 个启用的提醒计划")
            } catch {
                appState.showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func deletePlan(_ plan: ReminderPlan) {
        guard let user = appState.currentUser else { return }
        do {
            let remaining = try appState.workspaceStore.deleteReminder(id: plan.id, for: user.id)
            appState.refreshWorkspace()
            Task {
                try? await ReminderScheduler.syncNotifications(for: remaining, userID: user.id)
            }
            appState.showToast("已删除提醒「\(plan.name)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func runPlanNow(_ plan: ReminderPlan) {
        runningPlanID = plan.id
        Task {
            defer { runningPlanID = nil }
            do {
                let outcome = try await appState.executeReminderPlan(plan, dryRun: false)
                let fid = outcome.result?.fid ?? ""
                appState.showToast("提醒「\(plan.name)」执行成功\(fid.isEmpty ? "" : " · fid: \(fid)")")
            } catch {
                appState.showToast("执行失败：\(error.localizedDescription)", isError: true)
            }
        }
    }

    private func clearLogs() {
        guard let user = appState.currentUser else { return }
        do {
            try appState.workspaceStore.clearRunLogs(for: user.id)
            appState.refreshWorkspace()
            appState.showToast("执行日志已清空")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }
}

// MARK: - Reminder Editor Sheet

private struct ReminderEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existingPlan: ReminderPlan?
    let onSave: (ReminderPlan) -> Void

    @State private var name: String
    @State private var formInput: String
    @State private var accountName: String
    @State private var clocksText: String
    @State private var selectedWeekdays: Set<Int>
    @State private var usePOIPool: Bool
    @State private var latText: String
    @State private var lngText: String
    @State private var addr: String
    @State private var title: String
    @State private var wgs84: Bool
    @State private var jitterMeters: Double
    @State private var enabled: Bool

    @State private var showMyForms = false
    @State private var showMapPicker = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private struct WeekdayOption: Identifiable {
        let id: Int
        let label: String
    }

    private let weekdayOptions: [WeekdayOption] = [
        WeekdayOption(id: 1, label: "一"),
        WeekdayOption(id: 2, label: "二"),
        WeekdayOption(id: 3, label: "三"),
        WeekdayOption(id: 4, label: "四"),
        WeekdayOption(id: 5, label: "五"),
        WeekdayOption(id: 6, label: "六"),
        WeekdayOption(id: 7, label: "日")
    ]

    init(existingPlan: ReminderPlan?, onSave: @escaping (ReminderPlan) -> Void) {
        self.existingPlan = existingPlan
        self.onSave = onSave
        _name = State(initialValue: existingPlan?.name ?? "")
        _formInput = State(initialValue: existingPlan?.formID ?? "")
        _accountName = State(initialValue: existingPlan?.accountName ?? "default")
        _clocksText = State(initialValue: existingPlan?.clocks.joined(separator: ",") ?? "08:45,18:05")
        _selectedWeekdays = State(initialValue: Set(existingPlan?.weekdays ?? []))
        _usePOIPool = State(initialValue: existingPlan?.usePOIPool ?? false)
        let initLat = existingPlan.flatMap { $0.lat != 0 ? String(format: "%.6f", $0.lat) : nil } ?? ""
        let initLng = existingPlan.flatMap { $0.lng != 0 ? String(format: "%.6f", $0.lng) : nil } ?? ""
        _latText = State(initialValue: initLat)
        _lngText = State(initialValue: initLng)
        _addr = State(initialValue: existingPlan?.addr ?? "")
        _title = State(initialValue: existingPlan?.title ?? "")
        _wgs84 = State(initialValue: existingPlan?.wgs84 ?? false)
        _jitterMeters = State(initialValue: existingPlan?.jitterMeters ?? 15)
        _enabled = State(initialValue: existingPlan?.enabled ?? true)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("计划名称（如 早晚打卡）", text: $name)
                    HStack {
                        TextField("表单 ID 或分享链接", text: $formInput)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button("选择") {
                            showMyForms = true
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    if !appState.accounts.isEmpty {
                        Picker("使用账号", selection: $accountName) {
                            ForEach(appState.accounts) { account in
                                Text(account.name).tag(account.name)
                            }
                        }
                    } else {
                        TextField("账号标识", text: $accountName)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    Toggle("启用该提醒计划", isOn: $enabled)
                }

                Section("提醒时间与重复") {
                    TextField("多时间点（HH:mm 逗号分隔，如 08:45,18:05）", text: $clocksText)
                        .font(.body.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    VStack(alignment: .leading, spacing: 8) {
                        Text(selectedWeekdays.isEmpty ? "重复星期：每天（点击以下按钮限定星期）" : "重复星期（已选 \(selectedWeekdays.count) 天）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 6) {
                            ForEach(weekdayOptions) { option in
                                let active = selectedWeekdays.contains(option.id)
                                Button {
                                    if active {
                                        selectedWeekdays.remove(option.id)
                                    } else {
                                        selectedWeekdays.insert(option.id)
                                    }
                                } label: {
                                    Text(option.label)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 8)
                                        .background(
                                            active ? Color.accentColor : Color(.tertiarySystemFill),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(active ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("定位参数（用于「立即执行一次」）") {
                    Toggle("从 POI 点位池随机抽取", isOn: $usePOIPool)

                    if !usePOIPool {
                        Button {
                            showMapPicker = true
                        } label: {
                            Label("在地图上选取固定坐标", systemImage: "map.fill")
                        }
                        .buttonStyle(.glass)

                        HStack {
                            TextField("纬度 lat", text: $latText)
                                .keyboardType(.decimalPad)
                                .font(.body.monospaced())
                            TextField("经度 lng", text: $lngText)
                                .keyboardType(.decimalPad)
                                .font(.body.monospaced())
                        }
                        Toggle("输入坐标为 WGS-84", isOn: $wgs84)
                        TextField("地点名称（title）", text: $title)
                        TextField("详细地址（address）", text: $addr)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("随机抖动半径")
                            Spacer()
                            Text("\(Int(jitterMeters)) 米")
                                .font(.caption.monospacedDigit())
                        }
                        Slider(value: $jitterMeters, in: 0...200, step: 5)
                    }
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingPlan == nil ? "新建提醒计划" : "编辑提醒计划")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { savePlan() }
                        .disabled(isSaving)
                }
            }
            .sheet(isPresented: $showMyForms) {
                MyFormsSheet { summary in
                    formInput = summary.formID
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        name = summary.title
                    }
                }
            }
            .sheet(isPresented: $showMapPicker) {
                let lat = Double(latText) ?? 0
                let lng = Double(lngText) ?? 0
                let initPt: GeoPoint? = (try? GeoMath.validateCoord(lat: lat, lng: lng)) != nil
                    ? (wgs84 ? GeoMath.wgs84ToGCJ02(GeoPoint(lat: lat, lng: lng)) : GeoPoint(lat: lat, lng: lng))
                    : nil
                MapPickerSheet(
                    initialPoint: initPt,
                    initialAddr: addr,
                    initialTitle: title,
                    jitterRadiusMeters: jitterMeters,
                    savedPOIs: appState.pois,
                    confirmButtonTitle: "确认使用该点位"
                ) { selection in
                    let pt = wgs84 ? GeoMath.gcj02ToWGS84(selection.point) : selection.point
                    latText = String(format: "%.6f", pt.lat)
                    lngText = String(format: "%.6f", pt.lng)
                    addr = selection.addr
                    title = selection.title
                }
            }
            .onAppear {
                if existingPlan == nil, let active = appState.activeAccount {
                    accountName = active.name
                }
            }
        }
    }

    private func savePlan() {
        errorMessage = nil
        let parsedClocks: [ReminderClock]
        do {
            parsedClocks = try ReminderScheduler.parseClockList(clocksText)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let latVal = Double(latText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        let lngVal = Double(lngText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        if !usePOIPool && (latVal != 0 || lngVal != 0) {
            do {
                try GeoMath.validateCoord(lat: latVal, lng: lngVal)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        }

        isSaving = true
        let rawFormInput = formInput
        Task {
            defer { isSaving = false }
            do {
                let parsedLink = try await FormLinkParser.resolveFormID(rawFormInput)
                let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let cleanAccount = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
                let plan = ReminderPlan(
                    id: existingPlan?.id ?? UUID().uuidString,
                    name: cleanName.isEmpty ? "表单 \(parsedLink.formID)" : cleanName,
                    accountName: cleanAccount.isEmpty ? "default" : cleanAccount,
                    formID: parsedLink.formID,
                    enabled: enabled,
                    clocks: parsedClocks.map(\.formatted),
                    weekdays: selectedWeekdays.sorted(),
                    usePOIPool: usePOIPool,
                    lat: latVal,
                    lng: lngVal,
                    addr: addr.trimmingCharacters(in: .whitespacesAndNewlines),
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                    wgs84: wgs84,
                    jitterMeters: jitterMeters,
                    lastTriggeredAt: existingPlan?.lastTriggeredAt,
                    lastRunStatus: existingPlan?.lastRunStatus ?? ""
                )
                onSave(plan)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
