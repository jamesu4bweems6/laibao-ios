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

/// Thread-safe single-user local workspace storage persisted under:
/// `Application Support/LaiBao/`
/// - `settings.json` (`UserWorkspaceSettings`)
/// - `accounts.json` (`[LaiBaoAccount]` metadata ONLY; bearer tokens live strictly in iOS Keychain!)
/// - `pois.json` (`[POIItem]`)
/// - `reminders.json` (`[ReminderPlan]`)
/// - `run_logs.json` (`[CheckinRunLog]` capped ring buffer with token redaction)
public final class UserWorkspaceStore: @unchecked Sendable {
    public static let maxRunLogs: Int = 200

    private let lock = NSLock()
    private let rootDirectory: URL
    private let secretStore: any SecretStoring

    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LaiBao", isDirectory: true)
    }

    public init(
        rootDirectory: URL? = nil,
        secretStore: any SecretStoring = KeychainStore()
    ) {
        self.rootDirectory = (rootDirectory ?? Self.defaultRootDirectory()).standardizedFileURL
        self.secretStore = secretStore
    }

    /// Root directory where local JSON workspace files are stored.
    public var workspaceDirectory: URL {
        rootDirectory
    }

    // MARK: - Path & ID Validation

    /// Strictly validates an identifier (`accountName` / `formID`) against path traversal
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

    // MARK: - Settings

    public func loadSettings() throws -> UserWorkspaceSettings {
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked(UserWorkspaceSettings.self, from: rootDirectory.appendingPathComponent("settings.json"))
            ?? UserWorkspaceSettings()
    }

    public func saveSettings(_ settings: UserWorkspaceSettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(settings, to: rootDirectory.appendingPathComponent("settings.json"), in: rootDirectory)
    }

    // MARK: - Accounts (Metadata on Disk + Tokens in Keychain)

    public func loadAccounts() throws -> [LaiBaoAccount] {
        lock.lock()
        defer { lock.unlock() }

        let stored = try readJSONLocked([LaiBaoAccount].self, from: rootDirectory.appendingPathComponent("accounts.json")) ?? []
        var refreshed: [LaiBaoAccount] = []
        refreshed.reserveCapacity(stored.count)
        for var account in stored {
            let key = KeychainStore.tokenKey(accountName: account.name)
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
    /// bearer token strictly in iOS Keychain keyed by `accountName`.
    @discardableResult
    public func upsertAccount(
        _ account: LaiBaoAccount,
        token: String?,
        setActive: Bool = true
    ) throws -> LaiBaoAccount {
        let trimmedName = account.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = try Self.sanitizeID(trimmedName.isEmpty ? "default" : trimmedName)

        lock.lock()
        defer { lock.unlock() }

        let key = KeychainStore.tokenKey(accountName: safeName)
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

        let accountsURL = rootDirectory.appendingPathComponent("accounts.json")
        var accounts = try readJSONLocked([LaiBaoAccount].self, from: accountsURL) ?? []
        if let idx = accounts.firstIndex(where: { $0.name == safeName }) {
            accounts[idx] = updated
        } else {
            accounts.append(updated)
        }
        accounts.sort { $0.name < $1.name }
        try writeJSONLocked(accounts, to: accountsURL, in: rootDirectory)

        let settingsURL = rootDirectory.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        if setActive || settings.activeAccount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            settings.activeAccount = safeName
            try writeJSONLocked(settings, to: settingsURL, in: rootDirectory)
        }

        return updated
    }

    public func readToken(accountName: String) throws -> String? {
        let safeName = try Self.sanitizeID(accountName.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = KeychainStore.tokenKey(accountName: safeName)
        return try secretStore.readSecret(forKey: key)
    }

    public func setActiveAccount(_ accountName: String) throws {
        let safeName = try Self.sanitizeID(accountName.trimmingCharacters(in: .whitespacesAndNewlines))

        lock.lock()
        defer { lock.unlock() }

        let accounts = try readJSONLocked([LaiBaoAccount].self, from: rootDirectory.appendingPathComponent("accounts.json")) ?? []
        guard accounts.contains(where: { $0.name == safeName }) else {
            throw WorkspaceError.accountNotFound(safeName)
        }
        let settingsURL = rootDirectory.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        settings.activeAccount = safeName
        try writeJSONLocked(settings, to: settingsURL, in: rootDirectory)
    }

    public func deleteAccount(name: String) throws {
        let safeName = try Self.sanitizeID(name.trimmingCharacters(in: .whitespacesAndNewlines))

        lock.lock()
        defer { lock.unlock() }

        let key = KeychainStore.tokenKey(accountName: safeName)
        try secretStore.deleteSecret(forKey: key)

        let accountsURL = rootDirectory.appendingPathComponent("accounts.json")
        var accounts = try readJSONLocked([LaiBaoAccount].self, from: accountsURL) ?? []
        accounts.removeAll { $0.name == safeName }
        accounts.sort { $0.name < $1.name }
        try writeJSONLocked(accounts, to: accountsURL, in: rootDirectory)

        let settingsURL = rootDirectory.appendingPathComponent("settings.json")
        var settings = try readJSONLocked(UserWorkspaceSettings.self, from: settingsURL) ?? UserWorkspaceSettings()
        if settings.activeAccount == safeName {
            settings.activeAccount = accounts.first?.name ?? "default"
            try writeJSONLocked(settings, to: settingsURL, in: rootDirectory)
        }
    }

    /// Builds a ready-to-use `LaiBaoAPIClient` from the specified (or active) account's metadata and Keychain token.
    public func makeAPIClient(
        accountName: String? = nil,
        session: URLSession? = nil
    ) throws -> LaiBaoAPIClient {
        let settings = try loadSettings()
        let accounts = try loadAccounts()
        let requested = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let targetName = requested.isEmpty ? settings.activeAccount : requested

        let account = accounts.first(where: { $0.name == targetName })
            ?? accounts.first
        let resolvedName = account?.name ?? (targetName.isEmpty ? "default" : targetName)
        let token = (try? readToken(accountName: resolvedName)) ?? ""

        return LaiBaoAPIClient(
            baseURL: account?.baseURL ?? LaiBaoAPIClient.defaultBaseURL,
            token: token,
            appID: account?.appID ?? LaiBaoAPIClient.defaultAppID,
            ver: settings.ver,
            session: session
        )
    }

    // MARK: - POIs

    public func loadPOIs() throws -> [POIItem] {
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked([POIItem].self, from: rootDirectory.appendingPathComponent("pois.json")) ?? []
    }

    public func savePOIs(_ pois: [POIItem]) throws {
        for (idx, poi) in pois.enumerated() {
            do {
                try poi.validate()
            } catch {
                throw WorkspaceError.invalidPOI("第 \(idx + 1) 个点位无效: \(error.localizedDescription)")
            }
        }
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(pois, to: rootDirectory.appendingPathComponent("pois.json"), in: rootDirectory)
    }

    @discardableResult
    public func upsertPOI(_ poi: POIItem) throws -> [POIItem] {
        do {
            try poi.validate()
        } catch {
            throw WorkspaceError.invalidPOI("点位无效: \(error.localizedDescription)")
        }
        lock.lock()
        defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent("pois.json")
        var list = try readJSONLocked([POIItem].self, from: url) ?? []
        if let idx = list.firstIndex(where: { $0.id == poi.id }) {
            list[idx] = poi
        } else {
            list.append(poi)
        }
        try writeJSONLocked(list, to: url, in: rootDirectory)
        return list
    }

    @discardableResult
    public func deletePOI(id: String) throws -> [POIItem] {
        lock.lock()
        defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent("pois.json")
        var list = try readJSONLocked([POIItem].self, from: url) ?? []
        list.removeAll { $0.id == id }
        try writeJSONLocked(list, to: url, in: rootDirectory)
        return list
    }

    // MARK: - Reminders

    public func loadReminders() throws -> [ReminderPlan] {
        lock.lock()
        defer { lock.unlock() }
        return try readJSONLocked([ReminderPlan].self, from: rootDirectory.appendingPathComponent("reminders.json")) ?? []
    }

    public func saveReminders(_ plans: [ReminderPlan]) throws {
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked(plans, to: rootDirectory.appendingPathComponent("reminders.json"), in: rootDirectory)
    }

    @discardableResult
    public func upsertReminder(_ plan: ReminderPlan) throws -> [ReminderPlan] {
        lock.lock()
        defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent("reminders.json")
        var list = try readJSONLocked([ReminderPlan].self, from: url) ?? []
        if let idx = list.firstIndex(where: { $0.id == plan.id }) {
            list[idx] = plan
        } else {
            list.append(plan)
        }
        try writeJSONLocked(list, to: url, in: rootDirectory)
        return list
    }

    @discardableResult
    public func deleteReminder(id: String) throws -> [ReminderPlan] {
        lock.lock()
        defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent("reminders.json")
        var list = try readJSONLocked([ReminderPlan].self, from: url) ?? []
        list.removeAll { $0.id == id }
        try writeJSONLocked(list, to: url, in: rootDirectory)
        return list
    }

    // MARK: - Sanitized Check-in Run Logs

    public func loadRunLogs(planID: String? = nil) throws -> [CheckinRunLog] {
        lock.lock()
        defer { lock.unlock() }
        let all = try readJSONLocked([CheckinRunLog].self, from: rootDirectory.appendingPathComponent("run_logs.json")) ?? []
        if let planID, !planID.isEmpty {
            return all.filter { $0.planID == planID }
        }
        return all
    }

    public func appendRunLog(_ log: CheckinRunLog) throws {
        lock.lock()
        defer { lock.unlock() }
        let url = rootDirectory.appendingPathComponent("run_logs.json")
        var logs = try readJSONLocked([CheckinRunLog].self, from: url) ?? []

        var sanitized = log
        sanitized.message = Self.sanitizeLogMessage(log.message)
        logs.insert(sanitized, at: 0)
        if logs.count > Self.maxRunLogs {
            logs = Array(logs.prefix(Self.maxRunLogs))
        }
        try writeJSONLocked(logs, to: url, in: rootDirectory)
    }

    public func clearRunLogs() throws {
        lock.lock()
        defer { lock.unlock() }
        try writeJSONLocked([CheckinRunLog](), to: rootDirectory.appendingPathComponent("run_logs.json"), in: rootDirectory)
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
            throw WorkspaceError.storageError("创建本地数据目录失败: \(error.localizedDescription)")
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
