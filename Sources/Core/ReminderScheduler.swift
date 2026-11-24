import BackgroundTasks
import Foundation
import UserNotifications

/// Errors thrown while validating or scheduling local reminder plans.
public enum ReminderScheduleError: LocalizedError, Sendable, Equatable {
    case emptyClocks
    case invalidClock(String)
    case invalidWeekday(Int)
    case invalidWeekdayExpression(String)
    case noUpcomingTrigger

    public var errorDescription: String? {
        switch self {
        case .emptyClocks:
            return "至少需要一个 HH:mm 时间点"
        case .invalidClock(let raw):
            return "时间格式应为 HH:mm（00:00-23:59）: \(raw)"
        case .invalidWeekday(let day):
            return "星期数字必须在 1（周一）到 7（周日）之间: \(day)"
        case .invalidWeekdayExpression(let raw):
            return "无法解析星期表达式: \(raw)"
        case .noUpcomingTrigger:
            return "未来 8 天内未找到符合条件的提醒时间"
        }
    }
}

/// Local wall-clock time (`hour`, `minute`) for DST-safe reminder scheduling.
public struct ReminderClock: Hashable, Codable, Sendable, Comparable {
    public let hour: Int
    public let minute: Int

    public init(hour: Int, minute: Int) {
        self.hour = hour
        self.minute = minute
    }

    public var formatted: String {
        String(format: "%02d:%02d", hour, minute)
    }

    public static func < (lhs: ReminderClock, rhs: ReminderClock) -> Bool {
        if lhs.hour != rhs.hour { return lhs.hour < rhs.hour }
        return lhs.minute < rhs.minute
    }
}

/// Validates reminder clocks/weekdays, calculates DST-safe next trigger times, syncs `UNUserNotificationCenter`
/// calendar triggers with deep-link `userInfo`, and schedules optional `BGAppRefreshTask` refreshes.
public enum ReminderScheduler {
    public static let backgroundRefreshTaskIdentifier = "com.laibao.ios.reminder.refresh"
    public static let notificationCategoryIdentifier = "com.laibao.ios.reminder.checkin"

    // MARK: - Clock & Weekday Validation

    /// Parses a single `"HH:mm"` wall-clock string (`hour` in `0...23`, `minute` in `0...59` with 2-digit minute).
    public static func parseClock(_ raw: String) throws -> ReminderClock {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              !parts[0].isEmpty,
              parts[0].count <= 2,
              parts[1].count == 2,
              let hh = Int(parts[0]),
              let mm = Int(parts[1]),
              (0...23).contains(hh),
              (0...59).contains(mm) else {
            throw ReminderScheduleError.invalidClock(raw)
        }
        return ReminderClock(hour: hh, minute: mm)
    }

    /// Parses a comma-separated list of `"HH:mm"` clocks (e.g., `"08:45,18:05"`), deduplicating while preserving order.
    public static func parseClockList(_ raw: String) throws -> [ReminderClock] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ReminderScheduleError.emptyClocks
        }
        let items = trimmed.split(separator: ",", omittingEmptySubsequences: false).map { String($0) }
        return try validateClocks(items)
    }

    /// Validates an array of `"HH:mm"` clock strings, returning deduplicated `ReminderClock` values.
    public static func validateClocks(_ clocks: [String]) throws -> [ReminderClock] {
        guard !clocks.isEmpty else {
            throw ReminderScheduleError.emptyClocks
        }
        var seen = Set<ReminderClock>()
        var result: [ReminderClock] = []
        for raw in clocks {
            let parsed = try parseClock(raw)
            if seen.insert(parsed).inserted {
                result.append(parsed)
            }
        }
        guard !result.isEmpty else {
            throw ReminderScheduleError.emptyClocks
        }
        return result
    }

    /// Validates ISO weekday numbers (`1` = Monday ... `7` = Sunday). An empty array means every day.
    public static func validateWeekdays(_ weekdays: [Int]) throws -> Set<Int> {
        var set = Set<Int>()
        for day in weekdays {
            guard (1...7).contains(day) else {
                throw ReminderScheduleError.invalidWeekday(day)
            }
            set.insert(day)
        }
        return set
    }

    /// Parses weekday expressions like `"1-5"`, `"1,3,5"`, `"mon-fri"`, `"一,三,五"` into sorted ISO `1...7` numbers.
    public static func parseWeekdaysExpression(_ raw: String) throws -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let nameMap: [String: Int] = [
            "mon": 1, "tue": 2, "wed": 3, "thu": 4, "fri": 5, "sat": 6, "sun": 7,
            "一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "日": 7, "天": 7
        ]

        func parseOne(_ token: String) -> Int? {
            let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
            if let mapped = nameMap[clean] { return mapped }
            if let num = Int(clean), (1...7).contains(num) { return num }
            return nil
        }

        var result = Set<Int>()
        for segment in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let part = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else {
                throw ReminderScheduleError.invalidWeekdayExpression(raw)
            }
            if part.contains("-") {
                let bounds = part.split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2,
                      let start = parseOne(String(bounds[0])),
                      let end = parseOne(String(bounds[1])) else {
                    throw ReminderScheduleError.invalidWeekdayExpression(part)
                }
                var cur = start
                while true {
                    result.insert(cur)
                    if cur == end { break }
                    cur = (cur % 7) + 1
                }
            } else {
                guard let single = parseOne(part) else {
                    throw ReminderScheduleError.invalidWeekdayExpression(part)
                }
                result.insert(single)
            }
        }
        guard !result.isEmpty else {
            throw ReminderScheduleError.invalidWeekdayExpression(raw)
        }
        return result.sorted()
    }

    /// Converts ISO weekday (`1` = Mon ... `7` = Sun) to Apple `Calendar` weekday (`1` = Sun, `2` = Mon ... `7` = Sat).
    public static func isoWeekdayToAppleWeekday(_ isoWeekday: Int) -> Int {
        isoWeekday == 7 ? 1 : (isoWeekday + 1)
    }

    /// Converts Apple `Calendar` weekday (`1` = Sun, `2` = Mon ... `7` = Sat) to ISO weekday (`1` = Mon ... `7` = Sun).
    public static func appleWeekdayToISOWeekday(_ appleWeekday: Int) -> Int {
        appleWeekday == 1 ? 7 : (appleWeekday - 1)
    }

    // MARK: - DST-Safe Next Trigger Calculation

    /// Computes the next local wall-clock trigger `Date` strictly after `now`, using explicit
    /// `(year, month, day, hour, minute)` calendar components to remain immune to ±1h DST shifts.
    public static func nextTriggerDate(
        from now: Date = Date(),
        clocks: [String],
        weekdays: [Int],
        calendar: Calendar = .current
    ) throws -> Date {
        let parsedClocks = try validateClocks(clocks)
        let allowedISOWeekdays = try validateWeekdays(weekdays)

        var best: Date?
        for dayOffset in 0..<8 {
            guard let targetDay = calendar.date(byAdding: .day, value: dayOffset, to: now) else {
                continue
            }
            let ymd = calendar.dateComponents([.year, .month, .day], from: targetDay)
            for clock in parsedClocks {
                var comps = DateComponents()
                comps.year = ymd.year
                comps.month = ymd.month
                comps.day = ymd.day
                comps.hour = clock.hour
                comps.minute = clock.minute
                comps.second = 0

                guard let candidate = calendar.date(from: comps), candidate > now else {
                    continue
                }
                if !allowedISOWeekdays.isEmpty {
                    let appleWD = calendar.component(.weekday, from: candidate)
                    let isoWD = appleWeekdayToISOWeekday(appleWD)
                    guard allowedISOWeekdays.contains(isoWD) else {
                        continue
                    }
                }
                if best == nil || candidate < best! {
                    best = candidate
                }
            }
            if let best {
                return best
            }
        }
        throw ReminderScheduleError.noUpcomingTrigger
    }

    // MARK: - UNUserNotificationCenter Synchronization

    public static func notificationIdentifierPrefix(userID: String, planID: String? = nil) -> String {
        if let planID, !planID.isEmpty {
            return "laibao.reminder.\(userID).\(planID)."
        }
        return "laibao.reminder.\(userID)."
    }

    /// Pure builder for `UNNotificationRequest` objects corresponding to a single `ReminderPlan`.
    /// Attaches `userInfo: ["formID": ..., "planID": ..., "userID": ...]` for deep-link handling on tap.
    public static func buildNotificationRequests(
        for plan: ReminderPlan,
        userID: String
    ) throws -> [UNNotificationRequest] {
        guard plan.enabled else { return [] }
        let parsedClocks = try validateClocks(plan.clocks)
        let allowedISOWeekdays = try validateWeekdays(plan.weekdays).sorted()

        let baseTitle = plan.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayTitle = baseTitle.isEmpty ? "来宝接龙打卡提醒" : baseTitle
        let body = "表单 \(plan.formID) 打卡时间已到，轻点立即进入一键填报。"

        var requests: [UNNotificationRequest] = []
        let prefix = notificationIdentifierPrefix(userID: userID, planID: plan.id)

        if allowedISOWeekdays.isEmpty {
            for clock in parsedClocks {
                let content = UNMutableNotificationContent()
                content.title = displayTitle
                content.body = body
                content.sound = .default
                content.categoryIdentifier = notificationCategoryIdentifier
                content.userInfo = [
                    "formID": plan.formID,
                    "planID": plan.id,
                    "userID": userID
                ]

                var components = DateComponents()
                components.hour = clock.hour
                components.minute = clock.minute

                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                let id = "\(prefix)daily.\(clock.hour)_\(clock.minute)"
                requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            }
        } else {
            for isoDay in allowedISOWeekdays {
                let appleWD = isoWeekdayToAppleWeekday(isoDay)
                for clock in parsedClocks {
                    let content = UNMutableNotificationContent()
                    content.title = displayTitle
                    content.body = body
                    content.sound = .default
                    content.categoryIdentifier = notificationCategoryIdentifier
                    content.userInfo = [
                        "formID": plan.formID,
                        "planID": plan.id,
                        "userID": userID
                    ]

                    var components = DateComponents()
                    components.weekday = appleWD
                    components.hour = clock.hour
                    components.minute = clock.minute

                    let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                    let id = "\(prefix)wd\(isoDay).\(clock.hour)_\(clock.minute)"
                    requests.append(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
                }
            }
        }
        return requests
    }

    public static func requestNotificationAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])
    }

    public static func notificationAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        return settings.authorizationStatus
    }

    /// Replaces all pending local notifications owned by `userID` with the current enabled `plans`.
    public static func syncNotifications(for plans: [ReminderPlan], userID: String) async throws {
        let center = UNUserNotificationCenter.current()
        let userPrefix = notificationIdentifierPrefix(userID: userID)
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending.map(\.identifier).filter { $0.hasPrefix(userPrefix) }
        if !toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toRemove)
        }

        for plan in plans where plan.enabled {
            let requests = try buildNotificationRequests(for: plan, userID: userID)
            for request in requests {
                try await center.add(request)
            }
        }
    }

    /// Cancels all pending local notifications owned by `userID`.
    public static func removeNotifications(for userID: String) async {
        let center = UNUserNotificationCenter.current()
        let userPrefix = notificationIdentifierPrefix(userID: userID)
        let pending = await center.pendingNotificationRequests()
        let toRemove = pending.map(\.identifier).filter { $0.hasPrefix(userPrefix) }
        if !toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: toRemove)
        }
    }

    // MARK: - Background App Refresh

    /// Submits an optional `BGAppRefreshTaskRequest` for `com.laibao.ios.reminder.refresh`.
    public static func scheduleBackgroundRefresh(earliestBeginDate: Date? = nil) throws {
        let request = BGAppRefreshTaskRequest(identifier: backgroundRefreshTaskIdentifier)
        request.earliestBeginDate = earliestBeginDate ?? Date(timeIntervalSinceNow: 15 * 60)
        try BGTaskScheduler.shared.submit(request)
    }
}
