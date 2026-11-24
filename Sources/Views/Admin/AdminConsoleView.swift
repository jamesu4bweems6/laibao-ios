import SwiftUI

/// Admin-only local multi-user management console & cross-user reminder overview.
/// Enforces last-admin lockout protection and cascades workspace/Keychain/notification cleanup on deletion.
struct AdminConsoleView: View {
    private struct UserRemindersGroup: Identifiable {
        var id: String { user.id }
        let user: PublicLocalUser
        let plans: [ReminderPlan]
    }

    @Environment(AppState.self) private var appState

    @State private var users: [PublicLocalUser] = []
    @State private var allReminders: [UserRemindersGroup] = []
    @State private var showCreateUser = false
    @State private var resetPasswordTarget: PublicLocalUser?
    @State private var deleteTarget: PublicLocalUser?

    var body: some View {
        NavigationStack {
            Group {
                if let current = appState.currentUser, current.role == .admin {
                    List {
                        usersSection(currentAdmin: current)
                        globalRemindersSection
                    }
                    .listStyle(.insetGrouped)
                } else {
                    ContentUnavailableView(
                        "仅管理员可访问",
                        systemImage: "shield.slash.fill",
                        description: Text("请使用本地管理员账号登录后管理用户与全局提醒。")
                    )
                }
            }
            .navigationTitle("管理员控制台")
            .toolbar {
                if appState.currentUser?.role == .admin {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            reloadAdminData()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .accessibilityLabel("刷新管理数据")
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showCreateUser = true
                        } label: {
                            Label("新建用户", systemImage: "person.badge.plus")
                        }
                    }
                }
            }
            .onAppear {
                reloadAdminData()
            }
            .sheet(isPresented: $showCreateUser) {
                CreateUserSheet {
                    reloadAdminData()
                }
            }
            .sheet(item: $resetPasswordTarget) { target in
                ResetPasswordSheet(targetUser: target) {
                    reloadAdminData()
                }
            }
            .alert(
                "删除本地用户",
                isPresented: Binding(
                    get: { deleteTarget != nil },
                    set: { if !$0 { deleteTarget = nil } }
                ),
                presenting: deleteTarget
            ) { target in
                Button("永久删除「\(target.username)」", role: .destructive) {
                    performDelete(target: target)
                }
                Button("取消", role: .cancel) {}
            } message: { target in
                Text("将永久删除用户「\(target.displayName)」(@\(target.username)) 及其独立的来宝账号、钥匙串令牌、POI 点位与本地提醒计划。")
            }
        }
    }

    // MARK: - Sections

    private func usersSection(currentAdmin: PublicLocalUser) -> some View {
        Section("本地用户列表（\(users.count)）") {
            ForEach(users) { user in
                let isSelf = user.id == currentAdmin.id
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(user.displayName)
                                    .font(.headline)
                                if isSelf {
                                    Text("当前")
                                        .font(.caption2.weight(.semibold))
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            Text("@\(user.username) · ID: \(user.id)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        GlassStatusPill(
                            title: user.role.displayName,
                            systemImage: user.role == .admin ? "shield.fill" : "person.fill",
                            tint: user.role == .admin ? .blue : .gray
                        )
                        if user.disabled {
                            GlassStatusPill(title: "已禁用", tint: .red)
                        }
                    }

                    HStack(spacing: 12) {
                        Text("创建：\(user.createdAt.formatted(date: .abbreviated, time: .omitted))")
                        if let lastLogin = user.lastLoginAt {
                            Text("最近登录：\(lastLogin.formatted(date: .abbreviated, time: .shortened))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                    HStack(spacing: 8) {
                        if !isSelf {
                            Button(user.disabled ? "启用" : "禁用") {
                                toggleDisabled(user)
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                        }

                        Button(user.role == .admin ? "降为普通用户" : "设为管理员") {
                            toggleRole(user)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        Button("重置密码") {
                            resetPasswordTarget = user
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)

                        if !isSelf {
                            Button(role: .destructive) {
                                deleteTarget = user
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.glass)
                            .controlSize(.small)
                            .accessibilityLabel("删除用户 \(user.username)")
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    private var globalRemindersSection: some View {
        Section("全用户提醒计划总览") {
            let totalPlans = allReminders.reduce(0) { $0 + $1.plans.count }
            if totalPlans == 0 {
                Text("当前所有本地用户均未创建提醒计划。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(allReminders) { entry in
                    if !entry.plans.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("\(entry.user.displayName) (@\(entry.user.username))")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("\(entry.plans.count) 个计划")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(entry.plans) { plan in
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: plan.enabled ? "bell.badge.fill" : "bell.slash")
                                        .foregroundStyle(plan.enabled ? Color.green : Color.secondary)
                                        .font(.caption)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text("\(plan.name) · 表单 \(plan.formID)")
                                            .font(.caption.weight(.medium))
                                        Text("时间：\(plan.clocks.joined(separator: ", ")) · 账号：\(plan.accountName)\(plan.lastRunStatus.isEmpty ? "" : " · \(plan.lastRunStatus)")")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .padding(.leading, 4)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func reloadAdminData() {
        let fetched = appState.authStore.listUsers()
        users = fetched
        allReminders = appState.workspaceStore
            .loadAllUsersReminders(users: fetched)
            .map { UserRemindersGroup(user: $0.user, plans: $0.plans) }
        if let currentID = appState.currentUser?.id {
            guard let refreshedSelf = appState.authStore.getUser(id: currentID), !refreshedSelf.disabled else {
                appState.logout()
                return
            }
            appState.currentUser = refreshedSelf
        }
    }

    private func toggleDisabled(_ user: PublicLocalUser) {
        if user.id == appState.currentUser?.id {
            appState.showToast("不能禁用当前登录的管理员账号", isError: true)
            return
        }
        do {
            _ = try appState.authStore.setUserDisabled(userID: user.id, disabled: !user.disabled)
            reloadAdminData()
            appState.showToast("已\(user.disabled ? "启用" : "禁用")用户「\(user.username)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func toggleRole(_ user: PublicLocalUser) {
        let nextRole: LocalUserRole = user.role == .admin ? .user : .admin
        do {
            _ = try appState.authStore.setUserRole(userID: user.id, role: nextRole)
            reloadAdminData()
            appState.showToast("已将「\(user.username)」角色修改为\(nextRole.displayName)")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func performDelete(target: PublicLocalUser) {
        guard let actor = appState.currentUser else { return }
        do {
            try appState.authStore.deleteUser(actorID: actor.id, targetUserID: target.id)
            try? appState.workspaceStore.deleteUserData(userID: target.id)
            Task {
                await ReminderScheduler.removeNotifications(for: target.id)
            }
            reloadAdminData()
            appState.showToast("已删除用户「\(target.username)」并清理隔离工作区与钥匙串")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }
}

// MARK: - Create User Sheet

private struct CreateUserSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let onCreated: () -> Void

    @State private var username: String = ""
    @State private var displayName: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var role: LocalUserRole = .user
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("账号信息") {
                    TextField("用户名（3-32 位字母/数字/._-）", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("显示名（可选）", text: $displayName)
                    Picker("角色权限", selection: $role) {
                        ForEach(LocalUserRole.allCases) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                }

                Section("初始密码（至少 8 位）") {
                    SecureField("密码", text: $password)
                        .textContentType(.newPassword)
                    SecureField("确认密码", text: $confirmPassword)
                        .textContentType(.newPassword)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("新建本地用户")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") { createUser() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func createUser() {
        errorMessage = nil
        guard password.count >= PasswordHasher.minPasswordLength else {
            errorMessage = "密码长度至少需要 \(PasswordHasher.minPasswordLength) 位"
            return
        }
        guard password == confirmPassword else {
            errorMessage = "两次输入的密码不一致"
            return
        }

        isSaving = true
        let store = appState.authStore
        let targetUser = username
        let targetDisplay = displayName
        let targetPassword = password
        let targetRole = role

        Task {
            defer { isSaving = false }
            do {
                let created = try await Task.detached(priority: .userInitiated) {
                    try store.createUser(
                        username: targetUser,
                        displayName: targetDisplay,
                        password: targetPassword,
                        role: targetRole
                    )
                }.value
                onCreated()
                appState.showToast("已创建本地用户「\(created.username)」")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Reset Password Sheet

private struct ResetPasswordSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let targetUser: PublicLocalUser
    let onReset: () -> Void

    @State private var newPassword: String = ""
    @State private var confirmPassword: String = ""
    @State private var isSaving: Bool = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("目标用户") {
                    Text("\(targetUser.displayName) (@\(targetUser.username))")
                        .font(.headline)
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
            .navigationTitle("重置用户密码")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("确认重置") { resetPassword() }
                        .disabled(isSaving)
                }
            }
        }
    }

    private func resetPassword() {
        errorMessage = nil
        guard newPassword.count >= PasswordHasher.minPasswordLength else {
            errorMessage = "密码长度至少需要 \(PasswordHasher.minPasswordLength) 位"
            return
        }
        guard newPassword == confirmPassword else {
            errorMessage = "两次输入的密码不一致"
            return
        }

        isSaving = true
        let store = appState.authStore
        let uid = targetUser.id
        let pw = newPassword
        Task {
            defer { isSaving = false }
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try store.resetUserPassword(userID: uid, newPassword: pw)
                }.value
                onReset()
                appState.showToast("已重置「\(targetUser.username)」的密码")
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
