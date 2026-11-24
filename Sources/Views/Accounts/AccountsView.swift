import SwiftUI
import UIKit

/// Account & Local Security management tab:
/// - Current local user card (role, change password, Face ID / Touch ID toggle, sign out)
/// - 3 LaiBao login flows (Official Account QR auto-poll, manual Keychain token, WeChat code)
/// - Saved LaiBao accounts list (Keychain mask, switch active, delete)
/// - Live Whoami & Server Time (`epochMillis`) diagnostics
struct AccountsView: View {
    @Environment(AppState.self) private var appState

    @State private var showChangePassword = false
    @State private var showQRLogin = false
    @State private var showManualToken = false
    @State private var showCodeLogin = false

    @State private var isCheckingWhoami = false
    @State private var whoamiProfile: UserProfileInfo?
    @State private var whoamiError: String?

    @State private var isCheckingTime = false
    @State private var serverTimeSummary: String?
    @State private var serverTimeError: String?

    @State private var verDraft: String = ""
    @State private var mpAppIDDraft: String = ""
    @State private var showLogoutConfirm = false
    @State private var pendingDeleteAccount: LaiBaoAccount?

    var body: some View {
        NavigationStack {
            List {
                localUserSection
                loginMethodsSection
                savedAccountsSection
                diagnosticsSection
                protocolSettingsSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("账号与安全")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        appState.refreshWorkspace()
                        syncSettingsDrafts()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("刷新账号列表")
                }
            }
            .onAppear {
                syncSettingsDrafts()
            }
            .sheet(isPresented: $showChangePassword) {
                ChangePasswordSheet()
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
            .confirmationDialog(
                "确认退出当前本地账号？",
                isPresented: $showLogoutConfirm,
                titleVisibility: .visible
            ) {
                Button("退出登录并锁定", role: .destructive) {
                    appState.logout()
                }
                Button("取消", role: .cancel) {}
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

    private var localUserSection: some View {
        Section("当前本地用户") {
            if let user = appState.currentUser {
                HStack(spacing: 12) {
                    Image(systemName: user.role == .admin ? "person.badge.shield.checkmark.fill" : "person.crop.circle.fill")
                        .font(.system(size: 36))
                        .foregroundStyle(user.role == .admin ? Color.accentColor : Color.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text(user.displayName)
                                .font(.headline)
                            GlassStatusPill(
                                title: user.role.displayName,
                                systemImage: user.role == .admin ? "shield.fill" : "person.fill",
                                tint: user.role == .admin ? .blue : .gray
                            )
                        }
                        Text("@\(user.username)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        if let lastLogin = user.lastLoginAt {
                            Text("最近登录：\(lastLogin.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(.vertical, 4)

                Button {
                    showChangePassword = true
                } label: {
                    Label("修改本地登录密码", systemImage: "key.fill")
                }

                if BiometricAuthenticator.isAvailable {
                    let kind = BiometricAuthenticator.availableBiometry()
                    Toggle(isOn: Binding(
                        get: { appState.settings.biometricUnlockEnabled },
                        set: { newValue in
                            toggleBiometric(newValue)
                        }
                    )) {
                        Label("启用\(kind.displayName)快速解锁", systemImage: kind.systemImageName)
                    }
                }

                Button(role: .destructive) {
                    showLogoutConfirm = true
                } label: {
                    Label("锁定并退出当前本地用户", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    private var loginMethodsSection: some View {
        Section {
            Button {
                showQRLogin = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("公众号扫码登录（推荐）")
                            .font(.body.weight(.medium))
                        Text("生成官方二维码并自动轮询登录状态")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "qrcode.viewfinder")
                        .foregroundStyle(Color.accentColor)
                }
            }

            Button {
                showManualToken = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("手动粘贴 Token")
                            .font(.body.weight(.medium))
                        Text("自动去除 Bearer 前缀，直接存入 iOS 钥匙串")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "key.horizontal.fill")
                        .foregroundStyle(.orange)
                }
            }

            Button {
                showCodeLogin = true
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("微信 wx.login Code 登录")
                            .font(.body.weight(.medium))
                        Text("通过 POST /v4/login 换取会话令牌")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "terminal.fill")
                        .foregroundStyle(.green)
                }
            }
        } header: {
            Text("登录 / 添加来宝账号")
        } footer: {
            Text("所有来宝会话令牌仅加密保存在 iOS Keychain 中，绝不写入明文 JSON 文件。")
        }
    }

    private var savedAccountsSection: some View {
        Section("已保存的来宝账号（\(appState.accounts.count)）") {
            if appState.accounts.isEmpty {
                ContentUnavailableView(
                    "尚未添加来宝账号",
                    systemImage: "person.crop.circle.badge.plus",
                    description: Text("请使用上方扫码、粘贴令牌或微信 Code 添加账号。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(appState.accounts) { account in
                    let isActive = appState.activeAccount?.name == account.name
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 8) {
                                    Text(account.name)
                                        .font(.headline)
                                    if isActive {
                                        GlassStatusPill(title: "当前使用", systemImage: "checkmark", tint: .green)
                                    }
                                }
                                if !account.nickName.isEmpty || !account.fuid.isEmpty {
                                    Text([account.nickName, account.fuid.isEmpty ? nil : "fuid: \(account.fuid)"]
                                        .compactMap { $0 }
                                        .filter { !$0.isEmpty }
                                        .joined(separator: " · "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if !isActive {
                                Button("切换") {
                                    switchAccount(account)
                                }
                                .buttonStyle(.glass)
                                .controlSize(.small)
                            }
                        }

                        HStack(spacing: 10) {
                            Label(
                                account.hasToken ? "钥匙串令牌：\(account.tokenMask)" : "未保存令牌",
                                systemImage: account.hasToken ? "lock.shield.fill" : "exclamationmark.triangle"
                            )
                            .font(.caption.monospaced())
                            .foregroundStyle(account.hasToken ? Color.secondary : Color.orange)
                            Spacer()
                            if !account.source.isEmpty {
                                Text(account.source.uppercased())
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if !account.note.isEmpty {
                            Text("备注：\(account.note)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            pendingDeleteAccount = account
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var diagnosticsSection: some View {
        Section("会话与服务端时间诊断") {
            Button {
                checkWhoami()
            } label: {
                HStack {
                    Label("校验当前账号（Whoami）", systemImage: "person.text.rectangle")
                    Spacer()
                    if isCheckingWhoami {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isCheckingWhoami || appState.activeAccount == nil)

            if let profile = whoamiProfile {
                VStack(alignment: .leading, spacing: 4) {
                    Text("昵称：\(profile.nickName.isEmpty ? "（未返回）" : profile.nickName)")
                        .font(.subheadline.weight(.medium))
                    if !profile.fuid.isEmpty {
                        Text("FUID：\(profile.fuid)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    if !profile.openID.isEmpty {
                        Text("OpenID：\(profile.openID)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
            }
            if let whoamiError {
                Label(whoamiError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                checkServerTime()
            } label: {
                HStack {
                    Label("检查服务端时间（epochMillis）", systemImage: "clock.arrow.2.circlepath")
                    Spacer()
                    if isCheckingTime {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
            }
            .disabled(isCheckingTime)

            if let serverTimeSummary {
                Text(serverTimeSummary)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            if let serverTimeError {
                Label(serverTimeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var protocolSettingsSection: some View {
        Section("工作区协议参数") {
            HStack {
                Text("请求头 ver")
                Spacer()
                TextField(LaiBaoAPIClient.defaultVer, text: $verDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            HStack {
                Text("公众号 mpAppID")
                Spacer()
                TextField(LaiBaoAPIClient.defaultMPAppID, text: $mpAppIDDraft)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.body.monospaced())
            }
            Button("保存协议参数") {
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
        }
    }

    // MARK: - Actions

    private func syncSettingsDrafts() {
        verDraft = appState.settings.ver
        mpAppIDDraft = appState.settings.mpAppID
    }

    private func toggleBiometric(_ enabled: Bool) {
        var updated = appState.settings
        updated.biometricUnlockEnabled = enabled
        do {
            try appState.saveSettings(updated)
            appState.showToast(enabled ? "已开启生物识别快速解锁" : "已关闭生物识别快速解锁")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func switchAccount(_ account: LaiBaoAccount) {
        guard let user = appState.currentUser else { return }
        do {
            try appState.workspaceStore.setActiveAccount(account.name, for: user.id)
            appState.refreshWorkspace()
            whoamiProfile = nil
            whoamiError = nil
            appState.showToast("已切换至账号「\(account.name)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func deleteAccount(_ account: LaiBaoAccount) {
        guard let user = appState.currentUser else { return }
        do {
            try appState.workspaceStore.deleteAccount(name: account.name, for: user.id)
            appState.refreshWorkspace()
            appState.showToast("已删除账号「\(account.name)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func checkWhoami() {
        guard let user = appState.currentUser else { return }
        isCheckingWhoami = true
        whoamiError = nil
        Task {
            defer { isCheckingWhoami = false }
            do {
                let client = try appState.makeAPIClient()
                let profile = try await client.userInfo()
                whoamiProfile = profile
                if var active = appState.activeAccount {
                    if !profile.nickName.isEmpty { active.nickName = profile.nickName }
                    if !profile.fuid.isEmpty { active.fuid = profile.fuid }
                    if !profile.openID.isEmpty { active.openID = profile.openID }
                    _ = try? appState.workspaceStore.upsertAccount(active, token: nil, setActive: true, for: user.id)
                    appState.refreshWorkspace()
                }
                appState.showToast("会话有效：\(profile.nickName.isEmpty ? profile.fuid : profile.nickName)")
            } catch {
                whoamiProfile = nil
                whoamiError = error.localizedDescription
            }
        }
    }

    private func checkServerTime() {
        isCheckingTime = true
        serverTimeError = nil
        Task {
            defer { isCheckingTime = false }
            do {
                let client = (try? appState.makeAPIClient()) ?? LaiBaoAPIClient(ver: appState.settings.ver)
                let beforeMs = Int64(Date().timeIntervalSince1970 * 1000)
                let epochMillis = try await client.serverTime()
                let afterMs = Int64(Date().timeIntervalSince1970 * 1000)
                let localMidMs = (beforeMs + afterMs) / 2
                let serverDate = Date(timeIntervalSince1970: TimeInterval(epochMillis) / 1000.0)
                let delta = epochMillis - localMidMs
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                serverTimeSummary = "服务端：\(formatter.string(from: serverDate))（epochMillis=\(epochMillis)，本地偏差 \(delta >= 0 ? "+" : "")\(delta) ms）"
            } catch {
                serverTimeSummary = nil
                serverTimeError = error.localizedDescription
            }
        }
    }
}

// MARK: - Change Password Sheet

private struct ChangePasswordSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var oldPassword = ""
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var isSaving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("验证当前密码") {
                    SecureField("当前密码", text: $oldPassword)
                        .textContentType(.password)
                }
                Section("设置新密码（至少 8 位）") {
                    SecureField("新密码", text: $newPassword)
                        .textContentType(.newPassword)
                    SecureField("确认新密码", text: $confirmPassword)
                        .textContentType(.newPassword)
                }
                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("修改本地密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { savePassword() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func savePassword() {
        guard let user = appState.currentUser else { return }
        errorMessage = nil
        guard newPassword.count >= PasswordHasher.minPasswordLength else {
            errorMessage = "新密码长度至少需要 \(PasswordHasher.minPasswordLength) 位"
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = "两次输入的新密码不一致"
            return
        }
        isSaving = true
        let store = appState.authStore
        let userID = user.id
        let oldPW = oldPassword
        let newPW = newPassword
        Task {
            defer { isSaving = false }
            do {
                try await Task.detached(priority: .userInitiated) {
                    try store.changeOwnPassword(userID: userID, oldPassword: oldPW, newPassword: newPW)
                }.value
                appState.showToast("本地登录密码已更新")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
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

    @State private var session: QRSession?
    @State private var qrImage: UIImage?
    @State private var remainingSeconds: Int = 0
    @State private var statusText: String = "点击下方按钮生成登录二维码"
    @State private var statusTint: Color = .blue
    @State private var isLoadingQR = false
    @State private var isPolling = false
    @State private var pollingTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号配置") {
                    TextField("账号标识（如 default）", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("公众号 mpAppID", text: $mpAppID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.body.monospaced())
                    TextField("备注（可选）", text: $note)
                }

                Section("微信扫码区") {
                    VStack(spacing: 14) {
                        GlassStatusPill(
                            title: statusText,
                            systemImage: isPolling ? "qrcode.viewfinder" : "info.circle",
                            tint: statusTint
                        )

                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 220, height: 220)
                                .padding(14)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        } else if isLoadingQR {
                            ProgressView("正在申请二维码...")
                                .frame(height: 220)
                        } else {
                            ContentUnavailableView(
                                "等待生成二维码",
                                systemImage: "qrcode",
                                description: Text("生成后使用微信扫一扫或长按识别即可自动回传令牌。")
                            )
                            .frame(height: 200)
                        }

                        HStack(spacing: 10) {
                            Button {
                                startQRFlow()
                            } label: {
                                Label(session == nil ? "生成二维码" : "刷新二维码", systemImage: "arrow.clockwise")
                            }
                            .buttonStyle(.glassProminent)
                            .disabled(isLoadingQR)

                            if let url = session?.url, !url.isEmpty {
                                Button {
                                    UIPasteboard.general.string = url
                                    appState.showToast("已复制二维码链接，可发至微信长按识别")
                                } label: {
                                    Label("复制链接", systemImage: "doc.on.doc")
                                }
                                .buttonStyle(.glass)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                }
            }
            .navigationTitle("公众号扫码登录")
            .navigationBarTitleDisplayMode(.inline)
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
                remainingSeconds = max(30, qr.expireSeconds)
                if let cgImage = QRCodeRenderer.renderCGImage(from: qr.url, size: 512) {
                    qrImage = UIImage(cgImage: cgImage)
                }
                isLoadingQR = false
                isPolling = true

                let deadline = Date().addingTimeInterval(TimeInterval(remainingSeconds))
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
                    statusTint = .blue

                    if Date().timeIntervalSince(lastPoll) >= 2.5 {
                        lastPoll = Date()
                        if let login = try await client.checkQR(scene: qr.scene), !login.token.isEmpty {
                            saveLoggedInAccount(login)
                            isPolling = false
                            statusText = "扫码登录成功"
                            statusTint = .green
                            dismiss()
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

    private func saveLoggedInAccount(_ result: LoginResult) {
        guard let user = appState.currentUser else { return }
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
            _ = try appState.workspaceStore.upsertAccount(account, token: result.token, setActive: true, for: user.id)
            appState.refreshWorkspace()
            appState.showToast("扫码登录成功，令牌已安全存入钥匙串")
        } catch {
            appState.showToast("保存账号失败：\(error.localizedDescription)", isError: true)
        }
    }
}

// MARK: - Manual Token Login Sheet

private struct ManualTokenSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var accountName: String = "default"
    @State private var tokenInput: String = ""
    @State private var baseURL: String = LaiBaoAPIClient.defaultBaseURL
    @State private var appID: String = LaiBaoAPIClient.defaultAppID
    @State private var note: String = ""
    @State private var verifyWhoami: Bool = true
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
                    SecureField("粘贴 Authorization 令牌（支持含 Bearer 前缀）", text: $tokenInput)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button {
                        if let paste = UIPasteboard.general.string {
                            tokenInput = LaiBaoAPIClient.stripAuthPrefix(paste)
                        }
                    } label: {
                        Label("从剪贴板粘贴并自动清理 Bearer 前缀", systemImage: "doc.on.clipboard")
                    }
                } header: {
                    Text("会话令牌（仅存 iOS Keychain）")
                }

                Section("高级接口配置") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Client-App-Id", text: $appID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Toggle("保存后立即校验 Whoami", isOn: $verifyWhoami)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("手动保存令牌")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { saveToken() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func saveToken() {
        guard let user = appState.currentUser else { return }
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
                _ = try appState.workspaceStore.upsertAccount(account, token: cleanToken, setActive: true, for: user.id)
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
    @State private var isLoggingIn: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("wx.login 换取令牌（POST /v4/login）") {
                    TextField("账号标识（如 default）", text: $accountName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("粘贴一次性 wx.login code", text: $code)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("小程序 AppID", text: $appID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("备注（可选）", text: $note)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("微信 Code 登录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("登录") { submitCode() }
                        .disabled(isLoggingIn)
                }
            }
        }
    }

    private func submitCode() {
        guard let user = appState.currentUser else { return }
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
                _ = try appState.workspaceStore.upsertAccount(account, token: res.token, setActive: true, for: user.id)
                appState.refreshWorkspace()
                appState.showToast("微信 Code 登录成功，已切换至「\(finalName)」")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
