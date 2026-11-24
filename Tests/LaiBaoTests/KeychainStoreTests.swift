import Foundation
import XCTest
@testable import LaiBao

final class KeychainStoreTests: XCTestCase {
    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("laibao-ios-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    func testInMemorySecretStoreCRUDAndPrefixDeletion() throws {
        let store = InMemorySecretStore()
        let keyA = KeychainStore.tokenKey(accountName: "main")
        let keyB = KeychainStore.tokenKey(accountName: "work")
        let otherKey = "other:key"

        XCTAssertEqual(keyA, "account:main")
        XCTAssertNil(try store.readSecret(forKey: keyA))

        try store.saveSecret("tok-v1", forKey: keyA)
        XCTAssertEqual(try store.readSecret(forKey: keyA), "tok-v1")

        // Overwrite existing secret.
        try store.saveSecret("tok-v2", forKey: keyA)
        XCTAssertEqual(try store.readSecret(forKey: keyA), "tok-v2")

        try store.saveSecret("tok-work", forKey: keyB)
        try store.saveSecret("keep-me", forKey: otherKey)

        // Delete single secret (idempotent).
        try store.deleteSecret(forKey: keyA)
        try store.deleteSecret(forKey: keyA)
        XCTAssertNil(try store.readSecret(forKey: keyA))
        XCTAssertEqual(try store.readSecret(forKey: keyB), "tok-work")

        // Prefix deletion only clears matching prefix.
        try store.deleteAllSecrets(withPrefix: KeychainStore.tokenKeyPrefix)
        XCTAssertNil(try store.readSecret(forKey: keyB))
        XCTAssertEqual(try store.readSecret(forKey: otherKey), "keep-me")
    }

    func testWorkspaceStoreAccountsKeychainTokensAndSettings() async throws {
        let dir = try makeTempDirectory()
        let secrets = InMemorySecretStore()
        let workspace = UserWorkspaceStore(rootDirectory: dir, secretStore: secrets)

        let secretTokenA = "eyJ_SUPER_SECRET_MAIN_TOKEN_987654321"
        let secretTokenB = "eyJ_SUPER_SECRET_ALT_TOKEN_123456789"

        let savedMain = try workspace.upsertAccount(
            LaiBaoAccount(name: "main", note: "主账号"),
            token: "Bearer \(secretTokenA)",
            setActive: true
        )
        XCTAssertTrue(savedMain.hasToken)
        XCTAssertFalse(savedMain.tokenMask.isEmpty)
        XCTAssertFalse(savedMain.tokenMask.contains(secretTokenA))

        _ = try workspace.upsertAccount(
            LaiBaoAccount(name: "alt", note: "备用账号"),
            token: secretTokenB,
            setActive: false
        )

        // Verify Keychain retrieval and zero plaintext token leakage on disk.
        XCTAssertEqual(try workspace.readToken(accountName: "main"), secretTokenA)
        XCTAssertEqual(try workspace.readToken(accountName: "alt"), secretTokenB)

        let accountsURL = workspace.workspaceDirectory.appendingPathComponent("accounts.json")
        let onDiskJSON = try String(contentsOf: accountsURL, encoding: .utf8)
        XCTAssertFalse(onDiskJSON.contains(secretTokenA), "SECURITY VIOLATION: raw bearer token persisted to JSON file!")
        XCTAssertFalse(onDiskJSON.contains(secretTokenB), "SECURITY VIOLATION: raw bearer token persisted to JSON file!")

        // Active account switching & settings persistence.
        XCTAssertEqual(try workspace.loadSettings().activeAccount, "main")
        try workspace.setActiveAccount("alt")
        XCTAssertEqual(try workspace.loadSettings().activeAccount, "alt")

        var settings = try workspace.loadSettings()
        settings.ver = "2.5.0"
        settings.mpAppID = "wx_custom_mp"
        try workspace.saveSettings(settings)
        let reloadedSettings = try workspace.loadSettings()
        XCTAssertEqual(reloadedSettings.ver, "2.5.0")
        XCTAssertEqual(reloadedSettings.mpAppID, "wx_custom_mp")

        let client = try workspace.makeAPIClient()
        let hasTok = await client.hasToken()
        let masked = await client.maskedToken()
        XCTAssertTrue(hasTok)
        XCTAssertEqual(masked, LaiBaoAPIClient.maskToken(secretTokenB))
        XCTAssertEqual(client.ver, "2.5.0")

        // Reject invalid account identifiers / path traversal.
        XCTAssertThrowsError(try UserWorkspaceStore.sanitizeID("../escape"))
        XCTAssertThrowsError(try UserWorkspaceStore.sanitizeID("bad/name"))
        XCTAssertThrowsError(try UserWorkspaceStore.sanitizeID("   "))

        // Deleting active account removes its Keychain token and falls back to remaining account.
        try workspace.deleteAccount(name: "alt")
        XCTAssertNil(try workspace.readToken(accountName: "alt"))
        XCTAssertEqual(try workspace.readToken(accountName: "main"), secretTokenA)
        XCTAssertEqual(try workspace.loadAccounts().map(\.name), ["main"])
        XCTAssertEqual(try workspace.loadSettings().activeAccount, "main")
    }

    func testWorkspaceStorePOIsRemindersAndSanitizedRunLogs() throws {
        let dir = try makeTempDirectory()
        let workspace = UserWorkspaceStore(rootDirectory: dir, secretStore: InMemorySecretStore())

        // POIs CRUD & coordinate validation.
        let poi1 = POIItem(id: "p1", lat: 39.908823, lng: 116.397470, addr: "北京天安门", title: "办公点")
        let afterAdd = try workspace.upsertPOI(poi1)
        XCTAssertEqual(afterAdd.count, 1)
        XCTAssertEqual(try workspace.loadPOIs(), [poi1])

        let invalidPOI = POIItem(id: "bad", lat: 120.0, lng: 200.0, addr: "无效", title: "无效")
        XCTAssertThrowsError(try workspace.upsertPOI(invalidPOI))

        let afterDel = try workspace.deletePOI(id: "p1")
        XCTAssertTrue(afterDel.isEmpty)

        // Reminders CRUD.
        let plan = ReminderPlan(
            id: "plan-1",
            name: "晨检打卡",
            accountName: "main",
            formID: "1911520788713021441",
            enabled: true,
            clocks: ["08:45", "18:05"],
            weekdays: [1, 3, 5]
        )
        _ = try workspace.upsertReminder(plan)
        XCTAssertEqual(try workspace.loadReminders(), [plan])
        _ = try workspace.deleteReminder(id: "plan-1")
        XCTAssertTrue(try workspace.loadReminders().isEmpty)

        // Run logs persistence, plan filtering, and Bearer/Authorization redaction.
        let rawSecret = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9_SECRET"
        try workspace.appendRunLog(
            CheckinRunLog(planID: "plan-1", formID: "f1", success: false, message: "failed with Bearer \(rawSecret)")
        )
        try workspace.appendRunLog(
            CheckinRunLog(planID: "plan-2", formID: "f2", success: true, message: "Authorization: \(rawSecret) ok")
        )

        let allLogs = try workspace.loadRunLogs()
        XCTAssertEqual(allLogs.count, 2)
        for log in allLogs {
            XCTAssertFalse(log.message.contains(rawSecret))
            XCTAssertTrue(log.message.contains("[REDACTED]"))
        }
        XCTAssertEqual(try workspace.loadRunLogs(planID: "plan-1").count, 1)

        try workspace.clearRunLogs()
        XCTAssertTrue(try workspace.loadRunLogs().isEmpty)
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
        let requests = try ReminderScheduler.buildNotificationRequests(for: plan)
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0].content.userInfo["formID"] as? String, "1911520788713021441")
        XCTAssertEqual(requests[0].content.userInfo["planID"] as? String, "plan-1")
        let infoKeys = Set(requests[0].content.userInfo.keys.compactMap { $0 as? String })
        XCTAssertEqual(infoKeys, ["formID", "planID"])
        XCTAssertTrue(requests[0].identifier.hasPrefix("laibao.reminder.plan-1."))

        let png = QRCodeRenderer.renderPNGData(from: "http://weixin.qq.com/q/test", size: 256)
        XCTAssertNotNil(png)
        if let png {
            XCTAssertGreaterThan(png.count, 16)
            XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        }
    }
}
