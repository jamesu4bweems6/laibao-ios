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
    @State private var isLoadingMore: Bool = false
    @State private var errorMessage: String?
    @State private var loadTask: Task<Void, Never>?

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
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
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

                Section {
                    if isLoading && items.isEmpty {
                        HStack {
                            Spacer()
                            VStack(spacing: 10) {
                                ProgressView()
                                Text("正在加载接龙列表...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 28)
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
                                loadNextPage()
                            } label: {
                                HStack(spacing: 8) {
                                    Spacer()
                                    if isLoadingMore {
                                        ProgressView()
                                            .controlSize(.small)
                                        Text("加载中...")
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("加载更多（第 \(pageNo + 1) 页）")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Color.accentColor)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 4)
                            }
                            .disabled(isLoadingMore || isLoading)
                        }
                    }
                } header: {
                    HStack {
                        Text("\(scope.displayName)（已加载 \(items.count) 条）")
                        Spacer()
                        if isLoading && !items.isEmpty {
                            ProgressView()
                                .controlSize(.mini)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("我的接龙")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .searchable(text: $keyword, prompt: "搜索标题或表单 ID")
            .onSubmit(of: .search) {
                reloadFirstPage()
            }
            .refreshable {
                await performLoad(page: 1, append: false)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        reloadFirstPage()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isLoading)
                    .accessibilityLabel("刷新接龙列表")
                }
            }
            .onAppear {
                if items.isEmpty {
                    reloadFirstPage()
                }
            }
            .onDisappear {
                loadTask?.cancel()
            }
            .onChange(of: scope) { _, _ in
                reloadFirstPage()
            }
            .onChange(of: keyword) { _, newValue in
                if newValue.isEmpty {
                    reloadFirstPage()
                }
            }
        }
    }

    private func formSummaryRow(_ summary: FormSummary) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 8) {
                    Text(summary.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    StatusBadge(
                        title: summary.statusText,
                        tint: summary.status == 2 ? Color.green : Color.secondary
                    )
                }

                FlowLayout(spacing: 6, lineSpacing: 4) {
                    Text("ID \(summary.formID)")
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
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        let timeText = summary.updatedAt.isEmpty ? summary.createTime : summary.updatedAt
                        if !timeText.isEmpty {
                            Text(timeText)
                                .monospacedDigit()
                                .lineLimit(1)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func reloadFirstPage() {
        loadTask?.cancel()
        loadTask = Task {
            await performLoad(page: 1, append: false)
        }
    }

    private func loadNextPage() {
        guard !isLoading, !isLoadingMore, hasMore else { return }
        let nextPage = pageNo + 1
        loadTask = Task {
            await performLoad(page: nextPage, append: true)
        }
    }

    private func performLoad(page: Int, append: Bool) async {
        let requestedScope = scope
        let requestedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)

        if append {
            isLoadingMore = true
        } else {
            isLoading = true
        }
        errorMessage = nil
        defer {
            if append {
                isLoadingMore = false
            } else {
                isLoading = false
            }
        }

        do {
            let client = try appState.makeAPIClient()
            let res = try await client.listForms(
                scope: requestedScope,
                pageNo: page,
                pageSize: 20,
                keyword: requestedKeyword
            )
            guard !Task.isCancelled, requestedScope == scope else { return }
            pageNo = res.pageNo
            hasMore = res.hasMore
            if append {
                let existingIDs = Set(items.map(\.formID))
                let fresh = res.items.filter { !existingIDs.contains($0.formID) }
                items.append(contentsOf: fresh)
            } else {
                items = res.items
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            if !append {
                items = []
                hasMore = false
            }
        }
    }
}
