import SwiftUI
import UIKit

/// LaiBao account management & diagnostics tab:
/// - Active account hero summary & multi-account switcher (Keychain-backed)
/// - 3 LaiBao login flows (Official Account QR auto-poll, manual Keychain token, WeChat code)
/// - Live Whoami & Server Time (`epochMillis`) diagnostics
/// - Workspace protocol settings (`ver`, `mpAppID`)
struct AccountsView: View {
    private struct ServerTimeDiagnostic {
        let formattedTime: String
        let epochMillis: Int64
        let deltaMillis: Int64
    }

    @Environment(AppState.self) private var appState

    @State private var showQRLogin = false
    @State private var showManualToken = false
    @State private var showCodeLogin = false

    @State private var isCheckingWhoami = false
    @State private var whoamiProfile: UserProfileInfo?
    @State private var whoamiError: String?
    @State private var whoamiTask: Task<Void, Never>?

    @State private var isCheckingTime = false
    @State private var serverTimeDiagnostic: ServerTimeDiagnostic?
    @State private var serverTimeError: String?
    @State private var serverTimeTask: Task<Void, Never>?

    @State private var verDraft: String = ""
    @State private var mpAppIDDraft: String = ""
    @State private var pendingDeleteAccount: LaiBaoAccount?

    var body: some View {
        NavigationStack {
            List {
                if appState.accounts.isEmpty {
                    loginMethodsSection
                    savedAccountsSection
                } else {
                    savedAccountsSection
                    loginMethodsSection
                }
                diagnosticsSection
                protocolSettingsSection
            }
            .listStyle(.insetGrouped)
            .keyboardDoneToolbar()
            .navigationTitle("账号管理")
            .refreshable {
                appState.refreshWorkspace()
                syncSettingsDrafts()
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showQRLogin = true
                        } label: {
                            Label("公众号扫码登录", systemImage: "qrcode.viewfinder")
                        }
                        Button {
                            showManualToken = true
                        } label: {
                            Label("手动粘贴 Token", systemImage: "key.horizontal.fill")
                        }
                        Button {
                            showCodeLogin = true
                        } label: {
                            Label("微信 Code 登录", systemImage: "terminal.fill")
                        }
                        Divider()
                        Button {
                            appState.refreshWorkspace()
                            syncSettingsDrafts()
                        } label: {
                            Label("刷新本地状态", systemImage: "arrow.clockwise")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("添加或刷新账号")
                }
            }
            .onAppear {
                syncSettingsDrafts()
            }
            .onDisappear {
                whoamiTask?.cancel()
                serverTimeTask?.cancel()
            }
            .sheet(isPresented: $showQRLogin) {
                QRLoginSheet()
            }
            .sheet(isPresented: $showManualToken) {
                ManualTokenSheet()
            }
            .sheet(isPresented: $showCodeLogin) {
                CodeLoginSheet()
            }
            .alert(
                "删除来宝账号",
                isPresented: Binding(
                    get: { pendingDeleteAccount != nil },
                    set: { if !$0 { pendingDeleteAccount = nil } }
                ),
                presenting: pendingDeleteAccount
            ) { account in
                Button("删除「\(account.name)」", role: .destructive) {
                    deleteAccount(account)
                }
                Button("取消", role: .cancel) {}
            } message: { account in
                Text("将从本机配置及 iOS 钥匙串永久移除账号「\(account.name)」的令牌。")
            }
        }
    }

    // MARK: - Sections

    private var loginMethodsSection: some View {
        Section {
            Button {
                showQRLogin = true
            } label: {
                loginActionRow(
                    title: "公众号扫码登录",
                    subtitle: "生成官方二维码并自动轮询状态",
                    badge: "推荐",
                    systemImage: "qrcode.viewfinder",
                    tint: .accentColor
                )
            }
            .buttonStyle(.plain)

            Button {
                showManualToken = true
            } label: {
                loginActionRow(
                    title: "手动粘贴 Token",
                    subtitle: "自动清理 Bearer 前缀并直存钥匙串",
                    badge: nil,
                    systemImage: "key.horizontal.fill",
                    tint: .orange
                )
            }
            .buttonStyle(.plain)

            Button {
                showCodeLogin = true
            } label: {
                loginActionRow(
                    title: "微信 wx.login Code 登录",
                    subtitle: "通过 POST /v4/login 换取会话令牌",
                    badge: nil,
                    systemImage: "terminal.fill",
                    tint: .green
                )
            }
            .buttonStyle(.plain)
        } header: {
            Text(appState.accounts.isEmpty ? "开始登录来宝账号" : "添加其他账号")
        } footer: {
            Text("所有会话令牌仅加密保存于 iOS Keychain（AfterFirstUnlockThisDeviceOnly），绝不落盘明文 JSON。")
        }
    }

    private func loginActionRow(
        title: String,
        subtitle: String,
        badge: String?,
        systemImage: String,
        tint: Color
    ) -> some View {
        HStack(spacing: 12) {
            IconBadge(systemImage: systemImage, tint: tint, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    if let badge {
                        StatusBadge(title: badge, tint: tint)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
    }

    private var savedAccountsSection: some View {
        Section {
            if appState.accounts.isEmpty {
                ContentUnavailableView {
                    Label("尚未添加来宝账号", systemImage: "person.crop.circle.badge.plus")
                } description: {
                    Text("请使用上方扫码、粘贴令牌或微信 Code 完成登录。")
                } actions: {
                    Button {
                        showQRLogin = true
                    } label: {
                        Label("立即扫码登录", systemImage: "qrcode.viewfinder")
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
                }
                .listRowBackground(Color.clear)
            } else {
                ForEach(appState.accounts) { account in
                    accountRow(account)
                }
            }
        } header: {
            Text("已保存的账号（\(appState.accounts.count)）")
        }
    }

    private func accountRow(_ account: LaiBaoAccount) -> some View {
        let isActive = appState.activeAccount?.name == account.name
        let avatarTint: Color = isActive ? .accentColor : .secondary
        let displayInitial = accountInitial(for: account)

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text(displayInitial)
                    .font(.headline.weight(.bold))
                    .foregroundStyle(avatarTint)
                    .frame(width: 40, height: 40)
                    .background(avatarTint.opacity(0.14), in: Circle())
                    .overlay(
                        Circle()
                            .strokeBorder(avatarTint.opacity(0.28), lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(account.name)
                            .font(.headline)
                            .lineLimit(1)
                        if isActive {
                            StatusBadge(title: "当前使用", systemImage: "checkmark.circle.fill", tint: .green)
                        }
                    }

                    if !account.nickName.isEmpty || !account.fuid.isEmpty {
                        Text([
                            account.nickName.isEmpty ? nil : account.nickName,
                            account.fuid.isEmpty ? nil : "FUID \(account.fuid)"
                        ]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 8)

                if !isActive {
                    Button("切换") {
                        switchAccount(account)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            }

            FlowLayout(spacing: 6, lineSpacing: 6) {
                StatusBadge(
                    title: account.hasToken ? "钥匙串 \(account.tokenMask)" : "缺少令牌",
                    systemImage: account.hasToken ? "lock.shield.fill" : "exclamationmark.triangle.fill",
                    tint: account.hasToken ? Color.secondary : Color.orange,
                    monospaced: account.hasToken
                )
                if !account.source.isEmpty {
                    StatusBadge(
                        title: sourceBadgeTitle(account.source),
                        tint: Color.blue
                    )
                }
            }

            if !account.note.isEmpty {
                Text("备注：\(account.note)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive {
                switchAccount(account)
            }
        }
        .contextMenu {
            if !isActive {
                Button {
                    switchAccount(account)
                } label: {
                    Label("设为当前账号", systemImage: "checkmark.circle")
                }
            }
            if !account.fuid.isEmpty {
                Button {
                    UIPasteboard.general.string = account.fuid
                    appState.showToast("已复制 FUID")
                } label: {
                    Label("复制 FUID", systemImage: "doc.on.doc")
                }
            }
            Button(role: .destructive) {
                pendingDeleteAccount = account
            } label: {
                Label("删除账号", systemImage: "trash")
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                pendingDeleteAccount = account
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("会话与服务端时间诊断") {
            Button {
                checkWhoami()
            } label: {
                HStack(spacing: 10) {
                    IconBadge(systemImage: "person.text.rectangle", tint: .blue, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("校验当前账号（Whoami）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text(appState.activeAccount.map { "检测「\($0.name)」令牌有效性" } ?? "请先添加账号")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCheckingWhoami {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(isCheckingWhoami || appState.activeAccount == nil)

            if let profile = whoamiProfile {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("昵称") {
                        Text(profile.nickName.isEmpty ? "（未返回）" : profile.nickName)
                            .font(.subheadline.weight(.medium))
                    }
                    if !profile.fuid.isEmpty {
                        LabeledContent("FUID") {
                            Text(profile.fuid)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    if !profile.openID.isEmpty {
                        LabeledContent("OpenID") {
                            Text(profile.openID)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
                .padding(.vertical, 2)
            }

            if let whoamiError {
                InlineFeedbackBanner(
                    message: whoamiError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }

            Button {
                checkServerTime()
            } label: {
                HStack(spacing: 10) {
                    IconBadge(systemImage: "clock.arrow.2.circlepath", tint: .teal, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("检查服务端时间（epochMillis）")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Text("比对本机时钟与服务端毫秒偏差")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isCheckingTime {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)
            .disabled(isCheckingTime)

            if let diag = serverTimeDiagnostic {
                let isDriftHealthy = abs(diag.deltaMillis) < 1500
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("服务端时间") {
                        Text(diag.formattedTime)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    LabeledContent("本地偏差") {
                        StatusBadge(
                            title: "\(diag.deltaMillis >= 0 ? "+" : "")\(diag.deltaMillis) ms",
                            systemImage: isDriftHealthy ? "checkmark.circle.fill" : "clock.badge.exclamationmark",
                            tint: isDriftHealthy ? Color.green : Color.orange,
                            monospaced: true
                        )
                    }
                    LabeledContent("epochMillis") {
                        Text("\(diag.epochMillis)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                .font(.caption)
                .padding(.vertical, 2)
            }

            if let serverTimeError {
                InlineFeedbackBanner(
                    message: serverTimeError,
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .red
                )
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
            }
        }
    }

    private var protocolSettingsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 6) {
                Text("请求头 ver")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(LaiBaoAPIClient.defaultVer, text: $verDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .mobileInputField(verticalPadding: 8)
            }
            .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text("公众号 mpAppID")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                TextField(LaiBaoAPIClient.defaultMPAppID, text: $mpAppIDDraft)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .mobileInputField(verticalPadding: 8)
            }
            .padding(.vertical, 2)

            HStack(spacing: 10) {
                Button {
                    saveProtocolSettings()
                } label: {
                    Label("保存参数", systemImage: "checkmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)

                Button {
                    verDraft = LaiBaoAPIClient.defaultVer
                    mpAppIDDraft = LaiBaoAPIClient.defaultMPAppID
                    saveProtocolSettings()
                } label: {
                    Text("恢复默认")
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }
            .padding(.vertical, 2)
        } header: {
            Text("工作区协议参数")
        }
    }

    // MARK: - Helpers & Actions

    private func accountInitial(for account: LaiBaoAccount) -> String {
        let base = account.nickName.isEmpty ? account.name : account.nickName
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first.map { String($0).uppercased() } ?? "L"
    }

    private func sourceBadgeTitle(_ source: String) -> String {
        switch source.lowercased() {
        case "qr": return "公众号扫码"
        case "manual": return "手动令牌"
        case "code": return "微信 Code"
        default: return source.uppercased()
        }
    }

    private func syncSettingsDrafts() {
        verDraft = appState.settings.ver
        mpAppIDDraft = appState.settings.mpAppID
    }

    private func saveProtocolSettings() {
        dismissKeyboard()
        var updated = appState.settings
        let cleanVer = verDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMP = mpAppIDDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.ver = cleanVer.isEmpty ? LaiBaoAPIClient.defaultVer : cleanVer
        updated.mpAppID = cleanMP.isEmpty ? LaiBaoAPIClient.defaultMPAppID : cleanMP
        do {
            try appState.saveSettings(updated)
            syncSettingsDrafts()
            appState.showToast("工作区协议参数已保存")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func switchAccount(_ account: LaiBaoAccount) {
        do {
            try appState.workspaceStore.setActiveAccount(account.name)
            appState.refreshWorkspace()
            whoamiProfile = nil
            whoamiError = nil
            appState.showToast("已切换至账号「\(account.name)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func deleteAccount(_ account: LaiBaoAccount) {
        do {
            try appState.workspaceStore.deleteAccount(name: account.name)
            appState.refreshWorkspace()
            whoamiProfile = nil
            whoamiError = nil
            appState.showToast("已删除账号「\(account.name)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func checkWhoami() {
        whoamiTask?.cancel()
        isCheckingWhoami = true
        whoamiError = nil
        whoamiTask = Task {
            defer { isCheckingWhoami = false }
            do {
                let client = try appState.makeAPIClient()
                let profile = try await client.userInfo()
                guard !Task.isCancelled else { return }
                whoamiProfile = profile
                if var active = appState.activeAccount {
                    if !profile.nickName.isEmpty { active.nickName = profile.nickName }
                    if !profile.fuid.isEmpty { active.fuid = profile.fuid }
                    if !profile.openID.isEmpty { active.openID = profile.openID }
                    _ = try? appState.workspaceStore.upsertAccount(active, token: nil, setActive: true)
                    appState.refreshWorkspace()
                }
                appState.showToast("会话有效：\(profile.nickName.isEmpty ? profile.fuid : profile.nickName)")
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                whoamiProfile = nil
                whoamiError = error.localizedDescription
            }
        }
    }

    private func checkServerTime() {
        serverTimeTask?.cancel()
        isCheckingTime = true
        serverTimeError = nil
        serverTimeTask = Task {
            defer { isCheckingTime = false }
            do {
                let client = (try? appState.makeAPIClient()) ?? LaiBaoAPIClient(ver: appState.settings.ver)
                let beforeMs = Int64(Date().timeIntervalSince1970 * 1000)
                let epochMillis = try await client.serverTime()
                guard !Task.isCancelled else { return }
                let afterMs = Int64(Date().timeIntervalSince1970 * 1000)
                let localMidMs = (beforeMs + afterMs) / 2
                let serverDate = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000.0)
                let delta = epochMillis - localMidMs
                serverTimeDiagnostic = ServerTimeDiagnostic(
                    formattedTime: UIFormatters.ymdHMSMillis.string(from: serverDate),
                    epochMillis: epochMillis,
                    deltaMillis: delta
                )
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                serverTimeDiagnostic = nil
                serverTimeError = error.localizedDescription
            }
        }
    }
}

// MARK: - Official Account QR Login Sheet

private struct QRLoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var accountName: String = "default"
    @State private var mpAppID: String = ""
    @State private var note: String = ""
    @State private var showAdvanced: Bool = false

    @State private var session: QRSession?
    @State private var qrImage: UIImage?
    @State private var totalExpireSeconds: Int = 120
    @State private var remainingSeconds: Int = 0
    @State private var statusText: String = "正在向服务端申请二维码..."
    @State private var statusTint: Color = .blue
    @State private var isLoadingQR = false
    @State private var isPolling = false
    @State private var pollingTask: Task<Void, Never>?

    private var willOverwriteExistingAccount: Bool {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = name.isEmpty ? "default" : name
        return appState.accounts.contains(where: { $0.name == target })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("微信扫码登录") {
                    VStack(spacing: 14) {
                        GlassStatusPill(
                            title: statusText,
                            systemImage: isPolling ? "qrcode.viewfinder" : (statusTint == .red ? "exclamationmark.triangle.fill" : "info.circle.fill"),
                            tint: statusTint,
                            lineLimit: 2
                        )

                        if let qrImage {
                            VStack(spacing: 10) {
                                Image(uiImage: qrImage)
                                    .interpolation(.none)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 210, height: 210)
                                    .padding(14)
                                    .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .shadow(color: Color.black.opacity(0.08), radius: 10, y: 4)

                                if isPolling && totalExpireSeconds > 0 {
                                    ProgressView(
                                        value: Double(max(0, min(remainingSeconds, totalExpireSeconds))),
                                        total: Double(totalExpireSeconds)
                                    )
                                    .tint(remainingSeconds <= 15 ? Color.orange : Color.accentColor)
                                    .frame(maxWidth: 210)
                                }
                            }
                        } else if isLoadingQR {
                            VStack(spacing: 12) {
                                ProgressView()
                                    .controlSize(.large)
                                Text("正在申请二维码...")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(height: 210)
                        } else {
                            ContentUnavailableView(
                                "等待生成二维码",
                                systemImage: "qrcode",
                                description: Text("生成后可用微信扫一扫，或复制链接发至微信长按识别。")
                            )
                            .frame(height: 200)
                        }

                        FlowLayout(spacing: 8, lineSpacing: 8) {
                            Button {
                                startQRFlow()
                            } label: {
                                Label(session == nil ? "生成二维码" : "刷新", systemImage: "arrow.clockwise")
                                    .font(.subheadline.weight(.semibold))
                            }
                            .buttonStyle(.glassProminent)
                            .controlSize(.small)
                            .disabled(isLoadingQR)

                            if let url = session?.url, !url.isEmpty {
                                Button {
                                    UIPasteboard.general.string = url
                                    appState.showToast("已复制二维码链接，可发至微信长按识别")
                                } label: {
                                    Label("复制链接", systemImage: "doc.on.doc")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)

                                ShareLink(item: url) {
                                    Label("分享", systemImage: "square.and.arrow.up")
                                        .font(.subheadline)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }

                Section {
                    TextField("账号标识（如 default）", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $note)

                    if willOverwriteExistingAccount {
                        Label("将更新已有账号「\(accountName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "default" : accountName.trimmingCharacters(in: .whitespacesAndNewlines))」的钥匙串令牌", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    DisclosureGroup("高级选项（mpAppID）", isExpanded: $showAdvanced) {
                        TextField("公众号 mpAppID", text: $mpAppID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                    }
                } header: {
                    Text("保存目标账号")
                }
            }
            .keyboardDoneToolbar()
            .navigationTitle("公众号扫码登录")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") {
                        cancelPolling()
                        dismiss()
                    }
                }
            }
            .onAppear {
                if mpAppID.isEmpty {
                    mpAppID = appState.settings.mpAppID
                }
                startQRFlow()
            }
            .onDisappear {
                cancelPolling()
            }
        }
    }

    private func cancelPolling() {
        pollingTask?.cancel()
        pollingTask = nil
        isPolling = false
    }

    private func startQRFlow() {
        cancelPolling()
        isLoadingQR = true
        statusText = "正在向服务端申请二维码..."
        statusTint = .blue
        qrImage = nil
        session = nil

        let targetMP = mpAppID.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = LaiBaoAPIClient(ver: appState.settings.ver)

        pollingTask = Task {
            do {
                let qr = try await client.createQRSession(mpAppID: targetMP.isEmpty ? nil : targetMP)
                guard !Task.isCancelled else { return }
                session = qr
                let expire = max(30, qr.expireSeconds)
                totalExpireSeconds = expire
                remainingSeconds = expire
                if let cgImage = QRCodeRenderer.renderCGImage(from: qr.url, size: 512) {
                    qrImage = UIImage(cgImage: cgImage)
                }
                isLoadingQR = false
                isPolling = true

                let deadline = Date().addingTimeInterval(TimeInterval(expire))
                var lastPoll = Date.distantPast

                while !Task.isCancelled {
                    let left = Int(ceil(deadline.timeIntervalSinceNow))
                    if left <= 0 {
                        remainingSeconds = 0
                        isPolling = false
                        statusText = "二维码已过期，请点击刷新"
                        statusTint = .orange
                        return
                    }
                    remainingSeconds = left
                    statusText = "等待微信扫码确认 · 剩余 \(left) 秒"
                    statusTint = left <= 15 ? .orange : .blue

                    if Date().timeIntervalSince(lastPoll) >= 2.5 {
                        lastPoll = Date()
                        if let login = try await client.checkQR(scene: qr.scene), !login.token.isEmpty {
                            guard !Task.isCancelled else { return }
                            isPolling = false
                            if saveLoggedInAccount(login) {
                                statusText = "扫码登录成功"
                                statusTint = .green
                                dismiss()
                            } else {
                                statusText = "保存令牌失败，请重试"
                                statusTint = .red
                            }
                            return
                        }
                    }

                    try await Task.sleep(for: .seconds(1))
                }
            } catch is CancellationError {
                isLoadingQR = false
                isPolling = false
            } catch {
                isLoadingQR = false
                isPolling = false
                statusText = "失败：\(error.localizedDescription)"
                statusTint = .red
            }
        }
    }

    private func saveLoggedInAccount(_ result: LoginResult) -> Bool {
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "default" : name
        let account = LaiBaoAccount(
            name: finalName,
            baseURL: LaiBaoAPIClient.defaultBaseURL,
            appID: LaiBaoAPIClient.defaultAppID,
            note: note.trimmingCharacters(in: .whitespacesAndNewlines),
            fuid: result.fuid,
            openID: result.openID,
            nickName: result.nickName,
            source: "qr"
        )
        do {
            _ = try appState.workspaceStore.upsertAccount(account, token: result.token, setActive: true)
            appState.refreshWorkspace()
            appState.showToast("扫码登录成功，令牌已安全存入钥匙串")
            return true
        } catch {
            appState.showToast("保存账号失败：\(error.localizedDescription)", isError: true)
            return false
        }
    }
}

// MARK: - Manual Token Login Sheet

private struct ManualTokenSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var accountName: String = "default"
    @State private var tokenInput: String = ""
    @State private var revealToken: Bool = false
    @State private var baseURL: String = LaiBaoAPIClient.defaultBaseURL
    @State private var appID: String = LaiBaoAPIClient.defaultAppID
    @State private var note: String = ""
    @State private var verifyWhoami: Bool = true
    @State private var showAdvanced: Bool = false
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("账号标识（如 default）", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("备注（可选）", text: $note)
                }

                Section {
                    HStack(spacing: 8) {
                        Group {
                            if revealToken {
                                TextField("粘贴 Authorization 令牌（支持含 Bearer 前缀）", text: $tokenInput)
                                    .font(.subheadline.monospaced())
                            } else {
                                SecureField("粘贴 Authorization 令牌（支持含 Bearer 前缀）", text: $tokenInput)
                            }
                        }
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                        Button {
                            revealToken.toggle()
                        } label: {
                            Image(systemName: revealToken ? "eye.slash" : "eye")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealToken ? "隐藏令牌" : "显示令牌")
                    }

                    Button {
                        if let paste = UIPasteboard.general.string, !paste.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            tokenInput = LaiBaoAPIClient.stripAuthPrefix(paste)
                            appState.showToast("已粘贴并清理 Bearer 前缀")
                        } else {
                            appState.showToast("剪贴板为空", isError: true)
                        }
                    } label: {
                        Label("从剪贴板粘贴并清理 Bearer 前缀", systemImage: "doc.on.clipboard")
                    }

                    Toggle("保存前自动校验 Whoami", isOn: $verifyWhoami)
                } header: {
                    Text("会话令牌（仅存 iOS Keychain）")
                }

                Section {
                    DisclosureGroup("高级接口配置", isExpanded: $showAdvanced) {
                        TextField("Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.subheadline.monospaced())
                        TextField("Client-App-Id", text: $appID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
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
            .navigationTitle("手动保存令牌")
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
                        Button("保存") { saveToken() }
                    }
                }
            }
        }
    }

    private func saveToken() {
        dismissKeyboard()
        errorMessage = nil

        let cleanToken = LaiBaoAPIClient.stripAuthPrefix(tokenInput)
        guard !cleanToken.isEmpty else {
            errorMessage = "请输入有效的会话令牌"
            return
        }

        let cleanBase: String
        do {
            cleanBase = try LaiBaoAPIClient.validateBaseURL(baseURL)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "default" : name
        let cleanAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAppID = cleanAppID.isEmpty ? LaiBaoAPIClient.defaultAppID : cleanAppID

        isSaving = true
        Task {
            defer { isSaving = false }
            var nickName = ""
            var fuid = ""
            var openID = ""

            if verifyWhoami {
                do {
                    let client = LaiBaoAPIClient(
                        baseURL: cleanBase,
                        token: cleanToken,
                        appID: finalAppID,
                        ver: appState.settings.ver
                    )
                    let info = try await client.userInfo()
                    nickName = info.nickName
                    fuid = info.fuid
                    openID = info.openID
                } catch {
                    errorMessage = "令牌校验失败：\(error.localizedDescription)"
                    return
                }
            }

            let account = LaiBaoAccount(
                name: finalName,
                baseURL: cleanBase,
                appID: finalAppID,
                note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                fuid: fuid,
                openID: openID,
                nickName: nickName,
                source: "manual"
            )
            do {
                _ = try appState.workspaceStore.upsertAccount(account, token: cleanToken, setActive: true)
                appState.refreshWorkspace()
                appState.showToast("账号「\(finalName)」令牌已安全存入钥匙串")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - WeChat Code Login Sheet

private struct CodeLoginSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var accountName: String = "default"
    @State private var code: String = ""
    @State private var appID: String = LaiBaoAPIClient.defaultAppID
    @State private var baseURL: String = LaiBaoAPIClient.defaultBaseURL
    @State private var note: String = ""
    @State private var showAdvanced: Bool = false
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("wx.login 换取令牌（POST /v4/login）") {
                    TextField("账号标识（如 default）", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    HStack(spacing: 8) {
                        TextField("粘贴一次性 wx.login code", text: $code)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())

                        Button {
                            if let paste = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                               !paste.isEmpty {
                                code = paste
                            } else {
                                appState.showToast("剪贴板为空", isError: true)
                            }
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                        .accessibilityLabel("粘贴 wx.login code")
                    }

                    TextField("备注（可选）", text: $note)
                }

                Section {
                    DisclosureGroup("高级接口配置", isExpanded: $showAdvanced) {
                        TextField("小程序 AppID", text: $appID)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.subheadline.monospaced())
                        TextField("Base URL", text: $baseURL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .font(.subheadline.monospaced())
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
            .navigationTitle("微信 Code 登录")
            .navigationBarTitleDisplayMode(.inline)
            .presentationDragIndicator(.visible)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isLoggingIn {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("登录") { submitCode() }
                    }
                }
            }
        }
    }

    private func submitCode() {
        dismissKeyboard()
        errorMessage = nil
        let cleanCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanCode.isEmpty else {
            errorMessage = "请输入 wx.login code"
            return
        }
        let cleanBase: String
        do {
            cleanBase = try LaiBaoAPIClient.validateBaseURL(baseURL)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        let cleanAppID = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalAppID = cleanAppID.isEmpty ? LaiBaoAPIClient.defaultAppID : cleanAppID
        let name = accountName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = name.isEmpty ? "default" : name

        isLoggingIn = true
        Task {
            defer { isLoggingIn = false }
            do {
                let client = LaiBaoAPIClient(baseURL: cleanBase, appID: finalAppID, ver: appState.settings.ver)
                let res = try await client.loginByCode(cleanCode, appID: finalAppID)
                let account = LaiBaoAccount(
                    name: finalName,
                    baseURL: cleanBase,
                    appID: finalAppID,
                    note: note.trimmingCharacters(in: .whitespacesAndNewlines),
                    fuid: res.fuid,
                    openID: res.openID,
                    nickName: res.nickName,
                    source: "code"
                )
                _ = try appState.workspaceStore.upsertAccount(account, token: res.token, setActive: true)
                appState.refreshWorkspace()
                appState.showToast("微信 Code 登录成功，已切换至「\(finalName)」")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
