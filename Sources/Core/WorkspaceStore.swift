import Foundation

/// Errors thrown by `UserWorkspaceStore`.
public enum WorkspaceError: LocalizedError, Sendable, Equatable {
    case invalidIdentifier(String)
    case accountNotFound(String)
    case invalidPOI(String)
    case storageError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidIdentifier(let detail):
            return detail
        case .accountNotFound(let name):
            return "账号「\(name)」不存在"
        case .invalidPOI(let detail):
            return detail
        case .storageError(let detail):
            return "本地工作区存储失败：\(detail)"
        }
    }
}

/// Thread-safe per-user isolated workspace storage persisted under:
/// `Application Support/LaiBao/users/<safeUserID>/`
/// - `settings.json` (`UserWorkspaceSettings`)
/// - `accounts.json` (`[LaiBaoAccount]` metadata ONLY; bearer tokens live strictly in Keychain!)
/// - `pois.json` (`[POIItem]`)
/// - `reminders.json` (`[ReminderPlan]`)
/// - `run_logs.json` (`[CheckinRunLog]` capped ring buffer with token redaction)
public final class UserWorkspaceStore: @unchecked Sendable {
    public static let maxRunLogs: Int = 200

    private let lock = NSLock()
    private let rootDirectory: URL
    private let secretStore: any SecretStoring

    public init(
        rootDirectory: URL? = nil,
        secretStore: any SecretStoring = KeychainStore()
    ) {
        self.rootDirectory = rootDirectory ?? LocalAuthStore.defaultRootDirectory()
        self.secretStore = secretStore
    }

    // MARK: - Path & ID Validation

    /// Strictly validates an identifier (`userID` / `accountName` / `formID`) against path traversal
    /// and illegal filesystem characters (100% parity with Go `cfg.SanitizeID`).
    public static func sanitizeID(_ id: String) throws -> String {
        guard !id.isEmpty, id.trimmingCharacters(in: .whitespacesAndNewlines) == id else {
            throw WorkspaceError.invalidIdentifier("ID 不能为空或包含首尾空白")
        }
        guard id.count <= 128 else {
            throw WorkspaceError.invalidIdentifier("ID 长度超过 128 字符限制")
        }
        if id == "." || id == ".." || id.contains("..") {
            throw WorkspaceError.invalidIdentifier("ID 包含非法路径穿越片段: \(id)")
        }
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        if id.contains(where: { forbidden.contains($0) }) {
            throw WorkspaceError.invalidIdentifier("ID 包含非法路径字符: \(id)")
        }
        for scalar in id.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                throw WorkspaceError.invalidIdentifier("ID 包含空白或控制字符: \(id)")
            }
        }
        return id
    }

    /// Returns the validated isolated directory URL for a local user.
    public func userDirectory(for userID: String) throws -> URL {
        let safeID = try Self.sanitizeID(userID)
        let usersRoot = rootDirectory.appendingPathComponent("users", isDirectory: true).standardizedFileURL
        let userDir = usersRoot.appendingPathComponent(safeID, isDirectory: true).standardizedFileURL

        let expectedPrefix = usersRoot.path.hasSuffix("/") ? usersRoot.path : usersRoot.path + "/"
        guard userDir.path.hasPrefix(expectedPrefix),
              userDir.lastPathComponent == safeID else {
            throw WorkspaceError.invalidIdentifier("用户目录路径校验失败: \(userID)")
        }
        return userDir
    }

    // MARK: - Settings

    public func loadSettings(for userID: String) throws -> UserWorkspaceSettings {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked(UserWorkspaceSettings.self, from: dir.appendingPathComponent("settings.json"))
            ?? UserWorkspaceSettings()
    }

    public func saveSettings(_ settings: UserWorkspaceSettings, for userID: String) throws {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(settings, to: dir.appendingPathComponent("settings.json"), in: dir)
    }

    // MARK: - Accounts (Metadata on Disk + Tokens in Keychain)

    public func loadAccounts(for userID: String) throws -> [LaiBaoAccount] {
        let safeUserID = try Self.sanitizeID(userID)
        let dir = try userDirectory(for: safeUserID)
        lock.lock()
        defer { lock.unlock() }

        let stored = try readJSONLocked([LaiBaoAccount].self, from: dir.appendingPathComponent("accounts.json")) ?? []
        var refreshed: [LaiBaoAccount] = []
        refreshed.reserveCapacity(stored.count)
        for var account in stored {
            let key = KeychainStore.tokenKey(userID: safeUserID, accountName: account.name)
            if let token = try? secretStore.readSecret(forKey: key), !token.isEmpty {
                account.hasToken = true
                if account.tokenMask.isEmpty {
                    account.tokenMask = LaiBaoAPIClient.maskToken(token)
                }
            } else {
                account.hasToken = false
                account.tokenMask = ""
            }
            refreshed.append(account)
        }
        return refreshed.sorted { $0.name < $1.name }
    }

    /// Saves or updates an account's metadata on disk and (when `token` is provided) stores the stripped
    /// bearer token strictly in iOS Keychain under `(userID, accountName)`.
    @discardableResult
    public func upsertAccount(
        _ account: LaiBaoAccount,
        token: String?,
        setActive: Bool = true,
        for userID: String
    ) throws -> LaiBaoAccount {
        let safeUserID = try Self.sanitizeID(userID)
        let trimmedName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = try Self.sanitizeID(trimmedName.isEmpty ? "default" : trimmedName)
        let dir = try userDirectory(for: safeUserID)

        lock.lock()
        defer { lock.unlock() }

        let key = KeychainStore.tokenKey(userID: safeUserID, accountName: safeName)
        var effectiveHasToken = false
        var effectiveMask = ""

        if let rawToken = token {
            let cleanToken = LaiBaoAPIClient.stripAuthPrefix(rawToken)
            if cleanToken.isEmpty {
                try secretStore.deleteSecret(forKey: key)
                effectiveHasToken = false
                effectiveMask = ""
            } else {
                try secretStore.saveSecret(cleanToken, forKey: key)
                effectiveHasToken = true
                effectiveMask = LaiBaoAPIClient.maskToken(cleanToken)
            }
        } else if let existingToken = try secretStore.readSecret(forKey: key), !existingToken.isEmpty {
            effectiveHasToken = true
            effectiveMask = LaiBaoAPIClient.maskToken(existingToken)
        }

        var updated = account
        updated.name = safeName
        if updated.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.baseURL = LaiBaoAPIClient.defaultBaseURL
        }
        if updated.appID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            updated.appID = LaiBaoAPIClient.defaultAppID
        }
        updated.updatedAt = Date()
        updated.hasToken = effectiveHasToken
        updated.tokenMask = effectiveMask

        let accountsURL = dir.appendingPathComponent("accounts.json")
        var accounts = try readJSONLocked([LaiBaoAccount].self, from: accountsURL) ?? []
        if let idx = accounts.firstIndex(where: { $0.name == safeName }) {
            accounts[idx] = updated
        } else {
            accounts.append(updated)
        }
        accounts.sort { $0.name < $1.name }
        try writeJSONLocked(accounts, to: accountsURL, in: dir)

        let settingsURL = dir.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        if setActive || settings.activeAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.activeAccount = safeName
            try writeJSONLocked(settings, to: settingsURL, in: dir)
        }

        return updated
    }

    public func readToken(accountName: String, for userID: String) throws -> String? {
        let safeUserID = try Self.sanitizeID(userID)
        let safeName = try Self.sanitizeID(accountName.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = KeychainStore.tokenKey(userID: safeUserID, accountName: safeName)
        return try secretStore.readSecret(forKey: key)
    }

    public func setActiveAccount(_ accountName: String, for userID: String) throws {
        let safeUserID = try Self.sanitizeID(userID)
        let safeName = try Self.sanitizeID(accountName.trimmingCharacters(in: .whitespacesAndNewlines))
        let dir = try userDirectory(for: safeUserID)

        lock.lock()
        defer { lock.unlock() }

        let accounts = try readJSONLocked([LaiBaoAccount].self, from: dir.appendingPathComponent("accounts.json")) ?? []
        guard accounts.contains(where: { $0.name == safeName }) else {
            throw WorkspaceError.accountNotFound(safeName)
        }
        let settingsURL = dir.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        settings.activeAccount = safeName
        try writeJSONLocked(settings, to: settingsURL, in: dir)
    }

    public func deleteAccount(name: String, for userID: String) throws {
        let safeUserID = try Self.sanitizeID(userID)
        let safeName = try Self.sanitizeID(name.trimmingCharacters(in: .whitespacesAndNewlines))
        let dir = try userDirectory(for: safeUserID)

        lock.lock()
        defer { lock.unlock() }

        let key = KeychainStore.tokenKey(userID: safeUserID, accountName: safeName)
        try secretStore.deleteSecret(forKey: key)

        let accountsURL = dir.appendingPathComponent("accounts.json")
        var accounts = try readJSONLocked([LaiBaoAccount].self, from: accountsURL) ?? []
        accounts.removeAll { $0.name == safeName }
        accounts.sort { $0.name < $1.name }
        try writeJSONLocked(accounts, to: accountsURL, in: dir)

        let settingsURL = dir.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        if settings.activeAccount == safeName {
            settings.activeAccount = accounts.first?.name ?? "default"
            try writeJSONLocked(settings, to: settingsURL, in: dir)
        }
    }

    /// Builds a ready-to-use `LaiBaoAPIClient` from the specified (or active) account's metadata and Keychain token.
    public func makeAPIClient(
        accountName: String? = nil,
        for userID: String,
        session: URLSession? = nil
    ) throws -> LaiBaoAPIClient {
        let settings = try loadSettings(for: userID)
        let accounts = try loadAccounts(for: userID)
        let requested = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName = requested.isEmpty ? settings.activeAccount : requested

        let account = accounts.first(where: { $0.name == targetName })
            ?? accounts.first
        let resolvedName = account?.name ?? (targetName.isEmpty ? "default" : targetName)
        let token = (try? readToken(accountName: resolvedName, for: userID)) ?? ""

        return LaiBaoAPIClient(
            baseURL: account?.baseURL ?? LaiBaoAPIClient.defaultBaseURL,
            token: token,
            appID: account?.appID ?? LaiBaoAPIClient.defaultAppID,
            ver: settings.ver,
            session: session
        )
    }

    // MARK: - POIs

    public func loadPOIs(for userID: String) throws -> [POIItem] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked([POIItem].self, from: dir.appendingPathComponent("pois.json")) ?? []
    }

    public func savePOIs(_ pois: [POIItem], for userID: String) throws {
        for (idx, poi) in pois.enumerated() {
            do {
                try poi.validate()
            } catch {
                throw WorkspaceError.invalidPOI("第 \(idx + 1) 个点位无效: \(error.localizedDescription)")
            }
        }
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(pois, to: dir.appendingPathComponent("pois.json"), in: dir)
    }

    @discardableResult
    public func upsertPOI(_ poi: POIItem, for userID: String) throws -> [POIItem] {
        do {
            try poi.validate()
        } catch {
            throw WorkspaceError.invalidPOI("点位无效: \(error.localizedDescription)")
        }
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let url = dir.appendingPathComponent("pois.json")
        var list = try readJSONLocked([POIItem].self, from: url) ?? []
        if let idx = list.firstIndex(where: { $0.id == poi.id }) {
            list[idx] = poi
        } else {
            list.append(poi)
        }
        try writeJSONLocked(list, to: url, in: dir)
        return list
    }

    @discardableResult
    public func deletePOI(id: String, for userID: String) throws -> [POIItem] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let url = dir.appendingPathComponent("pois.json")
        var list = try readJSONLocked([POIItem].self, from: url) ?? []
        list.removeAll { $0.id == id }
        try writeJSONLocked(list, to: url, in: dir)
        return list
    }

    // MARK: - Reminders

    public func loadReminders(for userID: String) throws -> [ReminderPlan] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked([ReminderPlan].self, from: dir.appendingPathComponent("reminders.json")) ?? []
    }

    public func saveReminders(_ plans: [ReminderPlan], for userID: String) throws {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(plans, to: dir.appendingPathComponent("reminders.json"), in: dir)
    }

    @discardableResult
    public func upsertReminder(_ plan: ReminderPlan, for userID: String) throws -> [ReminderPlan] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let url = dir.appendingPathComponent("reminders.json")
        var list = try readJSONLocked([ReminderPlan].self, from: url) ?? []
        if let idx = list.firstIndex(where: { $0.id == plan.id }) {
            list[idx] = plan
        } else {
            list.append(plan)
        }
        try writeJSONLocked(list, to: url, in: dir)
        return list
    }

    @discardableResult
    public func deleteReminder(id: String, for userID: String) throws -> [ReminderPlan] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let url = dir.appendingPathComponent("reminders.json")
        var list = try readJSONLocked([ReminderPlan].self, from: url) ?? []
        list.removeAll { $0.id == id }
        try writeJSONLocked(list, to: url, in: dir)
        return list
    }

    /// Loads reminder plans across all provided local users (for Admin Console global overview).
    public func loadAllUsersReminders(users: [PublicLocalUser]) -> [(user: PublicLocalUser, plans: [ReminderPlan])] {
        users.map { user in
            let plans = (try? loadReminders(for: user.id)) ?? []
            return (user: user, plans: plans)
        }
    }

    // MARK: - Sanitized Check-in Run Logs

    public func loadRunLogs(for userID: String, planID: String? = nil) throws -> [CheckinRunLog] {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let all = try readJSONLocked([CheckinRunLog].self, from: dir.appendingPathComponent("run_logs.json")) ?? []
        if let planID, !planID.isEmpty {
            return all.filter { $0.planID == planID }
        }
        return all
    }

    public func appendRunLog(_ log: CheckinRunLog, for userID: String) throws {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        let url = dir.appendingPathComponent("run_logs.json")
        var logs = try readJSONLocked([CheckinRunLog].self, from: url) ?? []

        var sanitized = log
        sanitized.message = Self.sanitizeLogMessage(log.message)
        logs.insert(sanitized, at: 0)
        if logs.count > Self.maxRunLogs {
            logs = Array(logs.prefix(Self.maxRunLogs))
        }
        try writeJSONLocked(logs, to: url, in: dir)
    }

    public func clearRunLogs(for userID: String) throws {
        let dir = try userDirectory(for: userID)
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked([CheckinRunLog](), to: dir.appendingPathComponent("run_logs.json"), in: dir)
    }

    // MARK: - Cascade User Data Deletion

    /// Removes all isolated disk files and all Keychain tokens belonging to `userID`.
    public func deleteUserData(userID: String) throws {
        let safeUserID = try Self.sanitizeID(userID)
        let dir = try userDirectory(for: safeUserID)

        lock.lock()
        defer { lock.unlock() }

        try secretStore.deleteAllSecrets(withPrefix: KeychainStore.userKeyPrefix(userID: safeUserID))

        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            do {
                try fm.removeItem(at: dir)
            } catch {
                throw WorkspaceError.storageError("删除用户数据目录失败: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Private JSON Persistence Helpers

    private func readJSONLocked<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw WorkspaceError.storageError("读取 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw WorkspaceError.storageError("\(url.lastPathComponent) 格式损坏: \(error.localizedDescription)")
        }
    }

    private func writeJSONLocked<T: Encodable>(_ value: T, to url: URL, in directory: URL) throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw WorkspaceError.storageError("创建用户目录失败: \(error.localizedDescription)")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(value)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
        } catch {
            throw WorkspaceError.storageError("写入 \(url.lastPathComponent) 失败: \(error.localizedDescription)")
        }
    }

    /// Redacts accidental `Bearer <token>` or `Authorization:` strings before persisting run logs.
    public static func sanitizeLogMessage(_ message: String) -> String {
        var result = message
        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._\-+/=]{8,}"#,
            #"(?i)(authorization|token)\s*[:=]\s*['"]?[A-Za-z0-9._\-+/=]{8,}['"]?"#
        ]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let range = NSRange(location: 0, length: (result as NSString).length)
                result = regex.stringByReplacingMatches(in: result, options: [], range: range, withTemplate: "[REDACTED]")
            }
        }
        return result
    }
}
