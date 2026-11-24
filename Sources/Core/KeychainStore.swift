import Foundation
import Security

// MARK: - Keychain Errors

/// Errors raised during iOS Keychain secret storage operations.
public enum KeychainError: LocalizedError, Sendable, Equatable {
    case encodingFailed
    case osStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .encodingFailed:
            return "无法将令牌编码为 UTF-8 数据"
        case .osStatus(let status):
            return "钥匙串操作失败 (OSStatus=\(status))"
        }
    }
}

// MARK: - Secret Storage Protocol & Keychain Implementation

/// Abstraction over secret storage (implemented by `KeychainStore` in production
/// and `InMemorySecretStore` in unit tests and SwiftUI previews).
public protocol SecretStoring: Sendable {
    func saveSecret(_ value: String, forKey key: String) throws
    func readSecret(forKey key: String) throws -> String?
    func deleteSecret(forKey key: String) throws
    func deleteAllSecrets(withPrefix prefix: String) throws
}

/// Native iOS Keychain wrapper storing LaiBao bearer tokens with
/// `kSecClassGenericPassword` and `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`.
public final class KeychainStore: SecretStoring, Sendable {
    public static let defaultService: String = "com.laibao.ios.tokens"
    public static let tokenKeyPrefix: String = "account:"

    public let service: String

    public init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    /// Namespaced Keychain key for a single-user LaiBao account token.
    public static func tokenKey(accountName: String) -> String {
        "\(tokenKeyPrefix)\(accountName)"
    }

    public func saveSecret(_ value: String, forKey key: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw KeychainError.encodingFailed
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
                throw KeychainError.osStatus(updateStatus)
            }
            return
        }
        throw KeychainError.osStatus(addStatus)
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
            throw KeychainError.osStatus(status)
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
        throw KeychainError.osStatus(status)
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
            throw KeychainError.osStatus(status)
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
