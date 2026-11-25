import SwiftUI
import UIKit

/// Submission records query & inspection tab supporting:
/// - `我的记录` (`myRecords`), `最近一条` (`lastRecord`), `全员列表` (`allRecords`)
/// - Smart Form ID / Link resolution, 1-tap recent forms, & 「我的接龙」 picker
/// - One-tap 「带入编辑」 jumping directly into `CheckinView` in edit mode (`fid` + pre-filled catalogs)
struct RecordsView: View {
    private enum RecordQueryMode: String, CaseIterable, Hashable, Sendable {
        case mine
        case last
        case all

        var title: String {
            switch self {
            case .mine: return "我的记录"
            case .last: return "最近一条"
            case .all: return "全员列表"
            }
        }
    }

    @Environment(AppState.self) private var appState

    @State private var formInput: String = ""
    @State private var resolvedFormID: String = ""
    @State private var mode: RecordQueryMode = .mine
    @State private var pageNo: Int = 1
    @State private var totalCount: Int = 0
    @State private var records: [RecordItem] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?
    @State private var showMyFormsSheet: Bool = false
    @State private var fetchTask: Task<Void, Never>?

    private let pageSize: Int = 10

    private var totalPages: Int {
        guard totalCount > 0 else { return max(1, pageNo) }
        return max(1, Int(ceil(Double(totalCount) / Double(pageSize))))
    }

    private var hasNextPage: Bool {
        if totalCount > 0 {
            return pageNo * pageSize < totalCount
        }
        return records.count >= pageSize
    }

    var body: some View {
        NavigationStack {
            List {
                modePickerSection
                queryHeaderSection
                if resolvedFormID.isEmpty && records.isEmpty && !appState.recentForms.isEmpty {
                    recentFormsSection
                }
                resultsSection
            }
            .listStyle(.insetGrouped)
            .keyboardDoneToolbar()
            .navigationTitle("提交记录")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMyFormsSheet = true
                    } label: {
                        Label("我的接龙", systemImage: "list.bullet.rectangle.portrait")
                    }
                }
            }
            .refreshable {
                if !formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    await fetchRecordsAsync(page: pageNo)
                }
            }
            .sheet(isPresented: $showMyFormsSheet) {
                MyFormsSheet { summary in
                    formInput = summary.formID
                    fetchRecords(page: 1)
                }
            }
            .onChange(of: mode) { _, _ in
                if !formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    fetchRecords(page: 1)
                }
            }
            .onDisappear {
                fetchTask?.cancel()
            }
        }
    }

    // MARK: - Sections

    private var modePickerSection: some View {
        Section {
            GlassSegmentedControl(
                items: RecordQueryMode.allCases,
                selection: $mode,
                title: \.title,
                tint: .accentColor
            )
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowBackground(Color.clear)
        }
    }

    private var queryHeaderSection: some View {
        Section("表单与查询") {
            HStack(spacing: 8) {
                TextField("粘贴表单 ID 或分享链接", text: $formInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        fetchRecords(page: 1)
                    }

                if !formInput.isEmpty {
                    Button {
                        formInput = ""
                        errorMessage = nil
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
                        fetchRecords(page: 1)
                    } else {
                        appState.showToast("剪贴板为空", isError: true)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("粘贴并查询")
            }

            Button {
                dismissKeyboard()
                fetchRecords(page: 1)
            } label: {
                HStack(spacing: 6) {
                    if isLoading {
                        ProgressView()
                            .tint(.white)
                            .controlSize(.small)
                    } else {
                        Image(systemName: "magnifyingglass")
                    }
                    Text(isLoading ? "正在查询..." : "查询记录")
                }
            }
            .buttonStyle(PrimaryActionButtonStyle(fullWidth: true))
            .disabled(isLoading || formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !resolvedFormID.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    StatusBadge(
                        title: "表单 ID \(resolvedFormID)",
                        systemImage: "doc.text",
                        tint: .blue,
                        monospaced: true
                    )
                    if totalCount > 0 {
                        StatusBadge(
                            title: "共 \(totalCount) 条",
                            systemImage: "number",
                            tint: .green,
                            monospaced: true
                        )
                    }
                }
            }

            if let errorMessage {
                InlineFeedbackBanner(
                    message: errorMessage,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
    }

    private var recentFormsSection: some View {
        Section("最近使用的表单") {
            ForEach(appState.recentForms) { item in
                Button {
                    formInput = item.formID
                    fetchRecords(page: 1)
                } label: {
                    HStack(spacing: 10) {
                        IconBadge(systemImage: "clock.arrow.circlepath", tint: .accentColor, size: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            Text("ID \(item.formID)")
                                .font(.caption.monospaced())
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
        }
    }

    private var resultsSection: some View {
        Section {
            if isLoading && records.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 10) {
                        ProgressView()
                        Text("正在拉取提交记录...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 26)
                    Spacer()
                }
            } else if records.isEmpty {
                EmptyStateSectionView(
                    title: resolvedFormID.isEmpty ? "输入表单 ID 开始查询" : "暂无提交记录",
                    systemImage: "list.bullet.clipboard",
                    description: resolvedFormID.isEmpty
                        ? "可粘贴分享链接、短链，或从「我的接龙」选择要查看的活动。"
                        : "当前模式（\(mode.title)）未返回任何记录。",
                    actionTitle: resolvedFormID.isEmpty ? "浏览我的接龙" : nil,
                    actionSystemImage: resolvedFormID.isEmpty ? "tray.full" : nil,
                    action: resolvedFormID.isEmpty ? { showMyFormsSheet = true } : nil
                )
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            } else {
                ForEach(records) { record in
                    recordCard(record)
                }

                if mode != .last {
                    HStack {
                        Button {
                            fetchRecords(page: max(1, pageNo - 1))
                        } label: {
                            Label("上一页", systemImage: "chevron.left")
                                .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isLoading || pageNo <= 1)

                        Spacer()
                        Text(totalCount > 0 ? "第 \(pageNo) / \(totalPages) 页" : "第 \(pageNo) 页")
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button {
                            fetchRecords(page: pageNo + 1)
                        } label: {
                            HStack(spacing: 4) {
                                Text("下一页")
                                Image(systemName: "chevron.right")
                            }
                            .font(.subheadline.weight(.medium))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isLoading || !hasNextPage)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("\(mode.title)（当前展示 \(records.count) 条）")
        }
    }

    private func recordCard(_ record: RecordItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 8) {
                if !record.sequenceText.isEmpty {
                    StatusBadge(
                        title: "#\(record.sequenceText)",
                        tint: .accentColor,
                        monospaced: true
                    )
                }
                if !record.submitter.isEmpty {
                    Text(record.submitter)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .layoutPriority(1)
                }
                Spacer(minLength: 6)
                if !record.fid.isEmpty && !resolvedFormID.isEmpty {
                    Button {
                        appState.openFormInCheckin(
                            formID: resolvedFormID,
                            editFID: record.fid,
                            editCatalogs: record.catalogs
                        )
                        appState.showToast("已带入记录 fid: \(record.fid) 进行编辑")
                    } label: {
                        Label("带入编辑", systemImage: "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                if !record.fid.isEmpty {
                    Text("fid: \(record.fid)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !record.createTimeText.isEmpty {
                    Text("提交时间：\(record.createTimeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !record.updateTimeText.isEmpty && record.updateTimeText != record.createTimeText {
                    Text("更新时间：\(record.updateTimeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let labelStrings = record.labels?.displayStrings, !labelStrings.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(labelStrings, id: \.self) { label in
                        StatusBadge(title: label, tint: .accentColor)
                    }
                }
            }

            if !record.catalogs.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(record.catalogs) { cat in
                        let presentation = FieldTypePresentation.forType(cat.type)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: presentation.systemImage)
                                    .font(.caption2)
                                    .foregroundStyle(presentation.tint)
                                Text(cat.type.isEmpty ? "字段 #\(cat.cid)" : "\(presentation.label) · \(cat.cid)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Text(formatCatalogValue(cat))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    Color(.tertiarySystemFill).opacity(0.5),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions & Formatting

    private func fetchRecords(page: Int) {
        fetchTask?.cancel()
        fetchTask = Task {
            await fetchRecordsAsync(page: page)
        }
    }

    private func fetchRecordsAsync(page: Int) async {
        let trimmed = formInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = FormLinkParseError.empty.localizedDescription
            return
        }

        let requestedMode = mode
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let parsed = try await FormLinkParser.resolveFormID(trimmed)
            guard !Task.isCancelled else { return }
            resolvedFormID = parsed.formID
            let client = try appState.makeAPIClient()

            switch requestedMode {
            case .mine:
                let list = try await client.myRecords(formID: parsed.formID, pageNo: page, pageSize: pageSize)
                guard !Task.isCancelled, requestedMode == mode else { return }
                records = list.list
                totalCount = list.total
                pageNo = page
            case .last:
                let latest = try await client.lastRecord(formID: parsed.formID)
                guard !Task.isCancelled, requestedMode == mode else { return }
                if let latest {
                    records = [latest]
                    totalCount = 1
                } else {
                    records = []
                    totalCount = 0
                }
                pageNo = 1
            case .all:
                let list = try await client.allRecords(formID: parsed.formID, pageNo: page, pageSize: pageSize)
                guard !Task.isCancelled, requestedMode == mode else { return }
                records = list.list
                totalCount = list.total
                pageNo = page
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            records = []
            totalCount = 0
        }
    }

    private func formatCatalogValue(_ catalog: CatalogValue) -> String {
        let val = catalog.value
        if let s = val.stringValue {
            return s
        }
        if let dict = val.objectValue {
            if let title = dict["title"]?.stringValue, let addr = dict["address"]?.stringValue {
                return title == addr ? addr : "\(title)（\(addr)）"
            }
            if let prov = dict["province"]?.stringValue {
                let parts = [
                    prov,
                    dict["city"]?.stringValue ?? "",
                    dict["district"]?.stringValue ?? "",
                    dict["address"]?.stringValue ?? ""
                ].filter { !$0.isEmpty }
                if !parts.isEmpty { return parts.joined(separator: " ") }
            }
            if let cid = dict["cid"]?.coercedStringValue {
                let custom = dict["customValue"]?.stringValue ?? ""
                return custom.isEmpty ? "选项 \(cid)" : "选项 \(cid)（\(custom)）"
            }
            if let pathCids = dict["pathCids"]?.arrayValue {
                return pathCids.compactMap(\.coercedStringValue).joined(separator: " / ")
            }
            return val.compactJSONString()
        }
        if let arr = val.arrayValue {
            let pieces: [String] = arr.map { elem in
                if let s = elem.stringValue { return s }
                if let cid = elem["cid"]?.coercedStringValue { return "选项 \(cid)" }
                return elem.compactJSONString()
            }
            return pieces.joined(separator: "，")
        }
        return val.coercedStringValue ?? val.compactJSONString()
    }
}
