import Foundation

// MARK: - API & Client Errors

/// Server-side HTTP or business error returned by `form.qun100.com`.
public struct APIError: LocalizedError, Sendable, Equatable {
    public let status: Int
    public let code: Int
    public let message: String

    public init(status: Int = 0, code: Int = 0, message: String) {
        self.status = status
        self.code = code
        self.message = message
    }

    /// True when the session token is invalid or expired (HTTP 401, code `13552`, or code `13686`).
    public var isSessionExpired: Bool {
        status == 401 || code == 13552 || code == 13686
    }

    /// True when the server returned code `13362` ("暂无提交记录").
    public var isNoRecords: Bool {
        code == 13362
    }

    /// True when fallback endpoints should be short-circuited immediately.
    public var isFatalFormError: Bool {
        isSessionExpired || status == 403 || code == 13351 || code == 13408
    }

    public var errorDescription: String? {
        let resolved: String
        if !message.isEmpty {
            resolved = message
        } else if let described = Self.describeCode(code) {
            resolved = described
        } else if status > 0 {
            resolved = HTTPURLResponse.localizedString(forStatusCode: status)
        } else {
            resolved = "未知服务端错误"
        }

        if isSessionExpired {
            return "会话超时，请重新登录 (http=\(status) code=\(code))"
        }
        if code != 0 {
            return "接口错误 \(code): \(resolved)"
        }
        return "请求失败 (HTTP \(status)): \(resolved)"
    }

    /// Translates LaiBao / QunBaoShu mini-program error codes to human-readable Chinese messages.
    public static func describeCode(_ code: Int) -> String? {
        errorCodeMap[code]
    }

    private static let errorCodeMap: [Int: String] = [
        13314: "登录态异常，请重新登录",
        13318: "账号已被限制登录",
        13324: "需要匿名登录",
        13351: "表单不存在",
        13354: "提交的内容中含有敏感信息，请修改后重新提交",
        13356: "已达参与上限",
        13362: "暂无提交记录",
        13363: "非正常表单",
        13366: "记录已过期",
        13372: "扫码权限不足",
        13374: "此填报记录已被取消，无法操作",
        13375: "该表单已结束",
        13381: "权限已被移除，无法操作",
        13396: "商品信息已变更",
        13397: "该页面已经停止收集啦",
        13398: "还未到开始时间",
        13399: "已经截止啦",
        13408: "表单已删除或不可访问",
        13438: "所选时间不在有效时间内",
        13439: "不在可参与时间范围",
        13467: "内容违规被限制",
        13471: "预约时段校验失败",
        13492: "不在规定的参与星期/时段",
        13550: "操作不被允许",
        13552: "会话超时，请重新登录",
        13567: "服务暂时不可用",
        13584: "该表单为非循环表单",
        13616: "创建人设置了「不允许补卡」",
        13617: "当前没有补卡次数了",
        13618: "所选补卡时间不在有效时间内",
        13619: "创建人设置了「不允许补卡」",
        13620: "补卡次数已用完",
        13686: "登录态失效，请重新登录",
        17936: "预约时段已被占用",
        18208: "存储空间不足",
        36864: "表单数据量过大，正在扩容",
        36866: "表单数据正在清理"
    ]
}

/// Client-side transport, validation, and protocol errors raised by `LaiBaoAPIClient`.
public enum LaiBaoClientError: LocalizedError, Sendable, Equatable {
    case invalidBaseURL(String)
    case invalidPathID(String)
    case httpsDowngradeBlocked(String)
    case responseTooLarge(Int)
    case emptyResponse(Int)
    case invalidJSON(status: Int, detail: String)
    case missingRequiredParameter(String)
    case decodingFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let raw):
            return "服务端地址必须使用 http 或 https 协议且包含主机名: \(raw)"
        case .invalidPathID(let detail):
            return detail
        case .httpsDowngradeBlocked(let detail):
            return detail
        case .responseTooLarge(let limit):
            return "响应体超过 \(limit) 字节上限，拒绝处理截断数据"
        case .emptyResponse(let status):
            return "服务端返回空响应体 (http=\(status))"
        case .invalidJSON(let status, let detail):
            return "服务端返回非 JSON 响应 (http=\(status)): \(detail)"
        case .missingRequiredParameter(let detail):
            return detail
        case .decodingFailed(let detail):
            return "解析响应失败: \(detail)"
        }
    }
}

// MARK: - Auth & Profile API Models

/// Session credentials returned by `POST /v4/login` or `GET /v1/mpQrLoginResult`.
public struct LoginResult: Codable, Hashable, Sendable {
    public var token: String
    public var fuid: String
    public var openID: String
    public var nickName: String
    public var user: JSONValue?

    public init(
        token: String,
        fuid: String = "",
        openID: String = "",
        nickName: String = "",
        user: JSONValue? = nil
    ) {
        self.token = token
        self.fuid = fuid
        self.openID = openID
        self.nickName = nickName
        self.user = user
    }

    private enum CodingKeys: String, CodingKey {
        case token
        case wxLoginAccessToken
        case fuid
        case openID = "openid"
        case fname
        case nickName
        case user = "userInfo"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let primaryToken = try container.decodeIfPresent(String.self, forKey: .token) ?? ""
        let legacyToken = try container.decodeIfPresent(String.self, forKey: .wxLoginAccessToken) ?? ""
        let strippedPrimary = LaiBaoAPIClient.stripAuthPrefix(primaryToken)
        let finalToken = strippedPrimary.isEmpty ? LaiBaoAPIClient.stripAuthPrefix(legacyToken) : strippedPrimary
        self.token = finalToken
        self.fuid = try container.decodeIfPresent(String.self, forKey: .fuid) ?? ""
        self.openID = try container.decodeIfPresent(String.self, forKey: .openID) ?? ""
        let fName = try container.decodeIfPresent(String.self, forKey: .fname) ?? ""
        let altName = try container.decodeIfPresent(String.self, forKey: .nickName) ?? ""
        self.nickName = fName.isEmpty ? altName : fName
        self.user = try container.decodeIfPresent(JSONValue.self, forKey: .user)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(token, forKey: .token)
        try container.encode(fuid, forKey: .fuid)
        try container.encode(openID, forKey: .openID)
        try container.encode(nickName, forKey: .fname)
        try container.encodeIfPresent(user, forKey: .user)
    }
}

/// Official Account QR login session returned by `GET /v1/{mpAppID}/mpQrCode`.
public struct QRSession: Codable, Hashable, Sendable {
    public var scene: String
    public var ticket: String
    public var url: String
    public var expireSeconds: Int

    public init(scene: String, ticket: String, url: String, expireSeconds: Int) {
        self.scene = scene
        self.ticket = ticket
        self.url = url
        self.expireSeconds = expireSeconds
    }
}

/// Decoded user info from `GET /v1/userInfo`.
public struct UserProfileInfo: Codable, Hashable, Sendable {
    public var fuid: String
    public var openID: String
    public var nickName: String
    public var avatarURL: String
    public var raw: JSONValue

    public init(
        fuid: String = "",
        openID: String = "",
        nickName: String = "",
        avatarURL: String = "",
        raw: JSONValue = .null
    ) {
        self.fuid = fuid
        self.openID = openID
        self.nickName = nickName
        self.avatarURL = avatarURL
        self.raw = raw
    }

    public static func parse(from raw: JSONValue) -> UserProfileInfo {
        let dict = raw.objectValue ?? [:]
        func firstString(_ keys: String...) -> String {
            for key in keys {
                if let val = dict[key]?.coercedStringValue, !val.isEmpty {
                    return val
                }
            }
            return ""
        }
        return UserProfileInfo(
            fuid: firstString("fuid", "userId", "id"),
            openID: firstString("openid", "openId"),
            nickName: firstString("fname", "nickName", "nickname", "name"),
            avatarURL: firstString("avatar", "avatarUrl", "headImgUrl", "headimgurl"),
            raw: raw
        )
    }
}

// MARK: - Form List & Detail Models

/// The three list scopes for "My Forms" (`我的接龙`).
public enum FormListScope: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case participation
    case creation
    case manager

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .participation: return "我参与的"
        case .creation: return "我创建的"
        case .manager: return "我管理的"
        }
    }

    public static func parse(_ raw: String) -> FormListScope? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "", "participation", "participate":
            return .participation
        case "creation", "created", "released", "published":
            return .creation
        case "manager", "managed", "manage":
            return .manager
        default:
            return nil
        }
    }
}

/// Summary card item returned by `listForms(scope:pageNo:pageSize:keyword:)`.
public struct FormSummary: Codable, Hashable, Sendable, Identifiable {
    public var id: String { formID }
    public var formID: String
    public var title: String
    public var status: Int
    public var statusText: String
    public var actType: String
    public var creatorName: String
    public var participantCount: Int
    public var updatedAt: String
    public var createTime: String
    public var raw: [String: JSONValue]

    public init(
        formID: String,
        title: String,
        status: Int,
        statusText: String,
        actType: String = "",
        creatorName: String = "",
        participantCount: Int = 0,
        updatedAt: String = "",
        createTime: String = "",
        raw: [String: JSONValue] = [:]
    ) {
        self.formID = formID
        self.title = title
        self.status = status
        self.statusText = statusText
        self.actType = actType
        self.creatorName = creatorName
        self.participantCount = participantCount
        self.updatedAt = updatedAt
        self.createTime = createTime
        self.raw = raw
    }
}

/// Paginated list result returned by `listForms(...)`.
public struct FormSummaryList: Codable, Hashable, Sendable {
    public var scope: FormListScope
    public var pageNo: Int
    public var pageSize: Int
    public var hasMore: Bool
    public var items: [FormSummary]
    public var raw: JSONValue?

    public init(
        scope: FormListScope,
        pageNo: Int,
        pageSize: Int,
        hasMore: Bool,
        items: [FormSummary],
        raw: JSONValue? = nil
    ) {
        self.scope = scope
        self.pageNo = pageNo
        self.pageSize = pageSize
        self.hasMore = hasMore
        self.items = items
        self.raw = raw
    }
}

/// Sub-item inside a form field (e.g., radio/checkbox option).
public struct SubCatalog: Codable, Hashable, Sendable {
    public var cid: String
    public var uuid: String
    public var type: String
    public var role: String
    public var status: Int
    public var content: JSONValue?

    public init(
        cid: String = "",
        uuid: String = "",
        type: String = "",
        role: String = "",
        status: Int = 0,
        content: JSONValue? = nil
    ) {
        self.cid = cid
        self.uuid = uuid
        self.type = type
        self.role = role
        self.status = status
        self.content = content
    }

    private enum CodingKeys: String, CodingKey {
        case cid, uuid, type, role, status, content
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cid = try container.decodeIfPresent(JSONValue.self, forKey: .cid)?.coercedStringValue ?? ""
        self.uuid = try container.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.role = try container.decodeIfPresent(String.self, forKey: .role) ?? ""
        self.status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 0
        self.content = try container.decodeIfPresent(JSONValue.self, forKey: .content)
    }
}

/// A selectable option (`cid` + display `label`) for radio/checkbox fields.
public struct OptionItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String { cid }
    public var cid: String
    public var label: String

    public init(cid: String, label: String) {
        self.cid = cid
        self.label = label
    }
}

/// A single question/field (`catalog`) inside a form.
public struct FormField: Codable, Hashable, Sendable, Identifiable {
    public var id: String { cid.isEmpty ? uuid : cid }
    public var cid: String
    public var uuid: String
    public var type: String
    public var status: Int
    public var must: Bool
    public var content: JSONValue?
    public var catalogType: String
    public var config: [String: JSONValue]
    public var formCatalogs: [SubCatalog]

    public init(
        cid: String,
        uuid: String = "",
        type: String,
        status: Int = 1,
        must: Bool = false,
        content: JSONValue? = nil,
        catalogType: String = "",
        config: [String: JSONValue] = [:],
        formCatalogs: [SubCatalog] = []
    ) {
        self.cid = cid
        self.uuid = uuid
        self.type = type
        self.status = status
        self.must = must
        self.content = content
        self.catalogType = catalogType
        self.config = config
        self.formCatalogs = formCatalogs
    }

    private enum CodingKeys: String, CodingKey {
        case cid, uuid, type, status, must, content, catalogType, config, formCatalogs
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cid = try container.decodeIfPresent(JSONValue.self, forKey: .cid)?.coercedStringValue ?? ""
        self.uuid = try container.decodeIfPresent(String.self, forKey: .uuid) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 0
        self.must = try container.decodeIfPresent(Bool.self, forKey: .must) ?? false
        self.content = try container.decodeIfPresent(JSONValue.self, forKey: .content)
        self.catalogType = try container.decodeIfPresent(String.self, forKey: .catalogType) ?? ""
        self.config = try container.decodeIfPresent([String: JSONValue].self, forKey: .config) ?? [:]
        self.formCatalogs = try container.decodeIfPresent([SubCatalog].self, forKey: .formCatalogs) ?? []
    }

    /// Human-readable title of the field (aligned with Go `Field.Label()`).
    public var title: String {
        if let text = Self.extractContentText(content), !text.isEmpty {
            return text
        }
        if let first = formCatalogs.first,
           let text = Self.extractContentText(first.content), !text.isEmpty {
            return text
        }
        return type
    }

    /// Whether this field is visible (`status != -1`).
    public var isVisible: Bool {
        status != -1
    }

    /// Uppercased field type identifier (e.g., `"LOCATION"`, `"WORD"`, `"DATE"`).
    public var normalizedType: String {
        type.uppercased()
    }

    /// Active selectable options (`cid` + `label`) for radio/checkbox fields.
    public var optionItems: [OptionItem] {
        formCatalogs.compactMap { sub in
            guard sub.status != -1, sub.role == "OPTION", !sub.cid.isEmpty else {
                return nil
            }
            let text = Self.extractContentText(sub.content)
            let label = (text?.isEmpty == false) ? text! : sub.cid
            return OptionItem(cid: sub.cid, label: label)
        }
    }

    /// Active option `cid` list for radio/checkbox fields.
    public var options: [String] {
        optionItems.map(\.cid)
    }

    /// Parsed `SPECIFIED_LOCATION` constraint if present in `config`.
    public var specifiedLocation: SpecifiedLocation? {
        GeoMath.extractSpecifiedLocation(from: config)
    }

    static func extractContentText(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let s):
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .object(let dict):
            for key in ["content", "value", "title", "name", "text"] {
                if let s = dict[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                    return s
                }
            }
            return nil
        default:
            return nil
        }
    }
}

/// Client-side access condition notice parsed from `form.config.accessCondition`.
public struct AccessConditionNotice: Codable, Hashable, Sendable, Identifiable {
    public var id: String { kind }
    public var kind: String
    public var label: String
    public var note: String
    public var active: Bool

    public init(kind: String, label: String, note: String, active: Bool) {
        self.kind = kind
        self.label = label
        self.note = note
        self.active = active
    }
}

/// Detailed activity/form schema returned by `GET /v3/form/{id}` (or fallback `profile` + `catalog`).
public struct ActInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String { formID }
    public var formID: String
    public var title: String
    public var type: String
    public var status: Int
    public var version: JSONValue?
    public var fillPosition: Int
    public var catalogs: [FormField]
    public var formCatalogs: [FormField]
    public var config: [String: JSONValue]
    public var cycle: [String: JSONValue]
    public var rawDetail: JSONValue?

    public init(
        formID: String,
        title: String = "",
        type: String = "",
        status: Int = 2,
        version: JSONValue? = nil,
        fillPosition: Int = 0,
        catalogs: [FormField] = [],
        formCatalogs: [FormField] = [],
        config: [String: JSONValue] = [:],
        cycle: [String: JSONValue] = [:],
        rawDetail: JSONValue? = nil
    ) {
        self.formID = formID
        self.title = title
        self.type = type
        self.status = status
        self.version = version
        self.fillPosition = fillPosition
        self.catalogs = catalogs
        self.formCatalogs = formCatalogs
        self.config = config
        self.cycle = cycle
        self.rawDetail = rawDetail
    }

    private enum CodingKeys: String, CodingKey {
        case formID = "formId"
        case title
        case type
        case status
        case version
        case fillPosition
        case catalogs
        case formCatalogs
        case config
        case cycle
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.formID = try container.decodeIfPresent(JSONValue.self, forKey: .formID)?.coercedStringValue ?? ""
        self.title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.status = try container.decodeIfPresent(Int.self, forKey: .status) ?? 0
        self.version = try container.decodeIfPresent(JSONValue.self, forKey: .version)
        self.fillPosition = try container.decodeIfPresent(Int.self, forKey: .fillPosition) ?? 0
        self.catalogs = try container.decodeIfPresent([FormField].self, forKey: .catalogs) ?? []
        self.formCatalogs = try container.decodeIfPresent([FormField].self, forKey: .formCatalogs) ?? []
        self.config = try container.decodeIfPresent([String: JSONValue].self, forKey: .config) ?? [:]
        self.cycle = try container.decodeIfPresent([String: JSONValue].self, forKey: .cycle) ?? [:]
        self.rawDetail = nil
    }

    /// Unified field list (`catalogs` if non-empty, otherwise `formCatalogs`).
    public var fields: [FormField] {
        !catalogs.isEmpty ? catalogs : formCatalogs
    }

    /// Only visible fields (`status != -1`).
    public var visibleFields: [FormField] {
        fields.filter(\.isVisible)
    }

    /// Best-effort form display title (`title` -> `config` title keys -> `formID`).
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for key in ["title", "name", "activityTitle"] {
            if let s = config[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
                return s
            }
        }
        return formID
    }

    /// Chinese status label aligned with `validator.js`.
    public var statusText: String {
        Self.formStatusText(status)
    }

    /// Active client-side access condition hints (`wifi`, `qrcode`, `password`).
    public var accessConditions: [AccessConditionNotice] {
        guard let ac = config["accessCondition"]?.objectValue else {
            return []
        }
        let entries: [(String, String)] = [
            ("wifi", "需连接指定 WiFi"),
            ("qrcode", "仅限扫码参与"),
            ("password", "需要访问口令")
        ]
        var result: [AccessConditionNotice] = []
        for (key, label) in entries {
            if let sub = ac[key]?.objectValue, sub["active"]?.boolValue == true {
                result.append(AccessConditionNotice(
                    kind: key,
                    label: label,
                    note: "小程序前端存在客户端校验（服务端是否二次校验未证实）",
                    active: true
                ))
            }
        }
        return result
    }

    public static func formStatusText(_ status: Int) -> String {
        switch status {
        case 2: return "进行中"
        case 3: return "未开始"
        case -1: return "已结束"
        case -2: return "已暂停"
        case -3: return "已删除"
        default: return "未知(\(status))"
        }
    }
}

// MARK: - Submission & Record Models

/// Metadata entry attached alongside `IMAGE` catalog values (`imageDetails`).
public struct ImageDetail: Codable, Hashable, Sendable {
    public var url: String
    public var fileName: String

    public init(url: String, fileName: String) {
        self.url = url
        self.fileName = fileName
    }
}

/// Single answered field in a submission or record (`{cid, type, value, imageDetails?}`).
public struct CatalogValue: Codable, Hashable, Sendable, Identifiable {
    public var id: String { cid }
    public var cid: String
    public var type: String
    public var value: JSONValue
    public var imageDetails: [ImageDetail]?

    public init(cid: String, type: String, value: JSONValue, imageDetails: [ImageDetail]? = nil) {
        self.cid = cid
        self.type = type
        self.value = value
        self.imageDetails = imageDetails
    }

    private enum CodingKeys: String, CodingKey {
        case cid, type, value, imageDetails
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.cid = try container.decodeIfPresent(JSONValue.self, forKey: .cid)?.coercedStringValue ?? ""
        self.type = try container.decodeIfPresent(String.self, forKey: .type) ?? ""
        self.value = try container.decodeIfPresent(JSONValue.self, forKey: .value) ?? .null
        self.imageDetails = try container.decodeIfPresent([ImageDetail].self, forKey: .imageDetails)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(cid, forKey: .cid)
        try container.encode(type, forKey: .type)
        try container.encode(value, forKey: .value)
        if let details = imageDetails, !details.isEmpty {
            try container.encode(details, forKey: .imageDetails)
        }
    }
}

/// Request body for `POST /v1/{id}/form_data` and `PUT /v2/{id}/form_data`.
public struct SubmitPayload: Codable, Hashable, Sendable {
    public var fid: String
    public var catalogs: [CatalogValue]
    public var showQuestions: [String]
    public var examUsedTime: JSONValue?
    public var formVersion: JSONValue?
    public var subscribe: [String: JSONValue]
    public var patch: Bool
    public var patchDate: String
    public var patchTimeSection: String

    public init(
        fid: String = "",
        catalogs: [CatalogValue],
        showQuestions: [String] = [],
        examUsedTime: JSONValue? = nil,
        formVersion: JSONValue? = nil,
        subscribe: [String: JSONValue] = [:],
        patch: Bool = false,
        patchDate: String = "",
        patchTimeSection: String = ""
    ) {
        self.fid = fid
        self.catalogs = catalogs
        self.showQuestions = showQuestions
        self.examUsedTime = examUsedTime
        self.formVersion = formVersion
        self.subscribe = subscribe
        self.patch = patch
        self.patchDate = patchDate
        self.patchTimeSection = patchTimeSection
    }

    private enum CodingKeys: String, CodingKey {
        case fid
        case catalogs
        case showQuestions
        case examUsedTime
        case formVersion
        case subscribe
        case patch
        case patchDate
        case patchTimeSection
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fid = try container.decodeIfPresent(String.self, forKey: .fid) ?? ""
        self.catalogs = try container.decodeIfPresent([CatalogValue].self, forKey: .catalogs) ?? []
        self.showQuestions = try container.decodeIfPresent([String].self, forKey: .showQuestions) ?? []
        self.examUsedTime = try container.decodeIfPresent(JSONValue.self, forKey: .examUsedTime)
        self.formVersion = try container.decodeIfPresent(JSONValue.self, forKey: .formVersion)
        self.subscribe = try container.decodeIfPresent([String: JSONValue].self, forKey: .subscribe) ?? [:]
        self.patch = try container.decodeIfPresent(Bool.self, forKey: .patch) ?? false
        self.patchDate = try container.decodeIfPresent(String.self, forKey: .patchDate) ?? ""
        self.patchTimeSection = try container.decodeIfPresent(String.self, forKey: .patchTimeSection) ?? ""
    }

    /// Wire-accurate JSON encoding: always emits `examUsedTime` / `formVersion` (as `null` when absent),
    /// and omits `patch` / `patchDate` / `patchTimeSection` when false/empty.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(fid, forKey: .fid)
        try container.encode(catalogs, forKey: .catalogs)
        try container.encode(showQuestions, forKey: .showQuestions)
        if let examUsedTime {
            try container.encode(examUsedTime, forKey: .examUsedTime)
        } else {
            try container.encodeNil(forKey: .examUsedTime)
        }
        if let formVersion {
            try container.encode(formVersion, forKey: .formVersion)
        } else {
            try container.encodeNil(forKey: .formVersion)
        }
        try container.encode(subscribe, forKey: .subscribe)
        if patch {
            try container.encode(true, forKey: .patch)
        }
        if !patchDate.isEmpty {
            try container.encode(patchDate, forKey: .patchDate)
        }
        if !patchTimeSection.isEmpty {
            try container.encode(patchTimeSection, forKey: .patchTimeSection)
        }
    }

    /// Returns a copy with all patch-checkin fields cleared (required for `PUT /v2/{id}/form_data`).
    public func strippingPatchFields() -> SubmitPayload {
        var copy = self
        copy.patch = false
        copy.patchDate = ""
        copy.patchTimeSection = ""
        return copy
    }

    /// Formats this payload as pretty-printed JSON for dry-run inspection.
    public func prettyJSONString() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self),
              let str = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return str
    }
}

/// Response returned after `submit` or `update`.
public struct SubmitResult: Codable, Hashable, Sendable {
    public var fid: String
    public var sequence: JSONValue?
    public var raw: JSONValue?

    public init(fid: String, sequence: JSONValue? = nil, raw: JSONValue? = nil) {
        self.fid = fid
        self.sequence = sequence
        self.raw = raw
    }

    private enum CodingKeys: String, CodingKey {
        case fid, sequence, raw
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fid = try container.decodeIfPresent(JSONValue.self, forKey: .fid)?.coercedStringValue ?? ""
        self.sequence = try container.decodeIfPresent(JSONValue.self, forKey: .sequence)
        self.raw = try container.decodeIfPresent(JSONValue.self, forKey: .raw)
    }
}

/// Review and revision labels attached to a record.
public struct RecordLabels: Codable, Hashable, Sendable {
    public var reviewLabels: [JSONValue]
    public var reviseLabels: [JSONValue]

    public init(reviewLabels: [JSONValue] = [], reviseLabels: [JSONValue] = []) {
        self.reviewLabels = reviewLabels
        self.reviseLabels = reviseLabels
    }

    public var displayStrings: [String] {
        (reviewLabels + reviseLabels).compactMap { val in
            if let s = val.stringValue, !s.isEmpty { return s }
            if let dict = val.objectValue {
                for key in ["name", "label", "title", "text"] {
                    if let s = dict[key]?.stringValue, !s.isEmpty { return s }
                }
            }
            return val.coercedStringValue
        }
    }
}

/// A single submitted check-in record.
public struct RecordItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String {
        if !fid.isEmpty { return fid }
        let seq = sequence?.coercedStringValue ?? ""
        let ct = createTime?.coercedStringValue ?? ""
        return "\(seq)-\(ct)-\(submitter)"
    }

    public var fid: String
    public var sequence: JSONValue?
    public var createTime: JSONValue?
    public var updateTime: JSONValue?
    public var submitter: String
    public var labels: RecordLabels?
    public var catalogs: [CatalogValue]
    public var raw: [String: JSONValue]

    public init(
        fid: String,
        sequence: JSONValue? = nil,
        createTime: JSONValue? = nil,
        updateTime: JSONValue? = nil,
        submitter: String = "",
        labels: RecordLabels? = nil,
        catalogs: [CatalogValue] = [],
        raw: [String: JSONValue] = [:]
    ) {
        self.fid = fid
        self.sequence = sequence
        self.createTime = createTime
        self.updateTime = updateTime
        self.submitter = submitter
        self.labels = labels
        self.catalogs = catalogs
        self.raw = raw
    }

    public var sequenceText: String {
        sequence?.coercedStringValue ?? ""
    }

    public var createTimeText: String {
        Self.formatTimestamp(createTime)
    }

    public var updateTimeText: String {
        Self.formatTimestamp(updateTime)
    }

    public static func formatTimestamp(_ value: JSONValue?) -> String {
        guard let value else { return "" }
        if let str = value.stringValue {
            let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            if let numeric = Int64(trimmed), numeric > 1_000_000_000 {
                return formatEpoch(numeric)
            }
            return trimmed
        }
        if let num = value.int64Value, num > 1_000_000_000 {
            return formatEpoch(num)
        }
        return ""
    }

    private static func formatEpoch(_ epoch: Int64) -> String {
        let seconds: TimeInterval = epoch > 100_000_000_000
            ? TimeInterval(epoch) / 1000.0
            : TimeInterval(epoch)
        let date = Date(timeIntervalSince1970: seconds)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}

/// Unified list result returned by `myRecords` and `allRecords`.
public struct RecordList: Codable, Hashable, Sendable {
    public var list: [RecordItem]
    public var total: Int
    public var raw: JSONValue?

    public init(list: [RecordItem] = [], total: Int = 0, raw: JSONValue? = nil) {
        self.list = list
        self.total = total
        self.raw = raw
    }
}

// MARK: - Local Workspace Domain Models

/// Account metadata persisted in per-user `accounts.json`.
/// **SECURITY**: Actual bearer tokens are NEVER stored here; they live exclusively in iOS Keychain
/// keyed by `(userID, accountName)`.
public struct LaiBaoAccount: Codable, Hashable, Sendable, Identifiable {
    public var id: String { name }
    public var name: String
    public var baseURL: String
    public var appID: String
    public var note: String
    public var fuid: String
    public var openID: String
    public var nickName: String
    public var source: String
    public var updatedAt: Date
    public var hasToken: Bool
    public var tokenMask: String

    public init(
        name: String,
        baseURL: String = LaiBaoAPIClient.defaultBaseURL,
        appID: String = LaiBaoAPIClient.defaultAppID,
        note: String = "",
        fuid: String = "",
        openID: String = "",
        nickName: String = "",
        source: String = "",
        updatedAt: Date = Date(),
        hasToken: Bool = false,
        tokenMask: String = ""
    ) {
        self.name = name
        self.baseURL = baseURL
        self.appID = appID
        self.note = note
        self.fuid = fuid
        self.openID = openID
        self.nickName = nickName
        self.source = source
        self.updatedAt = updatedAt
        self.hasToken = hasToken
        self.tokenMask = tokenMask
    }
}

/// Saved Point-of-Interest entry in a user's POI pool.
public struct POIItem: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var lat: Double
    public var lng: Double
    public var addr: String
    public var title: String
    public var wgs84: Bool

    public init(
        id: String = UUID().uuidString,
        lat: Double,
        lng: Double,
        addr: String,
        title: String,
        wgs84: Bool = false
    ) {
        self.id = id
        self.lat = lat
        self.lng = lng
        self.addr = addr
        self.title = title
        self.wgs84 = wgs84
    }

    public var point: GeoPoint {
        GeoPoint(lat: lat, lng: lng)
    }

    public var gcj02Point: GeoPoint {
        wgs84 ? GeoMath.wgs84ToGCJ02(point) : point
    }

    public var wgs84Point: GeoPoint {
        wgs84 ? point : GeoMath.gcj02ToWGS84(point)
    }

    public func validate() throws {
        try GeoMath.validateCoord(lat: lat, lng: lng)
    }
}

/// Local scheduled reminder / check-in plan persisted per user.
public struct ReminderPlan: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var accountName: String
    public var formID: String
    public var enabled: Bool
    public var clocks: [String]
    /// ISO weekday numbers `1...7` (1 = Monday, ..., 7 = Sunday). Empty means every day.
    public var weekdays: [Int]
    public var usePOIPool: Bool
    public var lat: Double
    public var lng: Double
    public var addr: String
    public var title: String
    public var wgs84: Bool
    public var jitterMeters: Double
    public var lastTriggeredAt: Date?
    public var lastRunStatus: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        accountName: String = "default",
        formID: String,
        enabled: Bool = true,
        clocks: [String] = ["08:45"],
        weekdays: [Int] = [],
        usePOIPool: Bool = false,
        lat: Double = 0,
        lng: Double = 0,
        addr: String = "",
        title: String = "",
        wgs84: Bool = false,
        jitterMeters: Double = 15,
        lastTriggeredAt: Date? = nil,
        lastRunStatus: String = ""
    ) {
        self.id = id
        self.name = name
        self.accountName = accountName
        self.formID = formID
        self.enabled = enabled
        self.clocks = clocks
        self.weekdays = weekdays
        self.usePOIPool = usePOIPool
        self.lat = lat
        self.lng = lng
        self.addr = addr
        self.title = title
        self.wgs84 = wgs84
        self.jitterMeters = jitterMeters
        self.lastTriggeredAt = lastTriggeredAt
        self.lastRunStatus = lastRunStatus
    }
}

/// Sanitized execution log entry stored in a capped per-user ring buffer.
public struct CheckinRunLog: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var timestamp: Date
    public var planID: String?
    public var formID: String
    public var formTitle: String
    public var accountName: String
    public var dryRun: Bool
    public var success: Bool
    public var fid: String
    public var message: String

    public init(
        id: String = UUID().uuidString,
        timestamp: Date = Date(),
        planID: String? = nil,
        formID: String,
        formTitle: String = "",
        accountName: String = "",
        dryRun: Bool = false,
        success: Bool,
        fid: String = "",
        message: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.planID = planID
        self.formID = formID
        self.formTitle = formTitle
        self.accountName = accountName
        self.dryRun = dryRun
        self.success = success
        self.fid = fid
        self.message = message
    }
}

/// Per-user workspace preferences persisted in `settings.json`.
public struct UserWorkspaceSettings: Codable, Hashable, Sendable {
    public var activeAccount: String
    public var mpAppID: String
    public var ver: String
    public var geocodeURL: String
    public var biometricUnlockEnabled: Bool

    public init(
        activeAccount: String = "default",
        mpAppID: String = LaiBaoAPIClient.defaultMPAppID,
        ver: String = LaiBaoAPIClient.defaultVer,
        geocodeURL: String = "",
        biometricUnlockEnabled: Bool = false
    ) {
        self.activeAccount = activeAccount
        self.mpAppID = mpAppID
        self.ver = ver
        self.geocodeURL = geocodeURL
        self.biometricUnlockEnabled = biometricUnlockEnabled
    }
}
