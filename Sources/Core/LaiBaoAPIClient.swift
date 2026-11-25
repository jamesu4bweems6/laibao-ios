import Foundation

/// Per-request `URLSessionTaskDelegate` that blocks HTTPS -> HTTP downgrade redirects,
/// rejects non-HTTP(S) redirect schemes, and caps redirect chains at 10 hops.
final class HTTPSDowngradeBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hopCount = 0
    private var sawHTTPS = false
    private var _blockedReason: String?

    init(initialScheme: String?) {
        self.sawHTTPS = (initialScheme?.lowercased() == "https")
        super.init()
    }

    var blockedReason: String? {
        lock.lock()
        defer { lock.unlock() }
        return _blockedReason
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }

        if response.url?.scheme?.lowercased() == "https" {
            sawHTTPS = true
        }
        hopCount += 1
        if hopCount > 10 {
            _blockedReason = "重定向次数过多"
            completionHandler(nil)
            return
        }

        let nextScheme = request.url?.scheme?.lowercased() ?? ""
        if sawHTTPS && nextScheme != "https" {
            _blockedReason = "拒绝从 HTTPS 重定向降级到 \(nextScheme)"
            completionHandler(nil)
            return
        }
        if nextScheme != "http" && nextScheme != "https" {
            _blockedReason = "拒绝重定向到非 HTTP 协议: \(nextScheme)"
            completionHandler(nil)
            return
        }
        if nextScheme == "https" {
            sawHTTPS = true
        }
        completionHandler(request)
    }
}

/// Thread-safe actor client for `form.qun100.com` (`来宝接龙 / 群报数`).
/// Guarantees 100% wire-protocol parity with `laibao/internal/api` and the WeChat Mini Program.
public actor LaiBaoAPIClient {
    // MARK: - Protocol Constants

    public static let defaultBaseURL = "https://form.qun100.com"
    public static let defaultAppID = "wx04cb967b202c71bb"
    public static let defaultVer = "3.81.0"
    /// Official Account AppID used for H5 QR code login (NOT the mini-program AppID).
    public static let defaultMPAppID = "wxa4dd314619820d4c"
    public static let defaultUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148 MicroMessenger/8.0.49(0x18003128) NetType/WIFI Language/zh_CN"

    public static let defaultSourceBrand = "iPhone"
    public static let defaultSourcePlatform = "ios"
    public static let defaultSourceSystem = "iOS 17.5"
    public static let defaultSourcePlatformType = "MOBILE_WECHAT"

    public static let maxResponseBytes = 8 * 1024 * 1024
    public static let defaultQRExpireSeconds = 300

    private static let pathSegmentAllowed: CharacterSet = {
        var set = CharacterSet.urlPathAllowed
        set.remove(charactersIn: "/?#%&")
        return set
    }()

    // MARK: - Configuration Properties

    public nonisolated let baseURL: String
    public nonisolated let appID: String
    public nonisolated let ver: String
    public nonisolated let userAgent: String

    private var token: String
    private let session: URLSession

    public init(
        baseURL: String = LaiBaoAPIClient.defaultBaseURL,
        token: String = "",
        appID: String = LaiBaoAPIClient.defaultAppID,
        ver: String = LaiBaoAPIClient.defaultVer,
        userAgent: String = LaiBaoAPIClient.defaultUA,
        session: URLSession? = nil
    ) {
        let trimmedBase = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBase = trimmedBase.isEmpty ? Self.defaultBaseURL : trimmedBase
        self.baseURL = Self.trimTrailingSlashes(effectiveBase)
        self.token = Self.stripAuthPrefix(token)
        let trimmedApp = appID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.appID = trimmedApp.isEmpty ? Self.defaultAppID : trimmedApp
        let trimmedVer = ver.trimmingCharacters(in: .whitespacesAndNewlines)
        self.ver = trimmedVer.isEmpty ? Self.defaultVer : trimmedVer
        self.userAgent = userAgent

        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 60
            config.httpCookieStorage = nil
            config.httpShouldSetCookies = false
            self.session = URLSession(configuration: config)
        }
    }

    public func updateToken(_ newToken: String) {
        self.token = Self.stripAuthPrefix(newToken)
    }

    public func hasToken() -> Bool {
        !token.isEmpty
    }

    public func maskedToken() -> String {
        Self.maskToken(token)
    }

    // MARK: - Static Utilities

    /// Strips surrounding whitespace and any case-insensitive `"Bearer "` prefix.
    /// The LaiBao / QunBaoShu backend expects a bare token in the `Authorization` header.
    public static func stripAuthPrefix(_ token: String) -> String {
        var str = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if str.count >= 7, str.prefix(7).lowercased() == "bearer " {
            str = String(str.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return str
    }

    /// Masks a bearer token for safe UI/log display without leaking full credentials.
    public static func maskToken(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let chars = Array(trimmed)
        if chars.count <= 10 {
            return "***"
        }
        if chars.count <= 16 {
            return String(chars.prefix(2)) + "***" + String(chars.suffix(2))
        }
        return String(chars.prefix(6)) + "..." + String(chars.suffix(4))
    }

    /// Validates that a base URL uses `http` or `https` and includes a host.
    public static func validateBaseURL(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host, !host.isEmpty else {
            throw LaiBaoClientError.invalidBaseURL(raw)
        }
        return trimTrailingSlashes(trimmed)
    }

    /// Validates a path identifier (`formID` / `mpAppID`) against traversal, query/fragment injection,
    /// whitespace, and control characters, returning a percent-encoded path segment.
    public static func validatePathID(_ id: String) throws -> String {
        guard !id.isEmpty, id.trimmingCharacters(in: .whitespacesAndNewlines) == id else {
            throw LaiBaoClientError.invalidPathID("参数 ID 不能为空或包含首尾空白")
        }
        if id.contains("..") {
            throw LaiBaoClientError.invalidPathID("参数 ID 包含非法路径字符: \(id)")
        }
        let forbidden: Set<Character> = ["/", "\\", "?", "#", "%", "&"]
        if id.contains(where: { forbidden.contains($0) }) {
            throw LaiBaoClientError.invalidPathID("参数 ID 包含非法路径字符: \(id)")
        }
        for scalar in id.unicodeScalars {
            if CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                throw LaiBaoClientError.invalidPathID("参数 ID 包含空白或控制字符: \(id)")
            }
        }
        guard let escaped = id.addingPercentEncoding(withAllowedCharacters: pathSegmentAllowed) else {
            throw LaiBaoClientError.invalidPathID("参数 ID 编码失败: \(id)")
        }
        return escaped
    }

    private static func trimTrailingSlashes(_ value: String) -> String {
        var str = value
        while str.hasSuffix("/") {
            str.removeLast()
        }
        return str
    }

    // MARK: - Core Transport

    private struct RequestOptions {
        var clientFormID: String?
        var extraHeaders: [String: String] = [:]
        var minimalAuth: Bool = false
        var sourceHeaders: Bool = false
    }

    private struct Envelope: Decodable {
        let code: Int?
        let message: String?
        let data: JSONValue?
    }

    private func performRequest(
        method: String,
        path: String,
        queryItems: [URLQueryItem] = [],
        bodyData: Data? = nil,
        options: RequestOptions = RequestOptions()
    ) async throws -> JSONValue? {
        let validBase = try Self.validateBaseURL(baseURL)
        guard var components = URLComponents(string: validBase + path) else {
            throw LaiBaoClientError.invalidBaseURL(validBase + path)
        }
        if !queryItems.isEmpty {
            components.queryItems = queryItems
        }
        guard let url = components.url else {
            throw LaiBaoClientError.invalidBaseURL(validBase + path)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(ver, forHTTPHeaderField: "ver")

        if !options.minimalAuth {
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            if !userAgent.isEmpty {
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            }
            if !appID.isEmpty {
                request.setValue(appID, forHTTPHeaderField: "Client-App-Id")
            }
            if let formID = options.clientFormID, !formID.isEmpty {
                request.setValue(formID, forHTTPHeaderField: "Client-Form-Id")
            }
            if !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "Authorization")
            }
        }

        if options.sourceHeaders {
            request.setValue(Self.defaultSourceBrand, forHTTPHeaderField: "X-Source-Brand")
            request.setValue(Self.defaultSourcePlatform, forHTTPHeaderField: "X-Source-Platform")
            request.setValue(Self.defaultSourceSystem, forHTTPHeaderField: "X-Source-System")
            request.setValue(Self.defaultSourcePlatformType, forHTTPHeaderField: "X-Source-Platform-Type")
        }

        for (key, value) in options.extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        if let bodyData {
            request.httpBody = bodyData
        }

        let redirectDelegate = HTTPSDowngradeBlockingDelegate(initialScheme: url.scheme)
        let (data, response) = try await session.data(for: request, delegate: redirectDelegate)

        if let blocked = redirectDelegate.blockedReason {
            throw LaiBaoClientError.httpsDowngradeBlocked(blocked)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LaiBaoClientError.decodingFailed("非 HTTP 响应")
        }

        // Defense-in-depth: also detect unfollowed 3xx HTTPS -> HTTP downgrades (e.g., from custom protocols).
        if (300..<400).contains(httpResponse.statusCode),
           url.scheme?.lowercased() == "https",
           let loc = httpResponse.value(forHTTPHeaderField: "Location"),
           let nextURL = URL(string: loc, relativeTo: url)?.absoluteURL,
           nextURL.scheme?.lowercased() != "https" {
            throw LaiBaoClientError.httpsDowngradeBlocked(
                "拒绝从 HTTPS 重定向降级到 \(nextURL.scheme ?? "unknown")"
            )
        }

        if data.count > Self.maxResponseBytes {
            throw LaiBaoClientError.responseTooLarge(Self.maxResponseBytes)
        }

        // Explicitly allow HTTP 204 No Content empty body (used by PUT /v2/{id}/form_data).
        if httpResponse.statusCode == 204 {
            return nil
        }

        let trimmedString = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedData = trimmedString.data(using: .utf8) ?? Data()

        var envelope: Envelope?
        var decodeError: Error?
        if !trimmedData.isEmpty {
            do {
                envelope = try JSONDecoder().decode(Envelope.self, from: trimmedData)
            } catch {
                decodeError = error
            }
        }

        let envCode = envelope?.code ?? 0
        let envMessage = envelope?.message ?? ""

        if httpResponse.statusCode == 401 || (decodeError == nil && (envCode == 13552 || envCode == 13686)) {
            let msg = envMessage.isEmpty ? "会话超时，请重新登录" : envMessage
            throw APIError(status: httpResponse.statusCode, code: envCode, message: msg)
        }

        if httpResponse.statusCode < 200 || httpResponse.statusCode >= 300 {
            var msg = decodeError == nil ? envMessage : ""
            let code = decodeError == nil ? envCode : 0
            if msg.isEmpty, code != 0, let described = APIError.describeCode(code) {
                msg = described
            }
            if msg.isEmpty, !trimmedString.isEmpty {
                msg = Self.truncate(trimmedString, limit: 240)
            }
            if msg.isEmpty {
                msg = HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
            }
            throw APIError(status: httpResponse.statusCode, code: code, message: msg)
        }

        if trimmedData.isEmpty {
            throw LaiBaoClientError.emptyResponse(httpResponse.statusCode)
        }

        if let decodeError {
            throw LaiBaoClientError.invalidJSON(
                status: httpResponse.statusCode,
                detail: "\(decodeError.localizedDescription) (原始: \(Self.truncate(trimmedString, limit: 240)))"
            )
        }

        guard let parsedEnvelope = envelope else {
            throw LaiBaoClientError.emptyResponse(httpResponse.statusCode)
        }

        if let code = parsedEnvelope.code, code != 0 {
            let msg: String
            if !envMessage.isEmpty {
                msg = envMessage
            } else if let described = APIError.describeCode(code) {
                msg = described
            } else {
                msg = Self.truncate(trimmedString, limit: 240)
            }
            throw APIError(status: httpResponse.statusCode, code: code, message: msg)
        }

        return parsedEnvelope.data
    }

    private static func truncate(_ text: String, limit: Int) -> String {
        if text.count <= limit { return text }
        return String(text.prefix(limit)) + "..."
    }

    private static func isFatalFormError(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let apiErr = error as? APIError {
            return apiErr.isFatalFormError
        }
        return false
    }

    private static func isNoRecordsError(_ error: Error) -> Bool {
        if let apiErr = error as? APIError {
            return apiErr.isNoRecords
        }
        return false
    }

    // MARK: - Auth & Time Endpoints

    /// `GET /v1/server-time` with `Cache-Control: no-store`.
    /// Parses `epochMillis` with fallback to legacy `serverTime`.
    public func serverTime() async throws -> Int64 {
        let data = try await performRequest(
            method: "GET",
            path: "/v1/server-time",
            options: RequestOptions(extraHeaders: ["Cache-Control": "no-store"])
        )
        guard let dict = data?.objectValue else {
            return 0
        }
        if let epochMillis = dict["epochMillis"]?.int64Value, epochMillis != 0 {
            return epochMillis
        }
        return dict["serverTime"]?.int64Value ?? 0
    }

    /// `POST /v4/login` with `{code, appId}` and minimal headers (`Content-Type` + `ver` ONLY).
    /// Supports both `token` and legacy `wxLoginAccessToken` response keys.
    public func loginByCode(_ code: String, appID: String? = nil) async throws -> LoginResult {
        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            throw LaiBaoClientError.missingRequiredParameter("缺少 wx.login code")
        }
        let targetAppID = (appID?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? self.appID
        let payload: [String: String] = ["code": trimmedCode, "appId": targetAppID]
        let body = try JSONEncoder().encode(payload)
        let data = try await performRequest(
            method: "POST",
            path: "/v4/login",
            bodyData: body,
            options: RequestOptions(minimalAuth: true)
        )
        guard let data else {
            throw LaiBaoClientError.decodingFailed("登录响应中没有令牌")
        }
        let result = try data.decode(as: LoginResult.self)
        guard !result.token.isEmpty else {
            throw LaiBaoClientError.decodingFailed("登录响应中没有令牌")
        }
        return result
    }

    /// `GET /v1/{mpAppID}/mpQrCode` — creates an Official Account QR login session.
    public func createQRSession(mpAppID: String? = nil) async throws -> QRSession {
        let rawAppID = mpAppID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let effectiveAppID = rawAppID.isEmpty ? Self.defaultMPAppID : rawAppID
        let escaped = try Self.validatePathID(effectiveAppID)

        let data = try await performRequest(
            method: "GET",
            path: "/v1/\(escaped)/mpQrCode"
        )
        guard let root = data?.objectValue,
              let scene = root["scene"]?.stringValue, !scene.isEmpty,
              let ticketObj = root["ticket"]?.objectValue,
              let qrURL = ticketObj["url"]?.stringValue, !qrURL.isEmpty else {
            throw LaiBaoClientError.decodingFailed("二维码响应异常")
        }
        let ticket = ticketObj["ticket"]?.stringValue ?? ""
        let rawExpire = ticketObj["expireSeconds"]?.intValue ?? 0
        let expireSeconds = rawExpire > 0 ? rawExpire : Self.defaultQRExpireSeconds

        return QRSession(
            scene: scene,
            ticket: ticket,
            url: qrURL,
            expireSeconds: expireSeconds
        )
    }

    /// `GET /v1/mpQrLoginResult?scene=...` — non-blocking single poll of QR scan status.
    /// Returns `nil` when the user has not confirmed scanning yet.
    public func checkQR(scene: String) async throws -> LoginResult? {
        let trimmedScene = scene.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedScene.isEmpty else {
            throw LaiBaoClientError.missingRequiredParameter("缺少二维码 scene")
        }
        let data = try await performRequest(
            method: "GET",
            path: "/v1/mpQrLoginResult",
            queryItems: [URLQueryItem(name: "scene", value: trimmedScene)]
        )
        guard let data, !data.isNull else {
            return nil
        }
        if let dict = data.objectValue, dict.isEmpty {
            return nil
        }
        let result = try data.decode(as: LoginResult.self)
        return result.token.isEmpty ? nil : result
    }

    /// `GET /v1/userInfo` — verifies the current bearer token and retrieves profile metadata.
    public func userInfo() async throws -> UserProfileInfo {
        let data = try await performRequest(method: "GET", path: "/v1/userInfo")
        return UserProfileInfo.parse(from: data ?? .null)
    }

    // MARK: - Form List & Detail Endpoints

    /// Fetches "My Forms" across all 3 scopes:
    /// - `.participation`: `GET /v1/participation_forms?pageNo=&pageSize=`
    /// - `.creation`: `GET /v2/creation_forms?pageNo=&pageSize=&folderId=&forDraft=false` (flattens grouped `creations` sorted desc by `createTime`)
    /// - `.manager`: `GET /v3/manager_forms?pageNo=&pageSize=`
    public func listForms(
        scope: FormListScope,
        pageNo: Int = 1,
        pageSize: Int = 20,
        keyword: String = ""
    ) async throws -> FormSummaryList {
        let safePageNo = max(1, pageNo)
        let safePageSize = min(100, max(1, pageSize))

        let path: String
        let queryItems: [URLQueryItem]
        switch scope {
        case .participation:
            path = "/v1/participation_forms"
            queryItems = [
                URLQueryItem(name: "pageNo", value: String(safePageNo)),
                URLQueryItem(name: "pageSize", value: String(safePageSize))
            ]
        case .creation:
            path = "/v2/creation_forms"
            queryItems = [
                URLQueryItem(name: "pageNo", value: String(safePageNo)),
                URLQueryItem(name: "pageSize", value: String(safePageSize)),
                URLQueryItem(name: "folderId", value: ""),
                URLQueryItem(name: "forDraft", value: "false")
            ]
        case .manager:
            path = "/v3/manager_forms"
            queryItems = [
                URLQueryItem(name: "pageNo", value: String(safePageNo)),
                URLQueryItem(name: "pageSize", value: String(safePageSize))
            ]
        }

        let data = try await performRequest(method: "GET", path: path, queryItems: queryItems)
        return Self.parseFormSummaryList(
            scope: scope,
            pageNo: safePageNo,
            pageSize: safePageSize,
            keyword: keyword,
            raw: data
        )
    }

    /// `GET /v3/form/{formID}` with non-fatal fallback to `/v1/form/{formID}/profile` + `/v1/form/{formID}/catalog`.
    /// Short-circuits fatal auth/not-found errors, accepts 0-field forms, and sends per-request `Client-Form-Id`.
    public func formDetail(formID: String) async throws -> ActInfo {
        let escaped = try Self.validatePathID(formID)
        let opts = RequestOptions(clientFormID: formID)

        var primaryError: Error?
        do {
            if let raw = try await performRequest(method: "GET", path: "/v3/form/\(escaped)", options: opts),
               !raw.isNull {
                var info = try raw.decode(as: ActInfo.self)
                info.rawDetail = raw
                if info.formID.isEmpty {
                    info.formID = formID
                }
                return info
            } else {
                primaryError = LaiBaoClientError.decodingFailed("表单详情返回空 data")
            }
        } catch {
            primaryError = error
        }

        if let primaryError, Self.isFatalFormError(primaryError) {
            throw primaryError
        }

        // Non-fatal fallback: profile + catalog.
        let profileData = try await performRequest(
            method: "GET",
            path: "/v1/form/\(escaped)/profile",
            options: opts
        )
        let catalogData = try await performRequest(
            method: "GET",
            path: "/v1/form/\(escaped)/catalog",
            options: opts
        )

        let profileDict = profileData?.objectValue ?? [:]
        var catalogs: [FormField] = []
        if let catArrayVal = catalogData?.objectValue?["catalogs"] {
            catalogs = (try? catArrayVal.decode(as: [FormField].self)) ?? []
        }

        return ActInfo(
            formID: formID,
            title: profileDict["title"]?.stringValue ?? "",
            type: profileDict["type"]?.stringValue ?? "",
            status: profileDict["status"]?.intValue ?? 0,
            version: profileDict["version"],
            fillPosition: profileDict["fillPosition"]?.intValue ?? 0,
            catalogs: catalogs,
            formCatalogs: [],
            config: profileDict["config"]?.objectValue ?? [:],
            cycle: profileDict["cycle"]?.objectValue ?? [:],
            rawDetail: profileData
        )
    }

    // MARK: - Submission & Update Endpoints

    /// `POST /v1/{formID}/form_data` (creates a new record) with `Client-Form-Id` + 4 `X-Source-*` headers.
    public func submit(formID: String, payload: SubmitPayload) async throws -> SubmitResult {
        let escaped = try Self.validatePathID(formID)
        let body = try JSONEncoder().encode(payload)
        let raw = try await performRequest(
            method: "POST",
            path: "/v1/\(escaped)/form_data",
            bodyData: body,
            options: RequestOptions(clientFormID: formID, sourceHeaders: true)
        )
        return try Self.parseSubmitResult(raw: raw, fallbackFID: payload.fid)
    }

    /// `PUT /v2/{formID}/form_data` (edits an existing record; `payload.fid` required).
    /// Strips `patch`/`patchDate`/`patchTimeSection`, handles HTTP 204 No Content, and sends `Client-Form-Id` + 4 `X-Source-*` headers.
    public func update(formID: String, payload: SubmitPayload) async throws -> SubmitResult {
        let trimmedFID = payload.fid.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFID.isEmpty else {
            throw LaiBaoClientError.missingRequiredParameter("编辑记录必须提供 fid")
        }
        let escaped = try Self.validatePathID(formID)
        var clean = payload.strippingPatchFields()
        clean.fid = trimmedFID
        let body = try JSONEncoder().encode(clean)
        let raw = try await performRequest(
            method: "PUT",
            path: "/v2/\(escaped)/form_data",
            bodyData: body,
            options: RequestOptions(clientFormID: formID, sourceHeaders: true)
        )
        return try Self.parseSubmitResult(raw: raw, fallbackFID: clean.fid)
    }

    // MARK: - Record Query Endpoints

    /// Fetches the current account's own submitted records:
    /// 1. Primary: `GET /v1/{formID}/form_data/owner?pageNo=&pageSize=` (treats code `13362` as empty)
    /// 2. Fallback: `GET /v3/{formID}/form_data` (NO query params, parses `formDataDtoList`)
    /// 3. Page-1 safety net: `lastRecord(formID:)`
    public func myRecords(formID: String, pageNo: Int = 1, pageSize: Int = 10) async throws -> RecordList {
        let escaped = try Self.validatePathID(formID)
        let safePageNo = max(1, pageNo)
        let safePageSize = max(1, pageSize)
        let opts = RequestOptions(clientFormID: formID)

        // 1. Primary: /v1/{id}/form_data/owner
        var primaryError: Error?
        do {
            let raw = try await performRequest(
                method: "GET",
                path: "/v1/\(escaped)/form_data/owner",
                queryItems: [
                    URLQueryItem(name: "pageNo", value: String(safePageNo)),
                    URLQueryItem(name: "pageSize", value: String(safePageSize))
                ],
                options: opts
            )
            let parsed = Self.parseRecordList(from: raw)
            if !parsed.list.isEmpty {
                return parsed
            }
        } catch {
            if Self.isFatalFormError(error) {
                throw error
            }
            if !Self.isNoRecordsError(error) {
                primaryError = error
            }
        }

        // On page > 1, an empty successful primary response means end of pagination (no fallback).
        if primaryError == nil && safePageNo > 1 {
            return RecordList(list: [], total: 0)
        }

        // 2. Fallback: GET /v3/{id}/form_data (strictly without query parameters).
        var fallbackError: Error?
        do {
            let fbRaw = try await performRequest(
                method: "GET",
                path: "/v3/\(escaped)/form_data",
                options: opts
            )
            let parsed = Self.parseRecordList(from: fbRaw)
            if !parsed.list.isEmpty {
                return parsed
            }
        } catch {
            if Self.isFatalFormError(error) {
                throw error
            }
            if !Self.isNoRecordsError(error) {
                fallbackError = error
            }
        }

        if safePageNo > 1 {
            if let primaryError, fallbackError != nil {
                throw primaryError
            }
            return RecordList(list: [], total: 0)
        }

        // 3. Page-1 safety net: GET /v1/{id}/form_data/last
        do {
            if let last = try await lastRecord(formID: formID) {
                return RecordList(list: [last], total: 1, raw: .object(last.raw))
            }
        } catch {
            if Self.isFatalFormError(error) {
                throw error
            }
            if let primaryError, fallbackError != nil {
                throw primaryError
            }
        }

        return RecordList(list: [], total: 0)
    }

    /// `GET /v1/{formID}/form_data/last` — unwraps `{ "formDataDto": { ... } }` and maps `13362` to `nil`.
    public func lastRecord(formID: String) async throws -> RecordItem? {
        let escaped = try Self.validatePathID(formID)
        let raw: JSONValue?
        do {
            raw = try await performRequest(
                method: "GET",
                path: "/v1/\(escaped)/form_data/last",
                options: RequestOptions(clientFormID: formID)
            )
        } catch {
            if Self.isNoRecordsError(error) {
                return nil
            }
            throw error
        }

        guard let dict = raw?.objectValue, !dict.isEmpty else {
            return nil
        }

        if let dtoVal = dict["formDataDto"] {
            if let dtoDict = dtoVal.objectValue, !dtoDict.isEmpty {
                var item = Self.parseRecordItem(from: dtoDict)
                if item.labels == nil {
                    item.labels = Self.parseRecordLabels(from: dict)
                }
                return item
            }
            let top = Self.parseRecordItem(from: dict)
            return top.fid.isEmpty ? nil : top
        }

        return Self.parseRecordItem(from: dict)
    }

    /// `GET /v3/{formID}/form_datas` — lists all participants' submissions with review/revise labels.
    public func allRecords(formID: String, pageNo: Int = 1, pageSize: Int = 10) async throws -> RecordList {
        let escaped = try Self.validatePathID(formID)
        let safePageNo = max(1, pageNo)
        let safePageSize = max(1, pageSize)
        do {
            let raw = try await performRequest(
                method: "GET",
                path: "/v3/\(escaped)/form_datas",
                queryItems: [
                    URLQueryItem(name: "pageNo", value: String(safePageNo)),
                    URLQueryItem(name: "pageSize", value: String(safePageSize)),
                    URLQueryItem(name: "queryTimestamp", value: ""),
                    URLQueryItem(name: "stateLabelEnum", value: ""),
                    URLQueryItem(name: "sortType", value: "")
                ],
                options: RequestOptions(clientFormID: formID)
            )
            return Self.parseRecordList(from: raw)
        } catch {
            if Self.isNoRecordsError(error) {
                return RecordList(list: [], total: 0)
            }
            throw error
        }
    }

    /// `GET /v1/{formID}/name_list/used` — fetches live preset roster items and submission counts
    /// for fields with `config.NAME_LIST.active == true`. Treats code `13362` as empty `[]`.
    public func usedNameLists(
        formID: String,
        date: String = "",
        timeSection: String = ""
    ) async throws -> [UsedNameListBucket] {
        let escaped = try Self.validatePathID(formID)
        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "date", value: date)
        ]
        let cleanSection = timeSection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanSection.isEmpty {
            queryItems.append(URLQueryItem(name: "timeSection", value: cleanSection))
        }
        do {
            let raw = try await performRequest(
                method: "GET",
                path: "/v1/\(escaped)/name_list/used",
                queryItems: queryItems,
                options: RequestOptions(clientFormID: formID)
            )
            return Self.parseUsedNameLists(from: raw)
        } catch {
            if Self.isNoRecordsError(error) {
                return []
            }
            throw error
        }
    }

    // MARK: - Internal Response Parsers (Exposed for Unit Tests)

    static func parseUsedNameLists(from raw: JSONValue?) -> [UsedNameListBucket] {
        guard let raw, !raw.isNull else { return [] }
        let itemsArray: [JSONValue]
        if let arr = raw.arrayValue {
            itemsArray = arr
        } else if let arr = raw["list"]?.arrayValue {
            itemsArray = arr
        } else if let arr = raw["data"]?.arrayValue {
            itemsArray = arr
        } else {
            return []
        }

        var buckets: [UsedNameListBucket] = []
        for elem in itemsArray {
            guard let dict = elem.objectValue else { continue }
            let cid = dict["cid"]?.coercedStringValue ?? ""
            guard !cid.isEmpty else { continue }
            let rawList = dict["nameList"]?.arrayValue ?? []
            var entries: [NameListEntry] = []
            for (idx, rawItem) in rawList.enumerated() {
                if let str = rawItem.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !str.isEmpty {
                    entries.append(NameListEntry(
                        name: str,
                        index: idx,
                        no: "\(idx + 1)",
                        status: 0,
                        fillNum: 0
                    ))
                    continue
                }
                guard let itemDict = rawItem.objectValue else { continue }
                let status = itemDict["status"]?.intValue ?? 0
                guard status != -1 else { continue }
                guard let name = (itemDict["name"]?.coercedStringValue ?? itemDict["value"]?.coercedStringValue)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                      !name.isEmpty else {
                    continue
                }
                let groupID = itemDict["groupId"]?.coercedStringValue ?? itemDict["groupID"]?.coercedStringValue ?? ""
                let groupName = itemDict["groupName"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let fillNum = itemDict["fillNum"]?.intValue ?? 0
                let no = itemDict["no"]?.coercedStringValue ?? ""
                entries.append(NameListEntry(
                    name: name,
                    groupID: groupID,
                    groupName: groupName,
                    index: idx,
                    no: no,
                    status: status,
                    fillNum: fillNum
                ))
            }
            buckets.append(UsedNameListBucket(cid: cid, entries: entries))
        }
        return buckets
    }

    static func parseSubmitResult(raw: JSONValue?, fallbackFID: String) throws -> SubmitResult {
        guard let raw, !raw.isNull else {
            return SubmitResult(fid: fallbackFID, sequence: nil, raw: nil)
        }
        var res = try raw.decode(as: SubmitResult.self)
        if res.fid.isEmpty {
            res.fid = fallbackFID
        }
        res.raw = raw
        return res
    }

    static func parseRecordList(from raw: JSONValue?) -> RecordList {
        guard let raw, !raw.isNull else {
            return RecordList(list: [], total: 0, raw: nil)
        }

        // 1. Direct JSON array (e.g., GET /v1/{id}/form_data/owner).
        if let arr = raw.arrayValue {
            let items = arr.compactMap { elem -> RecordItem? in
                guard let dict = elem.objectValue else { return nil }
                return parseRecordItem(from: dict)
            }
            return RecordList(list: items, total: items.count, raw: raw)
        }

        // 2. Object wrapper: priority list -> formDataDtoList -> dataList -> records -> single formDataDto.
        guard let obj = raw.objectValue else {
            return RecordList(list: [], total: 0, raw: raw)
        }

        var rawDicts: [[String: JSONValue]] = []
        for key in ["list", "formDataDtoList", "dataList", "records"] {
            if let arr = obj[key]?.arrayValue {
                let dicts = arr.compactMap(\.objectValue)
                if !dicts.isEmpty {
                    rawDicts = dicts
                    break
                }
            }
        }
        if rawDicts.isEmpty, let dto = obj["formDataDto"]?.objectValue, !dto.isEmpty {
            rawDicts = [dto]
        }

        let items = rawDicts.map { parseRecordItem(from: $0) }
        var total = obj["total"]?.intValue ?? 0
        if total == 0 && !items.isEmpty {
            total = items.count
        }
        return RecordList(list: items, total: total, raw: raw)
    }

    static func parseRecordItem(from dict: [String: JSONValue]) -> RecordItem {
        let fid = firstCoercedString(in: dict, keys: ["fid", "id", "formDataId"])
        let createTime = firstNonEmpty(in: dict, keys: ["createTime", "submitTime"])
        let updateTime = firstNonEmpty(in: dict, keys: ["updateTime", "modifyTime"])
        let labels = parseRecordLabels(from: dict)

        var submitter = firstCoercedString(
            in: dict,
            keys: ["submitter", "userName", "nickName", "nickname", "fname", "creatorName", "publisherNickname"]
        )
        if submitter.isEmpty, let userDict = dict["user"]?.objectValue ?? dict["userInfo"]?.objectValue {
            submitter = firstCoercedString(in: userDict, keys: ["nickName", "nickname", "fname", "name"])
        }

        var catalogs: [CatalogValue] = []
        if let catsVal = dict["catalogs"], !catsVal.isNull {
            catalogs = (try? catsVal.decode(as: [CatalogValue].self)) ?? []
        }

        return RecordItem(
            fid: fid,
            sequence: dict["sequence"],
            createTime: createTime,
            updateTime: updateTime,
            submitter: submitter,
            labels: labels,
            catalogs: catalogs,
            raw: dict
        )
    }

    static func parseRecordLabels(from dict: [String: JSONValue]) -> RecordLabels? {
        guard let lblDict = dict["labels"]?.objectValue else {
            return nil
        }
        let review = lblDict["reviewLabels"]?.arrayValue ?? []
        let revise = lblDict["reviseLabels"]?.arrayValue ?? []
        return RecordLabels(reviewLabels: review, reviseLabels: revise)
    }

    static func parseFormSummaryList(
        scope: FormListScope,
        pageNo: Int,
        pageSize: Int,
        keyword: String,
        raw: JSONValue?
    ) -> FormSummaryList {
        guard let raw, !raw.isNull else {
            return FormSummaryList(scope: scope, pageNo: pageNo, pageSize: pageSize, hasMore: false, items: [], raw: nil)
        }

        var rawItems: [[String: JSONValue]] = []
        var hasDataFlag: Bool?
        var wasGrouped = false

        if let arr = raw.arrayValue {
            rawItems = arr.compactMap(\.objectValue)
        } else if let obj = raw.objectValue {
            hasDataFlag = obj["hasData"]?.boolValue

            let keyOrder: [String]
            switch scope {
            case .participation:
                keyOrder = ["participationForms", "creations", "list", "forms", "records"]
            case .creation, .manager:
                keyOrder = ["creations", "managerForms", "participationForms", "list", "forms", "records"]
            }

            for key in keyOrder {
                guard let val = obj[key], !val.isNull else { continue }
                if let arr = val.arrayValue {
                    rawItems = arr.compactMap(\.objectValue)
                    wasGrouped = false
                    break
                } else if let grouped = val.objectValue {
                    let sortedGroupKeys = grouped.keys.sorted(by: >)
                    for groupKey in sortedGroupKeys {
                        if let groupArr = grouped[groupKey]?.arrayValue {
                            rawItems.append(contentsOf: groupArr.compactMap(\.objectValue))
                        }
                    }
                    wasGrouped = true
                    break
                }
            }
        }

        var allItems = rawItems.map { parseFormSummaryItem(from: $0) }

        // Sort grouped creations descending by createTime (tie-breaking on formID desc).
        if wasGrouped && allItems.count > 1 {
            allItems.sort { lhs, rhs in
                let ti = lhs.createTime.isEmpty ? lhs.updatedAt : lhs.createTime
                let tj = rhs.createTime.isEmpty ? rhs.updatedAt : rhs.createTime
                if ti != tj { return ti > tj }
                return lhs.formID > rhs.formID
            }
        }

        let hasMore: Bool
        if let hasDataFlag {
            hasMore = hasDataFlag
        } else {
            hasMore = allItems.count >= pageSize && !allItems.isEmpty
        }

        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let finalItems: [FormSummary]
        if kw.isEmpty {
            finalItems = allItems
        } else {
            finalItems = allItems.filter { item in
                item.title.lowercased().contains(kw)
                    || item.formID.lowercased().contains(kw)
                    || item.creatorName.lowercased().contains(kw)
                    || item.actType.lowercased().contains(kw)
            }
        }

        return FormSummaryList(
            scope: scope,
            pageNo: pageNo,
            pageSize: pageSize,
            hasMore: hasMore,
            items: finalItems,
            raw: raw
        )
    }

    private static func parseFormSummaryItem(from dict: [String: JSONValue]) -> FormSummary {
        let formID = firstCoercedString(in: dict, keys: ["formId", "id", "fid"])
        var title = firstCoercedString(in: dict, keys: ["title", "name", "activityTitle"])
        if title.isEmpty { title = formID }

        let statusVal = dict["status"]?.intValue
        let status = statusVal ?? 0
        var statusText = firstCoercedString(in: dict, keys: ["statusText"])
        if statusVal != nil {
            let mapped = ActInfo.formStatusText(status)
            if !mapped.hasPrefix("未知(") {
                statusText = mapped
            } else if statusText.isEmpty {
                statusText = mapped
            }
        }

        let actType = firstCoercedString(in: dict, keys: ["type", "formType", "actType"])
        let creatorName = firstCoercedString(
            in: dict,
            keys: ["publisherNickname", "creatorName", "publisherName", "nickName", "nickname"]
        )
        let participants = firstInt(in: dict, keys: ["participants", "participantCount", "applyCount", "joinCount"]) ?? 0

        let createTime = RecordItem.formatTimestamp(dict["createTime"])
        var updatedAt = RecordItem.formatTimestamp(dict["modifyTime"])
        if updatedAt.isEmpty { updatedAt = RecordItem.formatTimestamp(dict["updateTime"]) }
        if updatedAt.isEmpty { updatedAt = RecordItem.formatTimestamp(dict["applyTime"]) }
        if updatedAt.isEmpty { updatedAt = createTime }

        return FormSummary(
            formID: formID,
            title: title,
            status: status,
            statusText: statusText,
            actType: actType,
            creatorName: creatorName,
            participantCount: participants,
            updatedAt: updatedAt,
            createTime: createTime,
            raw: dict
        )
    }

    private static func firstCoercedString(in dict: [String: JSONValue], keys: [String]) -> String {
        for key in keys {
            if let s = dict[key]?.coercedStringValue, !s.isEmpty {
                return s
            }
        }
        return ""
    }

    private static func firstInt(in dict: [String: JSONValue], keys: [String]) -> Int? {
        for key in keys {
            if let n = dict[key]?.intValue {
                return n
            }
        }
        return nil
    }

    private static func firstNonEmpty(in dict: [String: JSONValue], keys: [String]) -> JSONValue? {
        for key in keys {
            guard let val = dict[key], !val.isNull else { continue }
            if case .string(let s) = val, s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return val
        }
        return nil
    }
}
