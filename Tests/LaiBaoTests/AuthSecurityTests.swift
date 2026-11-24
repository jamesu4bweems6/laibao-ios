import Foundation
import XCTest
@testable import LaiBao

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ start: Date) {
        self.current = start
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(interval)
    }
}

final class AuthSecurityTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laibao-ios-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testPBKDF2SHA256RFC6070Vectors() throws {
        let vectors: [(password: String, salt: String, iter: Int, dkLen: Int, expectedHex: String)] = [
            ("password", "salt", 1, 32, "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b"),
            ("password", "salt", 2, 32, "ae4d0c95af6b46d32d0adff928f06dd02a303f8ef3c251dfd6e2d85a95474c43"),
            ("password", "salt", 4096, 32, "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"),
            ("passwordPASSWORDpassword", "saltSALTsaltSALTsaltSALTsaltSALTsalt", 4096, 40, "348c89dbcbd32b2f32d814b8116e84cf2b17347ebc1800181c4e2a1fb8dd53e1c635518c7dac47e9")
        ]

        for vec in vectors {
            let dk = try PasswordHasher.deriveKey(
                password: Data(vec.password.utf8),
                salt: Data(vec.salt.utf8),
                iterations: vec.iter,
                keyLength: vec.dkLen
            )
            let hex = dk.map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(hex, vec.expectedHex)
        }
    }

    func testPasswordHashAndVerify() throws {
        XCTAssertThrowsError(try PasswordHasher.hashPassword("short7!")) { err in
            XCTAssertEqual(err as? AuthSecurityError, .invalidPassword)
        }
        XCTAssertThrowsError(try PasswordHasher.hashPassword(String(repeating: "a", count: 129))) { err in
            XCTAssertEqual(err as? AuthSecurityError, .invalidPassword)
        }

        let h1 = try PasswordHasher.hashPassword("ValidPass123!")
        let h2 = try PasswordHasher.hashPassword("ValidPass123!")
        XCTAssertTrue(h1.hasPrefix("pbkdf2_sha256$210000$"))
        XCTAssertNotEqual(h1, h2, "Each call must use a fresh random salt")
        XCTAssertTrue(PasswordHasher.verifyPassword("ValidPass123!", encoded: h1))
        XCTAssertFalse(PasswordHasher.verifyPassword("WrongPass123!", encoded: h1))

        for bad in ["", "plain", "pbkdf2_sha256$10$aa$bb", "sha256$210000$aa$bb", "pbkdf2_sha256$210000$!!!$!!!"] {
            XCTAssertFalse(PasswordHasher.verifyPassword("ValidPass123!", encoded: bad))
        }

        XCTAssertTrue(PasswordHasher.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 3])))
        XCTAssertFalse(PasswordHasher.constantTimeEqual(Data([1, 2, 3]), Data([1, 2, 4])))
        XCTAssertFalse(PasswordHasher.constantTimeEqual(Data([1, 2]), Data([1, 2, 3])))
    }

    func testBruteForceRateLimitAndSlidingWindowRecovery() throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_763_900_000))
        let store = try LocalAuthStore(rootDirectory: dir, nowProvider: { clock.now() })

        XCTAssertTrue(store.needsSetup)
        let admin = try store.setupAdmin(username: "AdminOne", displayName: "管理员", password: "CorrectPass#1")
        XCTAssertFalse(store.needsSetup)
        XCTAssertEqual(admin.role, .admin)
        XCTAssertTrue(admin.id.hasPrefix("u_"))

        // Double setup must fail.
        XCTAssertThrowsError(try store.setupAdmin(username: "admin2", displayName: "Second", password: "CorrectPass#1")) { err in
            XCTAssertEqual(err as? AuthSecurityError, .alreadyInitialized)
        }

        // PublicLocalUser JSON must never leak passwordHash.
        let encodedPublic = try JSONEncoder().encode(admin)
        let publicText = String(data: encodedPublic, encoding: .utf8) ?? ""
        XCTAssertFalse(publicText.contains("passwordHash"))
        XCTAssertFalse(publicText.contains("pbkdf2_sha256"))

        // 10 consecutive failures -> 11th must hit rateLimited even with correct password.
        for _ in 0..<LocalAuthStore.rateLimitMaxFailures {
            XCTAssertThrowsError(try store.authenticate(username: "adminone", password: "WrongPass#1")) { err in
                XCTAssertEqual(err as? AuthSecurityError, .invalidCredentials)
            }
        }
        XCTAssertThrowsError(try store.authenticate(username: "adminone", password: "CorrectPass#1")) { err in
            guard case AuthSecurityError.rateLimited(let seconds) = err else {
                XCTFail("Expected rateLimited, got \(err)")
                return
            }
            XCTAssertGreaterThan(seconds, 0)
        }

        // Advance clock past 5-minute sliding window -> login succeeds.
        clock.advance(by: LocalAuthStore.rateLimitWindowSeconds + 2)
        let authed = try store.authenticate(username: "ADMINONE", password: "CorrectPass#1")
        XCTAssertEqual(authed.id, admin.id)
    }

    func testLastAdminProtectionSelfDeleteAndRBAC() throws {
        let dir = try makeTempDirectory()
        let clock = MutableClock(Date(timeIntervalSince1970: 1_763_900_000))
        let store = try LocalAuthStore(rootDirectory: dir, nowProvider: { clock.now() })

        let admin1 = try store.setupAdmin(username: "admin1", displayName: "主管理员", password: "Admin1Pass!")

        // Sole active admin cannot be disabled, demoted, or deleted.
        XCTAssertThrowsError(try store.setUserDisabled(userID: admin1.id, disabled: true)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .lastAdminProtected)
        }
        XCTAssertThrowsError(try store.setUserRole(userID: admin1.id, role: .user)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .lastAdminProtected)
        }
        XCTAssertThrowsError(try store.deleteUser(actorID: admin1.id, targetUserID: admin1.id)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .cannotDeleteSelf)
        }

        clock.advance(by: 60)
        let alice = try store.createUser(username: "Alice", displayName: "爱丽丝", password: "AlicePass#1", role: .user)
        XCTAssertThrowsError(try store.createUser(username: "alice", displayName: "Dup", password: "AlicePass#1", role: .user)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .userExists)
        }
        XCTAssertThrowsError(try store.deleteUser(actorID: alice.id, targetUserID: admin1.id)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .lastAdminProtected)
        }

        // Password change & admin reset.
        try store.changeOwnPassword(userID: alice.id, oldPassword: "AlicePass#1", newPassword: "AlicePass#2")
        _ = try store.authenticate(username: "alice", password: "AlicePass#2")

        _ = try store.resetUserPassword(userID: alice.id, newPassword: "AlicePass#3")
        _ = try store.authenticate(username: "alice", password: "AlicePass#3")

        // Disable blocks login.
        _ = try store.setUserDisabled(userID: alice.id, disabled: true)
        XCTAssertThrowsError(try store.authenticate(username: "alice", password: "AlicePass#3")) { err in
            XCTAssertEqual(err as? AuthSecurityError, .userDisabled)
        }

        // Second admin allows demoting admin1, then protects admin2.
        clock.advance(by: 60)
        let admin2 = try store.createUser(username: "admin2", displayName: "副管理员", password: "Admin2Pass!", role: .admin)
        _ = try store.setUserRole(userID: admin1.id, role: .user)
        XCTAssertThrowsError(try store.setUserRole(userID: admin2.id, role: .user)) { err in
            XCTAssertEqual(err as? AuthSecurityError, .lastAdminProtected)
        }

        // Delete alice persists across reload.
        try store.deleteUser(actorID: admin2.id, targetUserID: alice.id)
        let reloaded = try LocalAuthStore(rootDirectory: dir)
        XCTAssertNil(reloaded.getUser(id: alice.id))
        XCTAssertEqual(reloaded.listUsers().count, 2)
    }

    func testPerUserWorkspaceIsolationKeychainTokensAndDeletion() throws {
        let dir = try makeTempDirectory()
        let secrets = InMemorySecretStore()
        let workspace = UserWorkspaceStore(rootDirectory: dir, secretStore: secrets)

        let secretTokenA = "eyJ_SUPER_SECRET_USER_A_TOKEN_987654321"
        let secretTokenB = "eyJ_SUPER_SECRET_USER_B_TOKEN_123456789"

        _ = try workspace.upsertAccount(
            LaiBaoAccount(name: "main", note: "A主号"),
            token: "Bearer \(secretTokenA)",
            setActive: true,
            for: "u_alice"
        )
        _ = try workspace.upsertAccount(
            LaiBaoAccount(name: "main", note: "B主号"),
            token: secretTokenB,
            setActive: true,
            for: "u_bob"
        )

        // Verify strict token isolation and zero plaintext tokens written to accounts.json on disk.
        XCTAssertEqual(try workspace.readToken(accountName: "main", for: "u_alice"), secretTokenA)
        XCTAssertEqual(try workspace.readToken(accountName: "main", for: "u_bob"), secretTokenB)

        let aliceAccountsURL = try workspace.userDirectory(for: "u_alice").appendingPathComponent("accounts.json")
        let onDiskJSON = try String(contentsOf: aliceAccountsURL, encoding: .utf8)
        XCTAssertFalse(onDiskJSON.contains(secretTokenA), "SECURITY VIOLATION: raw bearer token persisted to JSON file!")
        XCTAssertFalse(onDiskJSON.contains(secretTokenB))

        // Verify POI & log isolation + log token redaction.
        try workspace.upsertPOI(POIItem(id: "p1", lat: 39.9, lng: 116.4, addr: "北京", title: "A点"), for: "u_alice")
        XCTAssertEqual(try workspace.loadPOIs(for: "u_alice").count, 1)
        XCTAssertEqual(try workspace.loadPOIs(for: "u_bob").count, 0)

        try workspace.appendRunLog(
            CheckinRunLog(formID: "f1", success: false, message: "failed with Bearer \(secretTokenA)"),
            for: "u_alice"
        )
        let logsA = try workspace.loadRunLogs(for: "u_alice")
        XCTAssertEqual(logsA.count, 1)
        XCTAssertFalse(logsA[0].message.contains(secretTokenA))
        XCTAssertTrue(logsA[0].message.contains("[REDACTED]"))

        // Reject traversal in userID.
        XCTAssertThrowsError(try workspace.userDirectory(for: "../escape"))

        // Deleting u_alice removes u_alice directory and secrets while keeping u_bob completely intact.
        try workspace.deleteUserData(userID: "u_alice")
        XCTAssertNil(try workspace.readToken(accountName: "main", for: "u_alice"))
        XCTAssertEqual(try workspace.readToken(accountName: "main", for: "u_bob"), secretTokenB)
        XCTAssertEqual(try workspace.loadAccounts(for: "u_alice").count, 0)
        XCTAssertEqual(try workspace.loadAccounts(for: "u_bob").count, 1)
    }

    func testReminderSchedulerNextTriggerNotificationsAndQRRenderer() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        // 2026-11-23 is Monday (ISO weekday 1).
        let mondayMorning = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 9, minute: 0))!
        let next = try ReminderScheduler.nextTriggerDate(
            from: mondayMorning,
            clocks: ["08:45", "18:05"],
            weekdays: [1, 3, 5],
            calendar: cal
        )
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: next)
        XCTAssertEqual(comps.day, 23)
        XCTAssertEqual(comps.hour, 18)
        XCTAssertEqual(comps.minute, 5)

        XCTAssertEqual(try ReminderScheduler.parseWeekdaysExpression("1-5"), [1, 2, 3, 4, 5])
        XCTAssertEqual(try ReminderScheduler.parseWeekdaysExpression("一,三,五"), [1, 3, 5])

        let plan = ReminderPlan(
            id: "plan-1",
            name: "晨检打卡",
            formID: "1911520788713021441",
            enabled: true,
            clocks: ["08:45"],
            weekdays: [1, 5]
        )
        let requests = try ReminderScheduler.buildNotificationRequests(for: plan, userID: "u_test")
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].content.userInfo["formID"] as? String, "1911520788713021441")
        XCTAssertEqual(requests[0].content.userInfo["planID"] as? String, "plan-1")
        XCTAssertEqual(requests[0].content.userInfo["userID"] as? String, "u_test")

        let png = QRCodeRenderer.renderPNGData(from: "http://weixin.qq.com/q/test", size: 256)
        XCTAssertNotNil(png)
        if let png {
            XCTAssertGreaterThan(png.count, 16)
            XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }
}
