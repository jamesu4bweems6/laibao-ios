import SwiftUI
import UIKit
import UserNotifications

/// Local scheduled check-in reminder plans + `UNUserNotificationCenter` calendar trigger sync
/// + one-tap immediate execution + sanitized run log history.
struct RemindersView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    @State private var authStatus: UNAuthorizationStatus = .notDetermined
    @State private var showSandboxDetail: Bool = false
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
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    Task {
                        await refreshNotificationStatus()
                    }
                }
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
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    StatusBadge(
                        title: notificationStatusTitle,
                        systemImage: notificationStatusIcon,
                        tint: notificationStatusTint
                    )
                    Spacer(minLength: 6)
                    if authStatus == .notDetermined {
                        Button("开启通知") {
                            requestNotificationPermission()
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    } else if authStatus == .denied {
                        Button("前往设置") {
                            if let settingsURL = URL(string: UIApplication.openSettingsURLString) {
                                openURL(settingsURL)
                            }
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                    } else {
                        Button("同步通知") {
                            syncAllNotifications()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }

                DisclosureGroup("iOS 提醒机制说明", isExpanded: $showSandboxDetail) {
                    Text("受 iOS 沙盒限制，定时计划通过系统本地日历通知（UNUserNotificationCenter）准点推送提醒，轻点通知可直达对应表单一键打卡；后台应用刷新（BGAppRefreshTask）由系统按电量与习惯动态调度，不保证准点静默提交。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
            .padding(.vertical, 2)
        } header: {
            Text("通知权限与同步")
        }
    }

    private var plansSection: some View {
        Section("打卡提醒计划（\(appState.reminders.count)）") {
            if appState.reminders.isEmpty {
                ContentUnavailableView {
                    Label("暂无提醒计划", systemImage: "bell.slash")
                } description: {
                    Text("创建多时间点、按星期循环的本地打卡提醒，到点一键直达填报。")
                } actions: {
                    Button {
                        isCreatingNew = true
                    } label: {
                        Label("新建提醒计划", systemImage: "plus")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(appState.reminders) { plan in
                    reminderRow(plan)
                }
            }
        }
    }

    private func reminderRow(_ plan: ReminderPlan) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(plan.clocks.joined(separator: " · "))
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .foregroundStyle(plan.enabled ? Color.primary : Color.secondary)
                        .lineLimit(2)

                    Text(plan.name.isEmpty ? "未命名提醒" : plan.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(plan.enabled ? Color.primary : Color.secondary)
                }
                Spacer(minLength: 8)
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

            FlowLayout(spacing: 6, lineSpacing: 6) {
                StatusBadge(
                    title: weekdaySummary(plan.weekdays),
                    systemImage: "calendar",
                    tint: plan.enabled ? Color.accentColor : Color.secondary
                )
                StatusBadge(
                    title: "表单 \(plan.formID)",
                    systemImage: "doc.text",
                    tint: Color.secondary,
                    monospaced: true
                )
                StatusBadge(
                    title: plan.accountName,
                    systemImage: "person.fill",
                    tint: Color.teal
                )
            }

            VStack(alignment: .leading, spacing: 3) {
                if plan.enabled,
                   let nextDate = try? ReminderScheduler.nextTriggerDate(clocks: plan.clocks, weekdays: plan.weekdays) {
                    Label(
                        "下次提醒：\(nextDate.formatted(date: .abbreviated, time: .shortened))",
                        systemImage: "bell.badge"
                    )
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                }

                Label(
                    plan.usePOIPool
                        ? "POI 点位池随机 · ±\(Int(plan.jitterMeters))m"
                        : "\(plan.title.isEmpty ? (plan.addr.isEmpty ? String(format: "%.6f,%.6f", plan.lat, plan.lng) : plan.addr) : plan.title) · ±\(Int(plan.jitterMeters))m",
                    systemImage: "mappin.and.ellipse"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

                if !plan.lastRunStatus.isEmpty {
                    let timeText = plan.lastTriggeredAt?.formatted(date: .omitted, time: .shortened) ?? ""
                    Text("最近执行\(timeText.isEmpty ? "" : "（\(timeText)）")：\(plan.lastRunStatus)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            HStack(spacing: 8) {
                Button {
                    runPlanNow(plan)
                } label: {
                    HStack(spacing: 5) {
                        if runningPlanID == plan.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "play.fill")
                        }
                        Text("立即执行")
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                    .font(.caption.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .disabled(runningPlanID != nil)

                Button {
                    appState.openFormInCheckin(formID: plan.formID)
                } label: {
                    Label("去填报", systemImage: "arrow.up.forward")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    editingPlan = plan
                } label: {
                    Label("编辑", systemImage: "pencil")
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
        }
        .padding(.vertical, 6)
        .opacity(plan.enabled ? 1.0 : 0.78)
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
                    HStack(alignment: .top, spacing: 10) {
                        IconBadge(
                            systemImage: log.success ? "checkmark" : "xmark",
                            tint: log.success ? Color.green : Color.red,
                            size: 26
                        )
                        .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                Text(log.formTitle.isEmpty ? log.formID : log.formTitle)
                                    .font(.subheadline.weight(.medium))
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                            }
                            Text(log.message)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if !log.fid.isEmpty || !log.accountName.isEmpty {
                                Text([
                                    log.accountName.isEmpty ? nil : "账号 \(log.accountName)",
                                    log.fid.isEmpty ? nil : "fid \(log.fid)"
                                ].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                    .contextMenu {
                        if !log.formID.isEmpty {
                            Button {
                                appState.openFormInCheckin(formID: log.formID)
                            } label: {
                                Label("在填报页打开此表单", systemImage: "arrow.up.forward.app")
                            }
                        }
                        Button {
                            UIPasteboard.general.string = log.message
                            appState.showToast("已复制日志详情")
                        } label: {
                            Label("复制日志内容", systemImage: "doc.on.doc")
                        }
                    }
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
        case .denied: return "通知已关闭"
        case .notDetermined: return "未开启通知权限"
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
        do {
            let updatedList = try appState.workspaceStore.upsertReminder(plan)
            appState.refreshWorkspace()
            Task {
                if plan.enabled && authStatus == .notDetermined {
                    _ = try? await ReminderScheduler.requestNotificationAuthorization()
                    await refreshNotificationStatus()
                }
                do {
                    try await ReminderScheduler.syncNotifications(for: updatedList)
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
        let plans = appState.reminders
        Task {
            do {
                try await ReminderScheduler.syncNotifications(for: plans)
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
        do {
            let remaining = try appState.workspaceStore.deleteReminder(id: plan.id)
            appState.refreshWorkspace()
            Task {
                try? await ReminderScheduler.syncNotifications(for: remaining)
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
        do {
            try appState.workspaceStore.clearRunLogs()
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
    @State private var clocks: [ReminderClock]
    @State private var pickerTime: Date
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

        let initialClocks: [ReminderClock] = {
            if let existing = existingPlan?.clocks,
               let parsed = try? ReminderScheduler.validateClocks(existing),
               !parsed.isEmpty {
                return parsed.sorted()
            }
            return [ReminderClock(hour: 8, minute: 45), ReminderClock(hour: 18, minute: 5)]
        }()
        _clocks = State(initialValue: initialClocks)

        var defaultPickerComps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        defaultPickerComps.hour = 9
        defaultPickerComps.minute = 0
        _pickerTime = State(initialValue: Calendar.current.date(from: defaultPickerComps) ?? Date())

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
                    HStack(spacing: 8) {
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
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("已选时间点（\(clocks.count)）")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                        }

                        if clocks.isEmpty {
                            Text("请通过下方时间选择器至少添加一个提醒时间")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        } else {
                            FlowLayout(spacing: 8, lineSpacing: 8) {
                                ForEach(clocks, id: \.self) { clock in
                                    HStack(spacing: 5) {
                                        Text(clock.formatted)
                                            .font(.subheadline.monospacedDigit().weight(.semibold))
                                        Button {
                                            withAnimation(.snappy(duration: 0.2)) {
                                                clocks.removeAll(where: { $0 == clock })
                                            }
                                        } label: {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel("删除时间 \(clock.formatted)")
                                    }
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.accentColor.opacity(0.14), in: Capsule())
                                    .foregroundStyle(Color.accentColor)
                                }
                            }
                        }

                        HStack(spacing: 10) {
                            DatePicker("添加时间", selection: $pickerTime, displayedComponents: .hourAndMinute)
                                .labelsHidden()
                                .datePickerStyle(.compact)

                            Button {
                                addClockFromPicker()
                            } label: {
                                Label("添加时间点", systemImage: "plus")
                                    .font(.caption.weight(.semibold))
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)

                            Spacer()
                        }
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text(selectedWeekdays.isEmpty ? "重复：每天" : "重复：已选 \(selectedWeekdays.count) 天")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Spacer()
                            HStack(spacing: 6) {
                                weekdayPresetButton("每天", days: [])
                                weekdayPresetButton("工作日", days: [1, 2, 3, 4, 5])
                                weekdayPresetButton("周末", days: [6, 7])
                            }
                        }

                        HStack(spacing: 6) {
                            ForEach(weekdayOptions) { option in
                                let active = selectedWeekdays.contains(option.id)
                                Button {
                                    withAnimation(.snappy(duration: 0.2)) {
                                        if active {
                                            selectedWeekdays.remove(option.id)
                                        } else {
                                            selectedWeekdays.insert(option.id)
                                        }
                                    }
                                } label: {
                                    Text(option.label)
                                        .font(.subheadline.weight(.semibold))
                                        .frame(maxWidth: .infinity)
                                        .frame(minHeight: 38)
                                        .background(
                                            active ? Color.accentColor : Color(.tertiarySystemFill),
                                            in: Capsule()
                                        )
                                        .foregroundStyle(active ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("周\(option.label)")
                                .accessibilityAddTraits(active ? .isSelected : [])
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .sensoryFeedback(.selection, trigger: selectedWeekdays)
                }

                Section("定位参数（用于「立即执行」）") {
                    Toggle("从 POI 点位池随机抽取", isOn: $usePOIPool)

                    if !usePOIPool {
                        Button {
                            showMapPicker = true
                        } label: {
                            Label("在地图上选取固定坐标", systemImage: "map.fill")
                        }
                        .buttonStyle(.glass)

                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("纬度 Lat")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("39.908823", text: $latText)
                                    .keyboardType(.decimalPad)
                                    .font(.subheadline.monospaced())
                                    .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text("经度 Lng")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                TextField("116.397470", text: $lngText)
                                    .keyboardType(.decimalPad)
                                    .font(.subheadline.monospaced())
                                    .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                            }
                        }
                        Toggle("输入坐标为 WGS-84", isOn: $wgs84)
                        TextField("地点名称（title）", text: $title)
                        TextField("详细地址（address）", text: $addr)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("随机抖动半径")
                            Spacer()
                            StatusBadge(
                                title: "±\(Int(jitterMeters)) m",
                                tint: jitterMeters > 0 ? Color.orange : Color.secondary,
                                monospaced: true
                            )
                        }
                        Slider(value: $jitterMeters, in: 0...200, step: 5)
                    }
                }

                if let errorMessage {
                    Section {
                        InlineFeedbackBanner(
                            message: errorMessage,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }
            .keyboardDoneToolbar()
            .navigationTitle(existingPlan == nil ? "新建提醒计划" : "编辑提醒计划")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("保存") { savePlan() }
                    }
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
                let lat = Double(latText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                let lng = Double(lngText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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

    private func weekdayPresetButton(_ label: String, days: Set<Int>) -> some View {
        let isMatch = selectedWeekdays == days
        return Button(label) {
            withAnimation(.snappy(duration: 0.2)) {
                selectedWeekdays = days
            }
        }
        .font(.caption2.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(isMatch ? Color.accentColor.opacity(0.18) : Color(.tertiarySystemFill), in: Capsule())
        .foregroundStyle(isMatch ? Color.accentColor : Color.secondary)
        .buttonStyle(.plain)
    }

    private func addClockFromPicker() {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: pickerTime)
        let newClock = ReminderClock(hour: comps.hour ?? 8, minute: comps.minute ?? 0)
        if !clocks.contains(newClock) {
            withAnimation(.snappy(duration: 0.2)) {
                clocks.append(newClock)
                clocks.sort()
            }
        }
    }

    private func savePlan() {
        dismissKeyboard()
        errorMessage = nil

        let validatedClocks: [ReminderClock]
        do {
            validatedClocks = try ReminderScheduler.validateClocks(clocks.map(\.formatted))
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let trimmedLat = latText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLng = lngText.trimmingCharacters(in: .whitespacesAndNewlines)
        var latVal: Double = 0
        var lngVal: Double = 0

        if !usePOIPool && (!trimmedLat.isEmpty || !trimmedLng.isEmpty) {
            guard let parsedLat = Double(trimmedLat), let parsedLng = Double(trimmedLng) else {
                errorMessage = "请输入有效的数字经纬度"
                return
            }
            do {
                try GeoMath.validateCoord(lat: parsedLat, lng: parsedLng)
            } catch {
                errorMessage = error.localizedDescription
                return
            }
            latVal = parsedLat
            lngVal = parsedLng
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
                    clocks: validatedClocks.map(\.formatted),
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
