import SwiftUI
import UIKit

/// Main dynamic check-in & form editing tab with smart link resolution,
/// 「我的接龙」 browser, 1-tap recent forms, dynamic native field controls,
/// MapKit geofence selection, patch (补卡) mode, edit mode (`fid`),
/// and a floating Liquid Glass Dry-Run / Submit dock.
struct CheckinView: View {
    @Environment(AppState.self) private var appState

    @State private var formInput: String = ""
    @State private var parsedLink: ParsedFormLink?
    @State private var parseError: String?
    @State private var isLoadingForm: Bool = false
    @State private var loadFormTask: Task<Void, Never>?
    @State private var loadedForm: ActInfo?

    @State private var fieldValues: [String: JSONValue] = [:]
    @State private var locationState = LocationFieldState()
    @State private var defaultText: String = ""

    // Edit Mode (`PUT /v2/{id}/form_data`)
    @State private var editFID: String = ""

    // Patch Mode (`POST /v1/{id}/form_data` only)
    @State private var patchEnabled: Bool = false
    @State private var patchDateSelection: Date = Date()
    @State private var patchDateText: String = ""
    @State private var patchSection: String = ""

    // Sheets & Submission State
    @State private var showMyFormsSheet = false
    @State private var mapPickerField: FormField?
    @State private var dryRunPreview: DryRunPreviewData?
    @State private var isSubmitting = false
    @State private var lastSubmitSummary: String?
    @State private var submitError: String?

    var body: some View {
        NavigationStack {
            Form {
                formSelectorSection

                if let form = loadedForm {
                    formOverviewSection(form)

                    if !editFID.isEmpty {
                        editModeBannerSection
                    }

                    dynamicFieldsSection(form)

                    if editFID.isEmpty {
                        patchSectionView
                    }
                } else {
                    emptyFormHelperSections
                }

                if let lastSubmitSummary {
                    Section("最近一次提交结果") {
                        InlineFeedbackBanner(
                            message: lastSubmitSummary,
                            systemImage: "checkmark.seal.fill",
                            tint: .green
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }

                if let submitError {
                    Section("提交错误") {
                        InlineFeedbackBanner(
                            message: submitError,
                            systemImage: "exclamationmark.triangle.fill",
                            tint: .red
                        )
                        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    }
                }
            }
            .keyboardDoneToolbar()
            .navigationTitle("动态填报")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMyFormsSheet = true
                    } label: {
                        Label("我的接龙", systemImage: "list.bullet.rectangle.portrait")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if loadedForm != nil {
                    GlassFloatingActionBar {
                        Button {
                            dismissKeyboard()
                            runDryRun()
                        } label: {
                            Label("预览", systemImage: "doc.text.magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .disabled(isSubmitting)
                        .accessibilityLabel("预览提交载荷 Dry-Run")

                        Button {
                            dismissKeyboard()
                            submitForm()
                        } label: {
                            HStack(spacing: 6) {
                                if isSubmitting {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: editFID.isEmpty ? "paperplane.fill" : "square.and.pencil")
                                }
                                Text(editFID.isEmpty ? "立即提交" : "保存修改")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.white)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(isSubmitting)
                    }
                }
            }
            .sheet(isPresented: $showMyFormsSheet) {
                MyFormsSheet { summary in
                    formInput = summary.formID
                    loadForm(from: summary.formID, editFID: nil, editCatalogs: nil)
                }
            }
            .sheet(item: $mapPickerField) { field in
                let spec = field.specifiedLocation
                MapPickerSheet(
                    initialPoint: locationState.gcj02PreviewPoint,
                    initialAddr: locationState.addr,
                    initialTitle: locationState.title,
                    anchors: spec?.anchors ?? [],
                    selectedAnchorIndex: locationState.anchorIndex,
                    jitterRadiusMeters: locationState.jitterMeters,
                    savedPOIs: appState.pois,
                    confirmButtonTitle: "确认使用该位置"
                ) { selection in
                    locationState.applyMapSelection(selection)
                    fieldValues.removeValue(forKey: field.cid)
                }
            }
            .sheet(item: $dryRunPreview) { preview in
                DryRunPreviewSheet(preview: preview)
            }
            .onAppear {
                if patchDateText.isEmpty {
                    patchDateText = UIFormatters.ymd.string(from: patchDateSelection)
                }
                consumeHandoffIfNeeded()
            }
            .onDisappear {
                loadFormTask?.cancel()
            }
            .onChange(of: appState.pendingCheckinRequestToken) { _, _ in
                consumeHandoffIfNeeded()
            }
        }
    }

    // MARK: - Sections

    private var formSelectorSection: some View {
        Section {
            HStack(spacing: 8) {
                TextField("粘贴分享链接、短链或表单 ID", text: $formInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .onSubmit {
                        loadForm(from: formInput, editFID: nil, editCatalogs: nil)
                    }

                if !formInput.isEmpty {
                    Button {
                        formInput = ""
                        parseError = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空输入")
                }

                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        formInput = pasted
                        loadForm(from: pasted, editFID: nil, editCatalogs: nil)
                    } else {
                        appState.showToast("剪贴板为空", isError: true)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("粘贴并解析")
            }

            Button {
                dismissKeyboard()
                loadForm(from: formInput, editFID: nil, editCatalogs: nil)
            } label: {
                HStack(spacing: 6) {
                    if isLoadingForm {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.down.doc.fill")
                    }
                    Text(isLoadingForm ? "正在解析加载..." : "解析并加载表单")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
            .disabled(isLoadingForm || formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if let parsed = parsedLink {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    StatusBadge(
                        title: "ID \(parsed.formID)",
                        systemImage: "checkmark.circle.fill",
                        tint: .green,
                        monospaced: true
                    )
                    StatusBadge(
                        title: sourceDisplayName(parsed.source),
                        tint: .blue
                    )
                }
            }

            if let parseError {
                InlineFeedbackBanner(
                    message: parseError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        } header: {
            Text("表单选择与链接解析")
        } footer: {
            Text("支持直接粘贴 s.qun100.com/link/* 短链、qun100.com/laibaoshu/*、launchApp 链接或原始表单 ID。")
        }
    }

    @ViewBuilder
    private var emptyFormHelperSections: some View {
        let recents = appState.recentForms
        if !recents.isEmpty {
            Section("最近填报（轻点快速加载）") {
                ForEach(recents) { item in
                    Button {
                        formInput = item.formID
                        loadForm(from: item.formID, editFID: nil, editCatalogs: nil)
                    } label: {
                        HStack(spacing: 10) {
                            IconBadge(
                                systemImage: item.lastSucceeded ? "checkmark.circle.fill" : "exclamationmark.circle.fill",
                                tint: item.lastSucceeded ? Color.green : Color.orange,
                                size: 32
                            )
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                HStack(spacing: 6) {
                                    Text("ID \(item.formID)")
                                        .font(.caption.monospaced())
                                    Text("·")
                                    Text(item.lastTime.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                }
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showMyFormsSheet = true
                } label: {
                    Label("浏览全部「我的接龙」", systemImage: "tray.full")
                        .font(.subheadline.weight(.medium))
                }
            }
        } else {
            Section {
                EmptyStateSectionView(
                    title: "选择要填报的接龙",
                    systemImage: "doc.text.magnifyingglass",
                    description: "粘贴分享链接，或从「我的接龙」列表中挑选参与的活动。",
                    actionTitle: "浏览我的接龙",
                    actionSystemImage: "tray.full"
                ) {
                    showMyFormsSheet = true
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
        }
    }

    private func formOverviewSection(_ form: ActInfo) -> some View {
        Section("表单概览") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    Text(form.displayTitle)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 6)
                    StatusBadge(
                        title: form.statusText,
                        tint: form.status == 2 ? Color.green : Color.orange
                    )
                }

                FlowLayout(spacing: 6, lineSpacing: 6) {
                    StatusBadge(
                        title: "ID \(form.formID)",
                        systemImage: "number",
                        tint: .secondary,
                        monospaced: true
                    )
                    StatusBadge(
                        title: "\(form.visibleFields.count) 项字段",
                        systemImage: "list.bullet",
                        tint: .blue
                    )
                    if let active = appState.activeAccount {
                        StatusBadge(
                            title: active.nickName.isEmpty ? active.name : "\(active.name)（\(active.nickName)）",
                            systemImage: "person.fill",
                            tint: .teal
                        )
                    }
                }

                if appState.activeAccount == nil {
                    InlineFeedbackBanner(
                        message: "尚未登录来宝账号，请先前往「账号」页添加令牌。",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            }
            .padding(.vertical, 2)

            if !form.accessConditions.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label("客户端访问条件静态提示", systemImage: "info.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.orange)
                    ForEach(form.accessConditions) { condition in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("• \(condition.label)")
                                .font(.caption.weight(.medium))
                            Text(condition.note)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var editModeBannerSection: some View {
        Section {
            HStack(spacing: 10) {
                IconBadge(systemImage: "pencil.line", tint: .orange, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑已有记录模式")
                        .font(.subheadline.weight(.semibold))
                    Text("PUT /v2 · fid \(editFID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 6)
                Button("退出编辑") {
                    editFID = ""
                    appState.showToast("已切回新建填报模式")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        }
    }

    private func dynamicFieldsSection(_ form: ActInfo) -> some View {
        Section("表单字段（\(form.visibleFields.count) 项）") {
            if form.visibleFields.isEmpty {
                Text("该表单未定义可见填报字段。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(form.visibleFields) { field in
                    DynamicFieldRow(
                        field: field,
                        fieldValues: $fieldValues,
                        locationState: $locationState,
                        savedPOIs: appState.pois,
                        onOpenMapPicker: { target in
                            mapPickerField = target
                        }
                    )
                }
            }
        }
    }

    private var patchSectionView: some View {
        Section("补卡选项（仅新建提交有效）") {
            Toggle("启用补卡提交（patch）", isOn: $patchEnabled)
            if patchEnabled {
                DatePicker(
                    "补卡日期",
                    selection: Binding(
                        get: { patchDateSelection },
                        set: { next in
                            patchDateSelection = next
                            patchDateText = UIFormatters.ymd.string(from: next)
                        }
                    ),
                    displayedComponents: [.date]
                )
                VStack(alignment: .leading, spacing: 4) {
                    Text("patchDate（YYYY-MM-DD）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("YYYY-MM-DD", text: $patchDateText)
                        .font(.subheadline.monospaced())
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .mobileInputField(verticalPadding: 8)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("补卡时段 patchTimeSection（可选）")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("留空按表单默认", text: $patchSection)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .mobileInputField(verticalPadding: 8)
                }
            }
        }
    }

    // MARK: - Actions

    private func consumeHandoffIfNeeded() {
        guard let handoff = appState.consumePendingCheckinHandoff() else { return }
        formInput = handoff.formID
        loadForm(
            from: handoff.formID,
            editFID: handoff.editFID,
            editCatalogs: handoff.editCatalogs
        )
    }

    private func loadForm(from rawInput: String, editFID incomingEditFID: String?, editCatalogs: [CatalogValue]?) {
        let trimmed = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            parseError = FormLinkParseError.empty.localizedDescription
            return
        }

        loadFormTask?.cancel()
        isLoadingForm = true
        parseError = nil
        submitError = nil
        lastSubmitSummary = nil

        let previousFormID = loadedForm?.formID

        loadFormTask = Task {
            defer { isLoadingForm = false }
            do {
                let parsed = try await FormLinkParser.resolveFormID(trimmed)
                guard !Task.isCancelled else { return }
                parsedLink = parsed
                let client = try appState.makeAPIClient()
                let detail = try await client.formDetail(formID: parsed.formID)
                guard !Task.isCancelled else { return }

                let isSwitchingForm = previousFormID != nil && previousFormID != detail.formID
                loadedForm = detail
                fieldValues = [:]
                editFID = incomingEditFID ?? ""
                patchEnabled = false

                if isSwitchingForm && (editCatalogs == nil || editCatalogs?.isEmpty == true) {
                    locationState.anchorIndex = nil
                }

                // Pre-populate default anchor when switching to a SPECIFIED_LOCATION form
                // whose geofence does not contain the existing coordinates, or when empty.
                if let locField = detail.visibleFields.first(where: { $0.normalizedType == "LOCATION" }),
                   let spec = locField.specifiedLocation,
                   spec.locationType == .specified,
                   let firstAnchor = spec.anchors.first {
                    let shouldPreFill: Bool = {
                        guard let currentPoint = locationState.gcj02PreviewPoint else {
                            return true
                        }
                        if isSwitchingForm {
                            let match = GeoMath.pickNearestAnchor(userPoint: currentPoint, anchors: spec.anchors)
                            return !(match?.isWithinScope ?? false)
                        }
                        return false
                    }()
                    if shouldPreFill {
                        locationState.wgs84 = false
                        locationState.applyAnchor(firstAnchor)
                    }
                }

                if let catalogs = editCatalogs, !catalogs.isEmpty {
                    applyEditCatalogs(catalogs, to: detail)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                parseError = error.localizedDescription
            }
        }
    }

    private func applyEditCatalogs(_ catalogs: [CatalogValue], to form: ActInfo) {
        let tempRecord = RecordItem(fid: editFID, catalogs: catalogs)
        var values = PayloadBuilder.draftFieldValues(from: tempRecord)
        let locationCIDs = Set(form.visibleFields.filter { $0.normalizedType == "LOCATION" }.map(\.cid))

        for item in catalogs where locationCIDs.contains(item.cid) {
            if let dict = item.value.objectValue {
                var lat = dict["latitude"]?.doubleValue ?? 0
                var lng = dict["longitude"]?.doubleValue ?? 0
                if (lat == 0 && lng == 0),
                   let coords = dict["location"]?["coordinates"]?.arrayValue,
                   coords.count >= 2 {
                    lng = coords[0].doubleValue ?? 0
                    lat = coords[1].doubleValue ?? 0
                }
                if (try? GeoMath.validateCoord(lat: lat, lng: lng)) != nil {
                    locationState.latText = String(format: "%.6f", lat)
                    locationState.lngText = String(format: "%.6f", lng)
                    locationState.wgs84 = false
                    locationState.usePOIPool = false
                    locationState.jitterMeters = 0
                }
                if let addr = dict["address"]?.stringValue {
                    locationState.addr = addr
                }
                if let title = dict["title"]?.stringValue {
                    locationState.title = title
                }
                values.removeValue(forKey: item.cid)
            }
        }
        fieldValues = values
    }

    private func buildCurrentDraft(dryRun: Bool) -> CheckinDraft {
        let formID = loadedForm?.formID ?? parsedLink?.formID ?? ""
        return CheckinDraft(
            formID: formID,
            lat: locationState.parsedLat,
            lng: locationState.parsedLng,
            addr: locationState.addr,
            title: locationState.title,
            wgs84: locationState.wgs84,
            jitterMeters: locationState.jitterMeters,
            usePOIPool: locationState.usePOIPool,
            pois: locationState.usePOIPool ? appState.pois : [],
            anchorIndex: locationState.anchorIndex,
            defaultText: defaultText,
            fieldValues: fieldValues,
            patch: editFID.isEmpty ? patchEnabled : false,
            patchDate: editFID.isEmpty ? patchDateText.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            patchSection: editFID.isEmpty ? patchSection.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            editFID: editFID,
            noAutoOption: false,
            dryRun: dryRun
        )
    }

    private func runDryRun() {
        guard let form = loadedForm else { return }
        submitError = nil
        do {
            let built = try PayloadBuilder.build(form: form, draft: buildCurrentDraft(dryRun: true))
            dryRunPreview = DryRunPreviewData(
                formID: form.formID,
                formTitle: form.displayTitle,
                isEdit: !editFID.isEmpty,
                prettyJSON: built.payload.prettyJSONString(),
                warnings: built.warnings,
                resolvedPoint: built.resolvedPoint
            )
        } catch {
            submitError = error.localizedDescription
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func submitForm() {
        guard let form = loadedForm else { return }
        submitError = nil
        lastSubmitSummary = nil

        let built: (payload: SubmitPayload, warnings: [String], resolvedPoint: GeoPoint?)
        do {
            built = try PayloadBuilder.build(form: form, draft: buildCurrentDraft(dryRun: false))
        } catch {
            submitError = error.localizedDescription
            appState.showToast(error.localizedDescription, isError: true)
            return
        }

        let isEdit = !editFID.isEmpty
        let activeAccountName = appState.activeAccount?.name ?? appState.settings.activeAccount
        isSubmitting = true

        Task {
            defer { isSubmitting = false }
            do {
                let client = try appState.makeAPIClient()
                let result: SubmitResult
                if isEdit {
                    result = try await client.update(formID: form.formID, payload: built.payload)
                } else {
                    result = try await client.submit(formID: form.formID, payload: built.payload)
                }

                let seqPart = result.sequence?.coercedStringValue.map { " · 序号 #\($0)" } ?? ""
                let fidPart = result.fid.isEmpty ? "" : " · fid: \(result.fid)"
                let summary = "\(isEdit ? "修改成功" : "提交成功")\(seqPart)\(fidPart)"
                lastSubmitSummary = summary

                let log = CheckinRunLog(
                    formID: form.formID,
                    formTitle: form.displayTitle,
                    accountName: activeAccountName,
                    dryRun: false,
                    success: true,
                    fid: result.fid,
                    message: built.warnings.isEmpty ? summary : "\(summary)（提示：\(built.warnings.joined(separator: "；"))）"
                )
                try? appState.workspaceStore.appendRunLog(log)
                appState.refreshWorkspace()
                appState.showToast(summary)
            } catch {
                submitError = error.localizedDescription
                let failLog = CheckinRunLog(
                    formID: form.formID,
                    formTitle: form.displayTitle,
                    accountName: activeAccountName,
                    dryRun: false,
                    success: false,
                    fid: editFID,
                    message: error.localizedDescription
                )
                try? appState.workspaceStore.appendRunLog(failLog)
                appState.refreshWorkspace()
                appState.showToast(error.localizedDescription, isError: true)
            }
        }
    }

    private func sourceDisplayName(_ source: String) -> String {
        switch source {
        case "raw": return "原始 ID"
        case "url_path": return "活动链接"
        case "url_query": return "URL 参数"
        case "url_q": return "二维码参数"
        case "url_scene": return "Scene 参数"
        case "url_address": return "launchApp 链接"
        case "short_link": return "短链重定向"
        default: return source
        }
    }
}

// MARK: - Dry-Run Preview Sheet

private struct DryRunPreviewData: Identifiable {
    let id = UUID()
    let formID: String
    let formTitle: String
    let isEdit: Bool
    let prettyJSON: String
    let warnings: [String]
    let resolvedPoint: GeoPoint?
}

private struct DryRunPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState

    let preview: DryRunPreviewData

    var body: some View {
        NavigationStack {
            List {
                Section("目标接口与坐标") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(preview.formTitle)
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 8) {
                            StatusBadge(
                                title: preview.isEdit ? "PUT" : "POST",
                                tint: preview.isEdit ? Color.orange : Color.blue,
                                monospaced: true
                            )
                            Text(preview.isEdit
                                 ? "/v2/\(preview.formID)/form_data"
                                 : "/v1/\(preview.formID)/form_data")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        if let pt = preview.resolvedPoint {
                            LabeledContent("最终 GCJ-02") {
                                Text(pt.formatted)
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 2)
                }

                if !preview.warnings.isEmpty {
                    Section("构建提示（\(preview.warnings.count)）") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            InlineFeedbackBanner(
                                message: warning,
                                systemImage: "exclamationmark.triangle.fill",
                                tint: .orange
                            )
                            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                        }
                    }
                }

                Section("JSON 载荷预览") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(preview.prettyJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 6)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("载荷预览（Dry-Run）")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        UIPasteboard.general.string = preview.prettyJSON
                        appState.showToast("已复制预览 JSON")
                    } label: {
                        Label("复制", systemImage: "doc.on.doc")
                    }
                }
            }
        }
    }
}
