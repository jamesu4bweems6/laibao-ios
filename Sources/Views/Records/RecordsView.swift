import SwiftUI
import UIKit

/// Submission records query & inspection tab supporting:
/// - `我的记录` (`myRecords`), `最近一条` (`lastRecord`), `全员列表` (`allRecords`)
/// - Smart Form ID / Link resolution & 「我的接龙」 picker
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

    private let pageSize: Int = 10

    var body: some View {
        NavigationStack {
            List {
                queryHeaderSection
                resultsSection
            }
            .listStyle(.insetGrouped)
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
        }
    }

    // MARK: - Sections

    private var queryHeaderSection: some View {
        Section("查询条件") {
            HStack(spacing: 8) {
                TextField("粘贴表单 ID 或分享链接", text: $formInput)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        fetchRecords(page: 1)
                    }

                Button {
                    if let pasted = UIPasteboard.general.string {
                        formInput = pasted
                        fetchRecords(page: 1)
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("粘贴并查询")
            }

            GlassSegmentedControl(
                items: RecordQueryMode.allCases,
                selection: $mode,
                title: \.title,
                tint: .accentColor
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            HStack(spacing: 10) {
                Button {
                    fetchRecords(page: 1)
                } label: {
                    HStack(spacing: 6) {
                        if isLoading {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "magnifyingglass")
                        }
                        Text("查询记录")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .disabled(isLoading || formInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button {
                    showMyFormsSheet = true
                } label: {
                    Label("我的接龙", systemImage: "tray.full")
                }
                .buttonStyle(.glass)
            }

            if !resolvedFormID.isEmpty {
                HStack(spacing: 8) {
                    GlassStatusPill(title: "表单 ID: \(resolvedFormID)", systemImage: "doc.text", tint: .blue)
                    if totalCount > 0 {
                        GlassStatusPill(title: "共 \(totalCount) 条", tint: .green)
                    }
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
        }
    }

    private var resultsSection: some View {
        Section {
            if isLoading && records.isEmpty {
                HStack {
                    Spacer()
                    ProgressView("正在拉取提交记录...")
                        .padding(.vertical, 24)
                    Spacer()
                }
            } else if records.isEmpty {
                ContentUnavailableView(
                    resolvedFormID.isEmpty ? "请输入表单 ID 查询" : "暂无提交记录",
                    systemImage: "list.bullet.clipboard",
                    description: Text(resolvedFormID.isEmpty
                                      ? "可粘贴活动链接、短链或从「我的接龙」选择表单。"
                                      : "当前查询模式（\(mode.title)）未返回任何记录。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(records) { record in
                    recordCard(record)
                }

                if mode != .last {
                    HStack {
                        Button("上一页") {
                            fetchRecords(page: max(1, pageNo - 1))
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isLoading || pageNo <= 1)

                        Spacer()
                        Text("第 \(pageNo) 页")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()

                        Button("下一页") {
                            fetchRecords(page: pageNo + 1)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .disabled(isLoading || records.count < pageSize)
                    }
                }
            }
        } header: {
            Text("\(mode.title)（当前展示 \(records.count) 条）")
        }
    }

    private func recordCard(_ record: RecordItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if !record.sequenceText.isEmpty {
                    GlassStatusPill(title: "序号 #\(record.sequenceText)", tint: .accentColor)
                }
                if !record.submitter.isEmpty {
                    Text(record.submitter)
                        .font(.subheadline.weight(.semibold))
                }
                Spacer()
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

            if !record.fid.isEmpty {
                Text("fid: \(record.fid)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: 2) {
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
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(labelStrings, id: \.self) { label in
                            Text(label)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.14), in: Capsule())
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }

            if !record.catalogs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(record.catalogs) { cat in
                        HStack(alignment: .top, spacing: 6) {
                            Text(cat.type.isEmpty ? cat.cid : "\(cat.type)#\(cat.cid)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 70, alignment: .leading)
                            Text(formatCatalogValue(cat))
                                .font(.caption)
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions & Formatting

    private func fetchRecords(page: Int) {
        Task {
            await fetchRecordsAsync(page: page)
        }
    }

    private func fetchRecordsAsync(page: Int) async {
        let trimmed = formInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = FormLinkParseError.empty.localizedDescription
            return
        }

        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let parsed = try await FormLinkParser.resolveFormID(trimmed)
            resolvedFormID = parsed.formID
            let client = try appState.makeAPIClient()

            switch mode {
            case .mine:
                let list = try await client.myRecords(formID: parsed.formID, pageNo: page, pageSize: pageSize)
                records = list.list
                totalCount = list.total
                pageNo = page
            case .last:
                if let latest = try await client.lastRecord(formID: parsed.formID) {
                    records = [latest]
                    totalCount = 1
                } else {
                    records = []
                    totalCount = 0
                }
                pageNo = 1
            case .all:
                let list = try await client.allRecords(formID: parsed.formID, pageNo: page, pageSize: pageSize)
                records = list.list
                totalCount = list.total
                pageNo = page
            }
        } catch {
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
