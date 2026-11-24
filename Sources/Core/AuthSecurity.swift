import CommonCrypto
import Foundation
import LocalAuthentication
import Security

// MARK: - Auth & Security Errors

public enum AuthSecurityError: LocalizedError, Sendable, Equatable {
    case alreadyInitialized
    case invalidUsername
    case invalidPassword
    case invalidCredentials
    case userDisabled
    case userNotFound
    case userExists
    case lastAdminProtected
    case cannotDeleteSelf
    case rateLimited(retryAfterSeconds: Int)
    case biometricUnavailable(String)
    case biometricFailed(String)
    case keychainError(OSStatus)
    case storageError(String)
    case cryptoError(String)

    public var errorDescription: String? {
        switch self {
        case .alreadyInitialized:
            return "系统已完成初始化，无法重复创建初始管理员"
        case .invalidUsername:
            return "用户名必须为 3-32 位字母、数字或 _ . -"
        case .invalidPassword:
            return "密码长度必须在 8 到 128 个字符之间"
        case .invalidCredentials:
            return "用户名或密码错误"
        case .userDisabled:
            return "账号已被禁用，请联系管理员"
        case .userNotFound:
            return "用户不存在"
        case .userExists:
            return "用户名已存在"
        case .lastAdminProtected:
            return "不能禁用、降权或删除最后一个活跃管理员"
        case .cannotDeleteSelf:
            return "不能删除当前登录的管理员账号"
        case .rateLimited(let seconds):
            return "登录失败次数过多，请在 \(max(1, seconds)) 秒后重试"
        case .biometricUnavailable(let detail):
            return "生物识别不可用：\(detail)"
        case .biometricFailed(let detail):
            return "生物识别验证失败：\(detail)"
        case .keychainError(let status):
            return "钥匙串操作失败 (OSStatus=\(status))"
        case .storageError(let detail):
            return "认证存储读写失败：\(detail)"
        case .cryptoError(let detail):
            return "密码学操作失败：\(detail)"
        }
    }
}

// MARK: - Secret Storage Protocol & Keychain Implementation

/// Abstraction over secret storage (implemented by `KeychainStore` in production and `InMemorySecretStore` in tests).
public protocol SecretStoring: Sendable {
    func saveSecret(_ value: String, forKey key: String) throws
    func readSecret(forKey key: String) throws -> String?
    func deleteSecret(forKey key: String) throws
    func deleteAllSecrets(withPrefix prefix: String) throws
}

/// Native iOS Keychain wrapper storing bearer tokens with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
public final class KeychainStore: SecretStoring, Sendable {
    public let service: String

    public init(service: String = "com.laibao.ios.tokens") {
        self.service = service
    }

    /// Namespaced Keychain key scoping each LaiBao account token to its owning local user.
    public static func tokenKey(userID: String, accountName: String) -> String {
        "user:\(userID):account:\(accountName)"
    }

    /// Key prefix matching all LaiBao account tokens owned by `userID`.
    public static func userKeyPrefix(userID: String) -> String {
        "user:\(userID):account:"
    }

    public func saveSecret(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw AuthSecurityError.storageError("无法将令牌编码为 UTF-8")
        }

        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        if addStatus == errSecDuplicateItem {
            let attributesToUpdate: [String: Any] = [
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            let updateStatus = SecItemUpdate(baseQuery as CFDictionary, attributesToUpdate as CFDictionary)
            guard updateStatus == errSecSuccess else {
                throw AuthSecurityError.keychainError(updateStatus)
            }
            return
        }
        throw AuthSecurityError.keychainError(addStatus)
    }

    public func readSecret(forKey key: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw AuthSecurityError.keychainError(status)
        }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            return nil
        }
        return value
    }

    public func deleteSecret(forKey key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound {
            return
        }
        throw AuthSecurityError.keychainError(status)
    }

    public func deleteAllSecrets(withPrefix prefix: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return
        }
        guard status == errSecSuccess else {
            throw AuthSecurityError.keychainError(status)
        }
        guard let items = result as? [[String: Any]] else {
            return
        }
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
               account.hasPrefix(prefix) {
                try deleteSecret(forKey: account)
            }
        }
    }
}

/// Thread-safe in-memory secret store for offline unit tests and SwiftUI previews.
public final class InMemorySecretStore: SecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init() {}

    public func saveSecret(_ value: String, forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage[key] = value
    }

    public func readSecret(forKey key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[key]
    }

    public func deleteSecret(forKey key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func deleteAllSecrets(withPrefix prefix: String) throws {
        lock.lock()
        defer { lock.unlock() }
        let keysToDelete = storage.keys.filter { $0.hasPrefix(prefix) }
        for key in keysToDelete {
            storage.removeValue(forKey: key)
        }
    }
}

// MARK: - PBKDF2-HMAC-SHA256 Password Hasher

/// OWASP-compliant PBKDF2-HMAC-SHA256 password hasher backed by Apple `CommonCrypto` and `Security`.
/// Format matches Go `internal/auth`: `pbkdf2_sha256$210000$<base64url-salt>$<base64url-dk>`.
public enum PasswordHasher {
    public static let iterations: Int = 210_000
    public static let saltLength: Int = 16
    public static let keyLength: Int = 32
    public static let minPasswordLength: Int = 8
    public static let maxPasswordBytes: Int = 128
    public static let scheme: String = "pbkdf2_sha256"

    private static let minAcceptedIterations = 10_000
    private static let maxAcceptedIterations = 5_000_000

    /// Dummy hash used during login when username does not exist to equalize verification timing.
    public static let dummyHash = "pbkdf2_sha256$210000$AAAAAAAAAAAAAAAAAAAAAA$AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

    /// Validates that password length is 8...128 (character count >= 8 and UTF-8 bytes <= 128).
    public static func validatePassword(_ password: String) throws {
        guard password.count >= minPasswordLength, password.utf8.count <= maxPasswordBytes else {
            throw AuthSecurityError.invalidPassword
        }
    }

    /// Generates cryptographically secure random bytes via `SecRandomCopyBytes`.
    public static func randomBytes(count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        guard status == errSecSuccess else {
            throw AuthSecurityError.cryptoError("生成随机字节失败 (OSStatus=\(status))")
        }
        return Data(bytes)
    }

    /// Raw RFC 2898 PBKDF2-HMAC-SHA256 key derivation via `CCKeyDerivationPBKDF`.
    public static func deriveKey(
        password: Data,
        salt: Data,
        iterations: Int,
        keyLength: Int
    ) throws -> Data {
        guard iterations > 0, keyLength > 0, !salt.isEmpty else {
            throw AuthSecurityError.cryptoError("无效的 PBKDF2 参数")
        }
        var derivedBytes = [UInt8](repeating: 0, count: keyLength)
        let status: Int32 = password.withUnsafeBytes { pwRawBuffer in
            let pwPtr = pwRawBuffer.bindMemory(to: Int8.self).baseAddress
            return salt.withUnsafeBytes { saltRawBuffer in
                let saltPtr = saltRawBuffer.bindMemory(to: UInt8.self).baseAddress
                return derivedBytes.withUnsafeMutableBufferPointer { dkBuffer in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr,
                        password.count,
                        saltPtr,
                        salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        dkBuffer.baseAddress,
                        keyLength
                    )
                }
            }
        }
        guard status == Int32(kCCSuccess) else {
            throw AuthSecurityError.cryptoError("PBKDF2 派生失败 (status=\(status))")
        }
        return Data(derivedBytes)
    }

    /// Hashes a plaintext password using PBKDF2-HMAC-SHA256 with a 16-byte random salt and 210,000 iterations.
    public static func hashPassword(_ password: String) throws -> String {
        try validatePassword(password)
        let salt = try randomBytes(count: saltLength)
        let passwordData = Data(password.utf8)
        let dk = try deriveKey(password: passwordData, salt: salt, iterations: iterations, keyLength: keyLength)
        return "\(scheme)$\(iterations)$\(encodeBase64URL(salt))$\(encodeBase64URL(dk))"
    }

    /// Verifies a plaintext password against an encoded PBKDF2-HMAC-SHA256 hash using constant-time comparison.
    public static func verifyPassword(_ password: String, encoded: String) -> Bool {
        guard !password.isEmpty, password.utf8.count <= maxPasswordBytes else {
            return false
        }
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == scheme else {
            return false
        }
        guard let iter = Int(parts[1]),
              iter >= minAcceptedIterations,
              iter <= maxAcceptedIterations else {
            return false
        }
        guard let salt = decodeBase64URL(String(parts[2])), salt.count >= 8 else {
            return false
        }
        guard let expectedDK = decodeBase64URL(String(parts[3])), expectedDK.count >= 16 else {
            return false
        }
        guard let derived = try? deriveKey(
            password: Data(password.utf8),
            salt: salt,
            iterations: iter,
            keyLength: expectedDK.count
        ) else {
            return false
        }
        return constantTimeEqual(derived, expectedDK)
    }

    /// Constant-time byte comparison to prevent timing side-channel leaks.
    public static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private static func encodeBase64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func decodeBase64URL(_ input: String) -> Data? {
        var str = input
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = str.count % 4
        if remainder == 1 {
            return nil
        } else if remainder == 2 {
            str.append("==")
        } else if remainder == 3 {
            str.append("=")
        }
        return Data(base64Encoded: str)
    }
}

// MARK: - Local Multi-User Models

public enum LocalUserRole: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case admin
    case user

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .admin: return "管理员"
        case .user: return "普通用户"
        }
    }
}

/// Complete persisted user record (stored inside protected `auth.json`, NEVER directly exposed to UI views).
public struct LocalUser: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var username: String
    public var displayName: String
    public var role: LocalUserRole
    public var disabled: Bool
    public var passwordHash: String
    public var createdAt: Date
    public var updatedAt: Date
    public var lastLoginAt: Date?

    public init(
        id: String,
        username: String,
        displayName: String,
        role: LocalUserRole,
        disabled: Bool = false,
        passwordHash: String,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        lastLoginAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.role = role
        self.disabled = disabled
        self.passwordHash = passwordHash
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastLoginAt = lastLoginAt
    }

    public func toPublic() -> PublicLocalUser {
        PublicLocalUser(
            id: id,
            username: username,
            displayName: displayName,
            role: role,
            disabled: disabled,
            createdAt: createdAt,
            updatedAt: updatedAt,
            lastLoginAt: lastLoginAt
        )
    }
}

/// Safe public user representation stripped of `passwordHash`.
public struct PublicLocalUser: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var username: String
    public var displayName: String
    public var role: LocalUserRole
    public var disabled: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var lastLoginAt: Date?

    public init(
        id: String,
        username: String,
        displayName: String,
        role: LocalUserRole,
        disabled: Bool,
        createdAt: Date,
        updatedAt: Date,
        lastLoginAt: Date? = nil
    ) {
        self.id = id
        self.username = username
        self.displayName = displayName
        self.role = role
        self.disabled = disabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastLoginAt = lastLoginAt
    }
}

// MARK: - Local Auth Store

/// Thread-safe local multi-user RBAC & PBKDF2 authentication store.
/// Persists atomically to `Application Support/LaiBao/auth.json` with `.completeFileProtection`.
public final class LocalAuthStore: @unchecked Sendable {
    public static let rateLimitMaxFailures: Int = 10
    public static let rateLimitWindowSeconds: TimeInterval = 5 * 60
    private static let maxDisplayNameLength: Int = 64

    private struct AuthFilePayload: Codable {
        var version: Int
        var users: [LocalUser]
    }

    private let lock = NSLock()
    private let rootDirectory: URL
    private let nowProvider: @Sendable () -> Date
    private var usersByID: [String: LocalUser] = [:]
    private var failureBuckets: [String: [Date]] = [:]

    public static func defaultRootDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("LaiBao", isDirectory: true)
    }

    public init(
        rootDirectory: URL? = nil,
        nowProvider: (@Sendable () -> Date)? = nil
    ) throws {
        self.rootDirectory = rootDirectory ?? Self.defaultRootDirectory()
        self.nowProvider = nowProvider ?? { Date() }
        try loadFromDiskLocked()
    }

    public var authFileURL: URL {
        rootDirectory.appendingPathComponent("auth.json", isDirectory: false)
    }

    /// True when no local users exist yet and initial admin setup is required.
    public var needsSetup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return usersByID.isEmpty
    }

    /// Creates the first administrator account. Rejects with `.alreadyInitialized` if any user already exists.
    @discardableResult
    public func setupAdmin(username: String, displayName: String, password: String) throws -> PublicLocalUser {
        let validUsername = try Self.validateUsername(username)
        let cleanDisplay = Self.sanitizeDisplayName(displayName, fallback: validUsername)
        let hash = try PasswordHasher.hashPassword(password)

        lock.lock()
        defer { lock.unlock() }

        guard usersByID.isEmpty else {
            throw AuthSecurityError.alreadyInitialized
        }

        let now = nowProvider()
        let userID = try generateUniqueUserIDLocked()
        let admin = LocalUser(
            id: userID,
            username: validUsername,
            displayName: cleanDisplay,
            role: .admin,
            disabled: false,
            passwordHash: hash,
            createdAt: now,
            updatedAt: now,
            lastLoginAt: now
        )
        usersByID[userID] = admin
        do {
            try saveToDiskLocked()
        } catch {
            usersByID.removeValue(forKey: userID)
            throw error
        }
        return admin.toPublic()
    }

    /// Authenticates a local user by username and password with a 10-failure / 5-minute sliding-window rate limiter
    /// and constant-time dummy-hash verification when the username does not exist.
    public func authenticate(username: String, password: String) throws -> PublicLocalUser {
        let normUser = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // 1. Check rate limit & snapshot target hash under lock.
        let (targetID, targetHash): (String?, String) = try {
            lock.lock()
            defer { lock.unlock() }
            let now = nowProvider()
            if let retryAfter = checkRateLimitLocked(now: now, normUsername: normUser) {
                throw AuthSecurityError.rateLimited(retryAfterSeconds: retryAfter)
            }
            if let found = findUserByUsernameLocked(normLower: normUser) {
                return (found.id, found.passwordHash)
            }
            return (nil, PasswordHasher.dummyHash)
        }()

        // 2. Run expensive PBKDF2 verification outside the lock.
        let passwordMatches = PasswordHasher.verifyPassword(password, encoded: targetHash)

        // 3. Re-acquire lock to update failure counters / lastLoginAt.
        lock.lock()
        defer { lock.unlock() }
        let now = nowProvider()

        guard let targetID, passwordMatches, var user = usersByID[targetID], user.passwordHash == targetHash else {
            recordFailureLocked(now: now, normUsername: normUser)
            throw AuthSecurityError.invalidCredentials
        }
        guard !user.disabled else {
            throw AuthSecurityError.userDisabled
        }

        clearFailuresLocked(normUsername: normUser)
        let previousLastLogin = user.lastLoginAt
        user.lastLoginAt = now
        usersByID[targetID] = user
        do {
            try saveToDiskLocked()
        } catch {
            user.lastLoginAt = previousLastLogin
            usersByID[targetID] = user
            throw error
        }
        return user.toPublic()
    }

    /// Verifies that a user exists and is active before granting Face ID / Touch ID quick unlock.
    @discardableResult
    public func recordBiometricUnlock(userID: String) throws -> PublicLocalUser {
        lock.lock()
        defer { lock.unlock() }
        guard var user = usersByID[userID] else {
            throw AuthSecurityError.userNotFound
        }
        guard !user.disabled else {
            throw AuthSecurityError.userDisabled
        }
        user.lastLoginAt = nowProvider()
        usersByID[userID] = user
        try saveToDiskLocked()
        return user.toPublic()
    }

    /// Verifies `oldPassword` and replaces the user's password with a freshly salted PBKDF2-HMAC-SHA256 hash.
    public func changeOwnPassword(userID: String, oldPassword: String, newPassword: String) throws {
        try PasswordHasher.validatePassword(newPassword)

        let oldHash: String = try {
            lock.lock()
            defer { lock.unlock() }
            guard let user = usersByID[userID] else {
                throw AuthSecurityError.userNotFound
            }
            guard !user.disabled else {
                throw AuthSecurityError.userDisabled
            }
            return user.passwordHash
        }()

        guard PasswordHasher.verifyPassword(oldPassword, encoded: oldHash) else {
            throw AuthSecurityError.invalidCredentials
        }
        let newHash = try PasswordHasher.hashPassword(newPassword)

        lock.lock()
        defer { lock.unlock() }
        guard var user = usersByID[userID] else {
            throw AuthSecurityError.userNotFound
        }
        guard !user.disabled else {
            throw AuthSecurityError.userDisabled
        }
        guard user.passwordHash == oldHash else {
            throw AuthSecurityError.invalidCredentials
        }
        user.passwordHash = newHash
        user.updatedAt = nowProvider()
        usersByID[userID] = user
        try saveToDiskLocked()
    }

    /// Returns all users stripped of password hashes, sorted admins-first then by creation date ascending.
    public func listUsers() -> [PublicLocalUser] {
        lock.lock()
        defer { lock.unlock() }
        return usersByID.values
            .map { $0.toPublic() }
            .sorted { lhs, rhs in
                let adminL = lhs.role == .admin
                let adminR = rhs.role == .admin
                if adminL != adminR { return adminL }
                if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
                if lhs.username != rhs.username { return lhs.username < rhs.username }
                return lhs.id < rhs.id
            }
    }

    public func getUser(id userID: String) -> PublicLocalUser? {
        lock.lock()
        defer { lock.unlock() }
        return usersByID[userID]?.toPublic()
    }

    /// Returns the most recently logged-in active (non-disabled) user, if any.
    /// Useful for displaying biometric quick-unlock on subsequent launches.
    public func mostRecentActiveUser() -> PublicLocalUser? {
        lock.lock()
        defer { lock.unlock() }
        return usersByID.values
            .filter { !$0.disabled }
            .sorted { lhs, rhs in
                let lDate = lhs.lastLoginAt ?? lhs.createdAt
                let rDate = rhs.lastLoginAt ?? rhs.createdAt
                return lDate > rDate
            }
            .first?
            .toPublic()
    }

    /// Creates a new local user (case-insensitive unique username).
    @discardableResult
    public func createUser(
        username: String,
        displayName: String,
        password: String,
        role: LocalUserRole
    ) throws -> PublicLocalUser {
        let validUsername = try Self.validateUsername(username)
        let cleanDisplay = Self.sanitizeDisplayName(displayName, fallback: validUsername)

        // Fast duplicate check before running PBKDF2.
        try {
            lock.lock()
            defer { lock.unlock() }
            if findUserByUsernameLocked(normLower: validUsername.lowercased()) != nil {
                throw AuthSecurityError.userExists
            }
        }()

        let hash = try PasswordHasher.hashPassword(password)

        lock.lock()
        defer { lock.unlock() }
        if findUserByUsernameLocked(normLower: validUsername.lowercased()) != nil {
            throw AuthSecurityError.userExists
        }
        let now = nowProvider()
        let userID = try generateUniqueUserIDLocked()
        let user = LocalUser(
            id: userID,
            username: validUsername,
            displayName: cleanDisplay,
            role: role,
            disabled: false,
            passwordHash: hash,
            createdAt: now,
            updatedAt: now,
            lastLoginAt: nil
        )
        usersByID[userID] = user
        do {
            try saveToDiskLocked()
        } catch {
            usersByID.removeValue(forKey: userID)
            throw error
        }
        return user.toPublic()
    }

    /// Enables or disables a user while protecting the last active admin from lockout.
    @discardableResult
    public func setUserDisabled(userID: String, disabled: Bool) throws -> PublicLocalUser {
        lock.lock()
        defer { lock.unlock() }
        guard var user = usersByID[userID] else {
            throw AuthSecurityError.userNotFound
        }
        if disabled && user.role == .admin && !user.disabled && activeAdminCountLocked() <= 1 {
            throw AuthSecurityError.lastAdminProtected
        }
        user.disabled = disabled
        user.updatedAt = nowProvider()
        usersByID[userID] = user
        try saveToDiskLocked()
        return user.toPublic()
    }

    /// Changes a user's role while preventing demotion of the last active admin.
    @discardableResult
    public func setUserRole(userID: String, role: LocalUserRole) throws -> PublicLocalUser {
        lock.lock()
        defer { lock.unlock() }
        guard var user = usersByID[userID] else {
            throw AuthSecurityError.userNotFound
        }
        if user.role == .admin && role != .admin && !user.disabled && activeAdminCountLocked() <= 1 {
            throw AuthSecurityError.lastAdminProtected
        }
        user.role = role
        user.updatedAt = nowProvider()
        usersByID[userID] = user
        try saveToDiskLocked()
        return user.toPublic()
    }

    /// Resets a target user's password (admin operation).
    @discardableResult
    public func resetUserPassword(userID: String, newPassword: String) throws -> PublicLocalUser {
        let hash = try PasswordHasher.hashPassword(newPassword)
        lock.lock()
        defer { lock.unlock() }
        guard var user = usersByID[userID] else {
            throw AuthSecurityError.userNotFound
        }
        user.passwordHash = hash
        user.updatedAt = nowProvider()
        usersByID[userID] = user
        try saveToDiskLocked()
        return user.toPublic()
    }

    /// Deletes a user; forbids self-deletion and protects the last active admin.
    public func deleteUser(actorID: String, targetUserID: String) throws {
        guard actorID != targetUserID else {
            throw AuthSecurityError.cannotDeleteSelf
        }
        lock.lock()
        defer { lock.unlock() }
        guard let target = usersByID[targetUserID] else {
            throw AuthSecurityError.userNotFound
        }
        if target.role == .admin && !target.disabled && activeAdminCountLocked() <= 1 {
            throw AuthSecurityError.lastAdminProtected
        }
        usersByID.removeValue(forKey: targetUserID)
        try saveToDiskLocked()
    }

    // MARK: - Private Helpers

    private func loadFromDiskLocked() throws {
        let url = authFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            usersByID = [:]
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw AuthSecurityError.storageError("读取 auth.json 失败: \(error.localizedDescription)")
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let payload = try decoder.decode(AuthFilePayload.self, from: data)
            var loaded: [String: LocalUser] = [:]
            for user in payload.users where !user.id.isEmpty {
                loaded[user.id] = user
            }
            usersByID = loaded
        } catch {
            throw AuthSecurityError.storageError("认证文件损坏: \(error.localizedDescription)")
        }
    }

    private func saveToDiskLocked() throws {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        } catch {
            throw AuthSecurityError.storageError("创建认证目录失败: \(error.localizedDescription)")
        }

        let sortedUsers = usersByID.values.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id < rhs.id
        }
        let payload = AuthFilePayload(version: 1, users: sortedUsers)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            let data = try encoder.encode(payload)
            try data.write(to: authFileURL, options: [.atomic, .completeFileProtection])
        } catch {
            throw AuthSecurityError.storageError("写入 auth.json 失败: \(error.localizedDescription)")
        }
    }

    private func activeAdminCountLocked() -> Int {
        usersByID.values.reduce(into: 0) { count, user in
            if user.role == .admin && !user.disabled {
                count += 1
            }
        }
    }

    private func findUserByUsernameLocked(normLower: String) -> LocalUser? {
        guard !normLower.isEmpty else { return nil }
        return usersByID.values.first { $0.username.lowercased() == normLower }
    }

    private func generateUniqueUserIDLocked() throws -> String {
        for _ in 0..<16 {
            let bytes = try PasswordHasher.randomBytes(count: 8)
            let hex = bytes.map { String(format: "%02x", $0) }.joined()
            let candidate = "u_\(hex)"
            if usersByID[candidate] == nil {
                return candidate
            }
        }
        throw AuthSecurityError.cryptoError("无法生成唯一用户 ID")
    }

    private func checkRateLimitLocked(now: Date, normUsername: String) -> Int? {
        guard !normUsername.isEmpty else { return nil }
        let key = "user:\(normUsername)"
        let pruned = pruneTimestamps(failureBuckets[key] ?? [], now: now)
        if pruned.isEmpty {
            failureBuckets.removeValue(forKey: key)
            return nil
        }
        failureBuckets[key] = pruned
        if pruned.count >= Self.rateLimitMaxFailures, let oldest = pruned.first {
            let retry = Int(ceil(oldest.addingTimeInterval(Self.rateLimitWindowSeconds).timeIntervalSince(now)))
            return max(1, retry)
        }
        return nil
    }

    private func recordFailureLocked(now: Date, normUsername: String) {
        if failureBuckets.count > 1024 {
            for (k, list) in failureBuckets {
                let pruned = pruneTimestamps(list, now: now)
                if pruned.isEmpty {
                    failureBuckets.removeValue(forKey: k)
                } else {
                    failureBuckets[k] = pruned
                }
            }
        }
        guard !normUsername.isEmpty else { return }
        let key = "user:\(normUsername)"
        var pruned = pruneTimestamps(failureBuckets[key] ?? [], now: now)
        pruned.append(now)
        failureBuckets[key] = pruned
    }

    private func clearFailuresLocked(normUsername: String) {
        guard !normUsername.isEmpty else { return }
        failureBuckets.removeValue(forKey: "user:\(normUsername)")
    }

    private func pruneTimestamps(_ timestamps: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-Self.rateLimitWindowSeconds)
        return timestamps.filter { $0 > cutoff }
    }

    private static func validateUsername(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 3, trimmed.count <= 32, !trimmed.contains("..") else {
            throw AuthSecurityError.invalidUsername
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-")
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            throw AuthSecurityError.invalidUsername
        }
        return trimmed
    }

    private static func sanitizeDisplayName(_ raw: String, fallback: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return fallback }
        if trimmed.count > maxDisplayNameLength {
            return String(trimmed.prefix(maxDisplayNameLength))
        }
        return trimmed
    }
}

// MARK: - Biometric Authenticator (Face ID / Touch ID)

public enum BiometricAuthenticator {
    public enum BiometryKind: String, Sendable, Equatable {
        case none
        case touchID
        case faceID
        case opticID

        public var displayName: String {
            switch self {
            case .none: return "生物识别"
            case .touchID: return "触控 ID"
            case .faceID: return "面容 ID"
            case .opticID: return "视控 ID"
            }
        }

        public var systemImageName: String {
            switch self {
            case .none: return "lock.shield"
            case .touchID: return "touchid"
            case .faceID: return "faceid"
            case .opticID: return "opticid"
            }
        }
    }

    public static func availableBiometry() -> BiometryKind {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        switch context.biometryType {
        case .faceID: return .faceID
        case .touchID: return .touchID
        case .opticID: return .opticID
        default: return .none
        }
    }

    public static var isAvailable: Bool {
        availableBiometry() != .none
    }

    public static func authenticate(reason: String = "解锁来宝接龙本地密码门禁") async throws -> Bool {
        let context = LAContext()
        context.localizedFallbackTitle = "使用密码"
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &authError) else {
            throw AuthSecurityError.biometricUnavailable(authError?.localizedDescription ?? "设备未启用生物识别")
        }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)
        } catch {
            throw AuthSecurityError.biometricFailed(error.localizedDescription)
        }
    }
}
