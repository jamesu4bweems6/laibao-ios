import SwiftUI

/// Modal browser for 「我的接龙」 across all 3 scopes:
/// `我参与的` (`/v1/participation_forms`), `我创建的` (`/v2/creation_forms`), `我管理的` (`/v3/manager_forms`).
struct MyFormsSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onSelect: (FormSummary) -> Void

    @State private var scope: FormListScope = .participation
    @State private var keyword: String = ""
    @State private var pageNo: Int = 1
    @State private var hasMore: Bool = false
    @State private var items: [FormSummary] = []
    @State private var isLoading: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    GlassSegmentedControl(
                        items: FormListScope.allCases,
                        selection: $scope,
                        title: \.displayName,
                        tint: .accentColor
                    )
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                    .listRowBackground(Color.clear)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    if isLoading && items.isEmpty {
                        HStack {
                            Spacer()
                            ProgressView("正在加载接龙列表...")
                                .padding(.vertical, 24)
                            Spacer()
                        }
                    } else if items.isEmpty {
                        ContentUnavailableView(
                            "暂无「\(scope.displayName)」表单",
                            systemImage: "tray",
                            description: Text(keyword.isEmpty ? "请确认当前账号已登录，或切换上方分组。" : "没有匹配「\(keyword)」的活动。")
                        )
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(items) { summary in
                            Button {
                                onSelect(summary)
                                dismiss()
                            } label: {
                                formSummaryRow(summary)
                            }
                            .buttonStyle(.plain)
                        }

                        if hasMore {
                            Button {
                                loadPage(page: pageNo + 1, append: true)
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoading {
                                        ProgressView()
                                            .controlSize(.small)
                                    } else {
                                        Text("加载更多（第 \(pageNo + 1) 页）")
                                            .font(.subheadline.weight(.medium))
                                    }
                                    Spacer()
                                }
                            }
                            .disabled(isLoading)
                        }
                    }
                } header: {
                    Text("\(scope.displayName)（已加载 \(items.count) 条）")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("我的接龙")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $keyword, prompt: "搜索标题或表单 ID")
            .onSubmit(of: .search) {
                loadPage(page: 1, append: false)
            }
            .refreshable {
                await loadPageAsync(page: 1, append: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        loadPage(page: 1, append: false)
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                }
            }
            .onAppear {
                if items.isEmpty {
                    loadPage(page: 1, append: false)
                }
            }
            .onChange(of: scope) { _, _ in
                loadPage(page: 1, append: false)
            }
            .onChange(of: keyword) { _, newValue in
                if newValue.isEmpty {
                    loadPage(page: 1, append: false)
                }
            }
        }
    }

    private func formSummaryRow(_ summary: FormSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Text(summary.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                GlassStatusPill(
                    title: summary.statusText,
                    tint: summary.status == 2 ? .green : .gray
                )
            }

            HStack(spacing: 10) {
                Text("ID: \(summary.formID)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if !summary.actType.isEmpty {
                    Text(summary.actType)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.tertiarySystemFill), in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if summary.participantCount > 0 {
                    Label("\(summary.participantCount)", systemImage: "person.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !summary.creatorName.isEmpty || !summary.updatedAt.isEmpty || !summary.createTime.isEmpty {
                HStack(spacing: 8) {
                    if !summary.creatorName.isEmpty {
                        Text("创建者：\(summary.creatorName)")
                    }
                    Spacer()
                    let timeText = summary.updatedAt.isEmpty ? summary.createTime : summary.updatedAt
                    if !timeText.isEmpty {
                        Text(timeText)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func loadPage(page: Int, append: Bool) {
        Task {
            await loadPageAsync(page: page, append: append)
        }
    }

    private func loadPageAsync(page: Int, append: Bool) async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let client = try appState.makeAPIClient()
            let res = try await client.listForms(
                scope: scope,
                pageNo: page,
                pageSize: 20,
                keyword: keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            pageNo = res.pageNo
            hasMore = res.hasMore
            if append {
                let existingIDs = Set(items.map(\.formID))
                let fresh = res.items.filter { !existingIDs.contains($0.formID) }
                items.append(contentsOf: fresh)
            } else {
                items = res.items
            }
        } catch {
            errorMessage = error.localizedDescription
            if !append {
                items = []
                hasMore = false
            }
        }
    }
}
