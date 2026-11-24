import SwiftUI
import UIKit

/// Main dynamic check-in & form editing tab with smart link resolution,
/// 「我的接龙」 browser, dynamic native field controls, MapKit geofence selection,
/// patch (补卡) mode, edit mode (`fid`), and floating Liquid Glass Dry-Run / Submit dock.
struct CheckinView: View {
    @Environment(AppState.self) private var appState

    @State private var formInput: String = ""
    @State private var parsedLink: ParsedFormLink?
    @State private var parseError: String?
    @State private var isLoadingForm: Bool = false
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
                }

                if let lastSubmitSummary {
                    Section("最近一次提交结果") {
                        Label(lastSubmitSummary, systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                    }
                }

                if let submitError {
                    Section("提交错误") {
                        Label(submitError, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
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
                            runDryRun()
                        } label: {
                            Label("预览载荷 (Dry-Run)", systemImage: "doc.text.magnifyingglass")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.glass)
                        .disabled(isSubmitting)

                        Button {
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
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
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
                    patchDateText = Self.formatYMD(patchDateSelection)
                }
                consumeHandoffIfNeeded()
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

                Button {
                    if let pasted = UIPasteboard.general.string {
                        formInput = pasted
                        loadForm(from: pasted, editFID: nil, editCatalogs: nil)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("粘贴并解析")
            }

            HStack(spacing: 10) {
                Button {
                    loadForm(from: formInput, editFID: nil, editCatalogs: nil)
                } label: {
                    HStack(spacing: 6) {
                        if isLoadingForm {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "arrow.down.doc.fill")
                        }
                        Text("解析并加载表单")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isLoadingForm || formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showMyFormsSheet = true
                } label: {
                    Label("我的接龙", systemImage: "tray.full")
                }
                .buttonStyle(.glass)
            }

            if let parsed = parsedLink {
                HStack(spacing: 8) {
                    GlassStatusPill(
                        title: "ID: \(parsed.formID)",
                        systemImage: "checkmark.circle.fill",
                        tint: .green
                    )
                    GlassStatusPill(
                        title: sourceDisplayName(parsed.source),
                        tint: .blue
                    )
                }
            }

            if let parseError {
                Label(parseError, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        } header: {
            Text("表单选择与链接解析")
        } footer: {
            Text("支持直接粘贴 s.qun100.com/link/* 短链、qun100.com/laibaoshu/*、launchApp 链接或原始表单 ID。")
        }
    }

    private func formOverviewSection(_ form: ActInfo) -> some View {
        Section("表单概览") {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Text(form.displayTitle)
                        .font(.headline)
                    Spacer()
                    GlassStatusPill(
                        title: form.statusText,
                        tint: form.status == 2 ? .green : .orange
                    )
                }

                HStack(spacing: 12) {
                    Text("表单 ID：\(form.formID)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                    Text("可见字段：\(form.visibleFields.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let active = appState.activeAccount {
                    Text("当前提交账号：\(active.name)\(active.nickName.isEmpty ? "" : "（\(active.nickName)）")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Label("尚未登录来宝账号，请先前往「账号」页添加令牌", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

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
                Image(systemName: "pencil.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("编辑已有记录模式（PUT /v2/form_data）")
                        .font(.subheadline.weight(.semibold))
                    Text("记录 fid：\(editFID)（自动移除补卡 patch 字段）")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出编辑") {
                    editFID = ""
                    appState.showToast("已切回新建填报模式")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
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
                            patchDateText = Self.formatYMD(next)
                        }
                    ),
                    displayedComponents: [.date]
                )
                TextField("patchDate（YYYY-MM-DD）", text: $patchDateText)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("补卡时段 patchTimeSection（可选）", text: $patchSection)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
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

        isLoadingForm = true
        parseError = nil
        submitError = nil
        lastSubmitSummary = nil

        Task {
            defer { isLoadingForm = false }
            do {
                let parsed = try await FormLinkParser.resolveFormID(trimmed)
                parsedLink = parsed
                let client = try appState.makeAPIClient()
                let detail = try await client.formDetail(formID: parsed.formID)
                loadedForm = detail
                fieldValues = [:]
                editFID = incomingEditFID ?? ""
                patchEnabled = false

                // Pre-populate default location anchor when a SPECIFIED_LOCATION field exists and user has no coords yet.
                if let locField = detail.visibleFields.first(where: { $0.normalizedType == "LOCATION" }),
                   let spec = locField.specifiedLocation,
                   spec.locationType == .specified,
                   let firstAnchor = spec.anchors.first,
                   locationState.gcj02PreviewPoint == nil {
                    locationState.latText = String(format: "%.6f", firstAnchor.latitude)
                    locationState.lngText = String(format: "%.6f", firstAnchor.longitude)
                    locationState.addr = firstAnchor.address.isEmpty ? firstAnchor.specifiedAddress : firstAnchor.address
                    locationState.title = firstAnchor.specifiedAddress
                    locationState.wgs84 = false
                }

                if let catalogs = editCatalogs, !catalogs.isEmpty {
                    applyEditCatalogs(catalogs, to: detail)
                }
            } catch {
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
                // Remove raw override so live MapPicker / locationState edits take effect cleanly.
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
        guard let form = loadedForm, let user = appState.currentUser else { return }
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
                try? appState.workspaceStore.appendRunLog(log, for: user.id)
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
                try? appState.workspaceStore.appendRunLog(failLog, for: user.id)
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

    private static func formatYMD(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
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
                Section("目标接口") {
                    Text(preview.isEdit
                         ? "PUT /v2/\(preview.formID)/form_data（编辑记录）"
                         : "POST /v1/\(preview.formID)/form_data（新建提交）")
                        .font(.caption.monospaced())
                    if let pt = preview.resolvedPoint {
                        Text("最终提交 GCJ-02 坐标：\(pt.formatted)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }

                if !preview.warnings.isEmpty {
                    Section("构建提示（\(preview.warnings.count)）") {
                        ForEach(preview.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                }

                Section("JSON 载荷预览") {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(preview.prettyJSON)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .padding(.vertical, 4)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("载荷预览（Dry-Run）")
            .navigationBarTitleDisplayMode(.inline)
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
