import SwiftUI

/// Local PBKDF2-HMAC-SHA256 password gate & initial admin setup screen
/// rendered on a floating Liquid Glass card over `LiquidGlassBackground`.
struct AuthGateView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.appearsActive) private var appearsActive

    @State private var username: String = ""
    @State private var displayName: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""

    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    @State private var retryAfterSeconds: Int = 0
    @State private var countdownTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            LiquidGlassBackground()

            ScrollView {
                VStack(spacing: 24) {
                    headerSection
                        .padding(.top, 28)

                    GlassEffectContainer(spacing: 16) {
                        VStack(alignment: .leading, spacing: 18) {
                            cardTitleRow

                            if let startupErr = appState.startupErrorMessage {
                                Label(startupErr, systemImage: "exclamationmark.triangle.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.orange)
                            }

                            if appState.needsSetup {
                                setupFields
                            } else {
                                loginFields
                            }

                            if retryAfterSeconds > 0 {
                                HStack(spacing: 8) {
                                    Image(systemName: "hourglass")
                                        .foregroundStyle(.orange)
                                    Text("登录失败次数过多，请在 \(retryAfterSeconds) 秒后重试")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(.orange)
                                }
                                .padding(.vertical, 4)
                            }

                            if let errorMessage, !errorMessage.isEmpty {
                                Label(errorMessage, systemImage: "xmark.octagon.fill")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }

                            actionButtons
                        }
                        .padding(22)
                        .glassEffect(.regular, in: .rect(cornerRadius: 28))
                    }
                    .frame(maxWidth: 440)
                    .opacity(appearsActive ? 1.0 : 0.78)
                    .animation(.easeInOut(duration: 0.2), value: appearsActive)

                    Text("本地独立运行 · PBKDF2-SHA256 加密 · 令牌安全存储于 iOS 钥匙串")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.bottom, 24)
                }
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .onAppear {
            if !appState.needsSetup, username.isEmpty, let candidate = appState.biometricCandidateUser {
                username = candidate.username
            }
        }
        .onDisappear {
            countdownTask?.cancel()
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(.clear)
                    .frame(width: 74, height: 74)
                    .glassEffect(.regular.tint(.accentColor.opacity(0.28)), in: .circle)

                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }

            Text("来宝接龙")
                .font(.largeTitle.bold())

            GlassStatusPill(
                title: appState.needsSetup ? "首次启动 · 初始化本地门禁" : "本地安全门禁已锁定",
                systemImage: appState.needsSetup ? "shield.lefthalf.filled" : "lock.fill",
                tint: .accentColor
            )
        }
    }

    private var cardTitleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(appState.needsSetup ? "初始化管理员账号" : "密码登录")
                .font(.title3.bold())
            Text(
                appState.needsSetup
                    ? "请创建首个本地管理员账号（密码至少 8 位），用于保护多用户工作区与钥匙串凭证。"
                    : "请输入本地账号和密码解锁您的独立工作区。"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    private var setupFields: some View {
        VStack(spacing: 12) {
            labeledInput("用户名（3-32 位字母/数字/._-）") {
                TextField("例如：admin", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }

            labeledInput("显示名（可选）") {
                TextField("例如：管理员", text: $displayName)
            }

            labeledInput("密码（至少 8 位）") {
                SecureField("请输入密码", text: $password)
                    .textContentType(.newPassword)
            }

            labeledInput("确认密码") {
                SecureField("请再次输入密码", text: $confirmPassword)
                    .textContentType(.newPassword)
                    .onSubmit {
                        submitAction()
                    }
            }
        }
    }

    private var loginFields: some View {
        VStack(spacing: 12) {
            labeledInput("用户名") {
                TextField("请输入用户名", text: $username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
            }

            labeledInput("密码") {
                SecureField("请输入密码", text: $password)
                    .textContentType(.password)
                    .onSubmit {
                        submitAction()
                    }
            }
        }
    }

    private func labeledInput<Field: View>(_ title: String, @ViewBuilder field: () -> Field) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            field()
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(Color(.secondarySystemBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var actionButtons: some View {
        VStack(spacing: 10) {
            Button {
                submitAction()
            } label: {
                HStack(spacing: 8) {
                    if isSubmitting {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(appState.needsSetup ? "创建管理员并进入" : "登录")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.glassProminent)
            .disabled(isSubmitting || retryAfterSeconds > 0)

            if !appState.needsSetup, let candidate = appState.biometricCandidateUser {
                let kind = BiometricAuthenticator.availableBiometry()
                Button {
                    biometricUnlockAction()
                } label: {
                    Label(
                        "使用\(kind.displayName)快速解锁（\(candidate.displayName)）",
                        systemImage: kind.systemImageName
                    )
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.glass)
                .disabled(isSubmitting)
            }
        }
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func submitAction() {
        guard !isSubmitting, retryAfterSeconds == 0 else { return }
        errorMessage = nil

        let trimmedUser = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedUser.isEmpty else {
            errorMessage = "请输入用户名"
            return
        }

        if appState.needsSetup {
            guard password.count >= PasswordHasher.minPasswordLength else {
                errorMessage = "密码长度至少需要 \(PasswordHasher.minPasswordLength) 位"
                return
            }
            guard password == confirmPassword else {
                errorMessage = "两次输入的密码不一致"
                return
            }
        } else if password.isEmpty {
            errorMessage = "请输入密码"
            return
        }

        isSubmitting = true
        let targetUser = trimmedUser
        let targetDisplay = displayName
        let targetPassword = password

        Task {
            defer { isSubmitting = false }
            do {
                if appState.needsSetup {
                    try await appState.setupAdmin(
                        username: targetUser,
                        displayName: targetDisplay,
                        password: targetPassword
                    )
                } else {
                    try await appState.login(username: targetUser, password: targetPassword)
                }
                password = ""
                confirmPassword = ""
            } catch let authErr as AuthSecurityError {
                if case .rateLimited(let seconds) = authErr {
                    startRateLimitCountdown(seconds: max(1, seconds))
                    errorMessage = nil
                } else {
                    errorMessage = authErr.localizedDescription
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func biometricUnlockAction() {
        guard !isSubmitting else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                try await appState.unlockWithBiometrics()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func startRateLimitCountdown(seconds: Int) {
        countdownTask?.cancel()
        retryAfterSeconds = seconds
        countdownTask = Task {
            while !Task.isCancelled && retryAfterSeconds > 0 {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                if retryAfterSeconds > 0 {
                    retryAfterSeconds -= 1
                }
            }
        }
    }
}
