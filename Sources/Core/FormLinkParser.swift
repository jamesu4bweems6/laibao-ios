import Foundation

/// Errors raised while parsing or resolving a LaiBao / QunBaoShu form link.
public enum FormLinkParseError: LocalizedError, Sendable, Equatable {
    case empty
    case wechatShortLink
    case shortLinkNeedsResolve(url: URL)
    case invalidURL(String)
    case pathTraversal(String)
    case unrecognized(String)
    case redirectBlocked(String)
    case tooManyRedirects(Int)
    case resolutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "请输入表单 ID 或活动分享链接"
        case .wechatShortLink:
            return "检测到微信加密短链（#小程序://...），无法在离线环境下解码出表单 ID。请直接从「我的接龙列表」一键选择该活动，或长按识别活动海报二维码粘贴完整链接"
        case .shortLinkNeedsResolve(let url):
            return "检测到群报数/来豹短链（\(url.absoluteString)），需要联网解析重定向以提取表单 ID"
        case .invalidURL(let detail):
            return detail
        case .pathTraversal(let detail):
            return detail
        case .unrecognized(let detail):
            return detail
        case .redirectBlocked(let detail):
            return detail
        case .tooManyRedirects(let limit):
            return "短链重定向超过最大允许跳数（\(limit) 跳），无法解析表单 ID"
        case .resolutionFailed(let detail):
            return detail
        }
    }
}

/// Successfully extracted form identifier with provenance metadata.
public struct ParsedFormLink: Sendable, Equatable, Hashable {
    public let formID: String
    /// One of `"raw"`, `"url_path"`, `"url_query"`, `"url_q"`, `"url_scene"`, `"url_address"`, `"short_link"`.
    public let source: String
    public let resolvedURL: String?

    public init(formID: String, source: String, resolvedURL: String? = nil) {
        self.formID = formID
        self.source = source
        self.resolvedURL = resolvedURL
    }
}

/// Strictly blocks automatic HTTP redirects so `FormLinkParser.resolveFormID` can validate every hop against the SSRF allowlist.
private final class NoRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Offline parser and SSRF-safe short-link resolver for all LaiBao / QunBaoShu share links.
public enum FormLinkParser {
    /// All 7 known white-label brand path prefixes under `qun100.{com,net}`.
    public static let knownSharePrefixes: Set<String> = [
        "laibaoshu",
        "detail",
        "pro",
        "lanbao",
        "ssp",
        "qbsc",
        "jlyy"
    ]

    /// Strict production short-link host allowlist.
    public static let allowedShortLinkHosts: Set<String> = [
        "s.qun100.com"
    ]

    /// Strict redirect target host allowlist (official `qun100.{com,net}` domains only).
    public static let allowedRedirectTargetHosts: Set<String> = [
        "s.qun100.com",
        "www.qun100.com",
        "qun100.com",
        "www.qun100.net",
        "qun100.net"
    ]

    public static let maxShortLinkHops: Int = 3

    private static let embeddedURLPattern = #"https?://[^\s<>"'{}|\\^`，。！？、；：（）【】《》]+"#

    /// Extracts an `s.qun100.com/link/<shortCode>` URL from raw input or multi-line share text, if present.
    public static func extractShortLink(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for match in findEmbeddedURLs(in: trimmed) {
            let cleaned = trimURLTrailingPunct(match)
            guard let components = URLComponents(string: cleaned),
                  let url = components.url,
                  isShortLinkURL(components: components) else {
                continue
            }
            return url
        }
        return nil
    }

    /// Parses a raw form ID, brand URL, `launchApp?address=...`, mini-program path, query fragment,
    /// or multi-line WeChat share text offline.
    /// Never mistakes an `s.qun100.com/link/<shortCode>` short code for a `formId`; throws `.shortLinkNeedsResolve(url:)`.
    public static func parseFormID(_ input: String) throws -> ParsedFormLink {
        try parseFormIDDepth(input, depth: 0)
    }

    /// Attempts offline parsing first; if input contains an allowlisted `https://s.qun100.com/link/<shortCode>` short link,
    /// resolves up to 3 hops using a credential-free ephemeral `URLSession` with strict HTTPS port-443 SSRF checks.
    public static func resolveFormID(_ input: String, session: URLSession? = nil) async throws -> ParsedFormLink {
        do {
            return try parseFormID(input)
        } catch FormLinkParseError.shortLinkNeedsResolve(let shortURL) {
            return try await resolveShortLink(shortURL, injectedSession: session)
        } catch {
            throw error
        }
    }

    // MARK: - Short-Link Resolution (SSRF-Hardened)

    private static func resolveShortLink(_ initialURL: URL, injectedSession: URLSession?) async throws -> ParsedFormLink {
        try validateShortLinkURL(initialURL)

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        if let injectedClasses = injectedSession?.configuration.protocolClasses {
            config.protocolClasses = injectedClasses
        }

        let delegate = NoRedirectSessionDelegate()
        let ephemeralSession = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { ephemeralSession.finishTasksAndInvalidate() }

        var currentURL = initialURL

        for _ in 0..<maxShortLinkHops {
            try validateShortLinkURL(currentURL)

            var request = URLRequest(url: currentURL)
            request.httpMethod = "GET"
            request.httpShouldHandleCookies = false
            request.setValue(LaiBaoAPIClient.defaultUA, forHTTPHeaderField: "User-Agent")
            request.setValue(
                "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
                forHTTPHeaderField: "Accept"
            )

            let response: URLResponse
            do {
                (_, response) = try await ephemeralSession.data(for: request)
            } catch {
                throw FormLinkParseError.resolutionFailed("短链请求失败: \(error.localizedDescription)")
            }

            guard let httpResponse = response as? HTTPURLResponse else {
                throw FormLinkParseError.resolutionFailed("短链未返回有效的 HTTP 响应")
            }
            guard isRedirectStatus(httpResponse.statusCode) else {
                throw FormLinkParseError.resolutionFailed("短链未返回重定向（HTTP \(httpResponse.statusCode)），无法解析表单 ID")
            }

            guard let locationHeader = httpResponse.value(forHTTPHeaderField: "Location")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !locationHeader.isEmpty else {
                throw FormLinkParseError.resolutionFailed("短链重定向缺少 Location 响应头")
            }

            guard let nextURL = URL(string: locationHeader, relativeTo: currentURL)?.absoluteURL else {
                throw FormLinkParseError.invalidURL("无法解析短链重定向地址: \(locationHeader)")
            }

            try validateRedirectTargetURL(nextURL)

            do {
                let parsed = try parseFormID(nextURL.absoluteString)
                return ParsedFormLink(
                    formID: parsed.formID,
                    source: "short_link",
                    resolvedURL: nextURL.absoluteString
                )
            } catch FormLinkParseError.shortLinkNeedsResolve(let chainedURL) {
                currentURL = chainedURL
                continue
            } catch {
                throw FormLinkParseError.resolutionFailed("短链目标地址无法提取合法表单 ID: \(error.localizedDescription)")
            }
        }

        throw FormLinkParseError.tooManyRedirects(maxShortLinkHops)
    }

    private static func isRedirectStatus(_ statusCode: Int) -> Bool {
        statusCode == 301 || statusCode == 302 || statusCode == 303 || statusCode == 307 || statusCode == 308
    }

    private static func validateShortLinkURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw FormLinkParseError.invalidURL("短链地址无效")
        }
        if components.user != nil || components.password != nil {
            throw FormLinkParseError.redirectBlocked("拒绝包含用户信息（userinfo）的短链地址")
        }
        guard allowedShortLinkHosts.contains(host) else {
            throw FormLinkParseError.redirectBlocked("拒绝解析非白名单短链域名: \(host)")
        }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "https" else {
            throw FormLinkParseError.redirectBlocked("短链解析仅允许 HTTPS 协议，拒绝: \(scheme)")
        }
        if let port = components.port, port != 443 {
            throw FormLinkParseError.redirectBlocked("短链解析拒绝非默认端口: \(port)")
        }
        if hasURLPathTraversal(rawURL: url.absoluteString, components: components) {
            throw FormLinkParseError.pathTraversal("短链路径包含非法穿越字符: \(components.percentEncodedPath)")
        }
        let rawPath = components.percentEncodedPath
        guard rawPath.lowercased().hasPrefix("/link/") else {
            throw FormLinkParseError.invalidURL("短链路径必须以 /link/ 开头且包含短码: \(rawPath)")
        }
        let codePart = String(rawPath.dropFirst("/link/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !codePart.isEmpty else {
            throw FormLinkParseError.invalidURL("短链路径必须以 /link/ 开头且包含短码: \(rawPath)")
        }
    }

    private static func validateRedirectTargetURL(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw FormLinkParseError.invalidURL("短链重定向目标无效")
        }
        if components.user != nil || components.password != nil {
            throw FormLinkParseError.redirectBlocked("拒绝重定向至包含用户信息（userinfo）的地址")
        }
        guard allowedRedirectTargetHosts.contains(host) else {
            throw FormLinkParseError.redirectBlocked("拒绝重定向至非白名单域名: \(host)")
        }
        let scheme = components.scheme?.lowercased() ?? ""
        guard scheme == "https" else {
            throw FormLinkParseError.redirectBlocked("拒绝重定向降级至非 HTTPS 协议: \(scheme)")
        }
        if let port = components.port, port != 443 {
            throw FormLinkParseError.redirectBlocked("拒绝重定向至非默认端口: \(port)")
        }
        if hasURLPathTraversal(rawURL: url.absoluteString, components: components) {
            throw FormLinkParseError.pathTraversal("重定向目标路径包含非法穿越字符: \(components.percentEncodedPath)")
        }
    }

    // MARK: - Core Offline Parsing

    private static func parseFormIDDepth(_ input: String, depth: Int) throws -> ParsedFormLink {
        guard depth <= 3 else {
            throw FormLinkParseError.unrecognized("链接嵌套层级过深，无法解析表单 ID")
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw FormLinkParseError.empty
        }

        // 1. Prefer embedded http(s):// URLs (supports multi-line WeChat share text).
        let embedded = findEmbeddedURLs(in: trimmed)
        if !embedded.isEmpty {
            var lastError: Error?
            var shortLinkError: FormLinkParseError?
            for match in embedded {
                let cleaned = trimURLTrailingPunct(match)
                do {
                    return try parseFormIDFromURL(cleaned, depth: depth)
                } catch let err as FormLinkParseError {
                    if case .shortLinkNeedsResolve = err {
                        shortLinkError = err
                    }
                    lastError = err
                } catch {
                    lastError = error
                }
            }
            if let shortLinkError {
                throw shortLinkError
            }
            if trimmed.contains("#小程序://") {
                throw FormLinkParseError.wechatShortLink
            }
            if let err = lastError {
                throw err
            }
        }

        // 2. Detect WeChat encrypted mini-program short link (#小程序://...).
        if trimmed.contains("#小程序://") {
            throw FormLinkParseError.wechatShortLink
        }

        // 3. Mini-program internal paths or query fragments:
        //    /subPackages/activityDetail/detail/share/7321247?&formId=1911520788713021441
        //    /subPackages/activityDetail/pages/detail/main?formId=6543210
        //    ?formId=6543210 / q=... / scene=6543210,ACTIVITY_V2
        if trimmed.contains("?") || looksLikeFormQuery(trimmed) {
            var queryPart = trimmed
            if let qIndex = trimmed.firstIndex(of: "?") {
                let pathPart = String(trimmed[..<qIndex])
                if hasTraversalInValue(pathPart) || pathPart.lowercased().contains("%2f") {
                    throw FormLinkParseError.pathTraversal("路径包含非法穿越字符: \(input)")
                }
                queryPart = String(trimmed[trimmed.index(after: qIndex)...])
            }
            if let hashIndex = queryPart.firstIndex(of: "#") {
                queryPart = String(queryPart[..<hashIndex])
            }
            while queryPart.hasPrefix("&") {
                queryPart.removeFirst()
            }
            if let parsed = try extractFromQueryString(queryPart, depth: depth) {
                return parsed
            }
        }

        // 4. Raw formId (strip wrapping quotes only; never strip / \ . so traversal is caught).
        let candidate = trimWrappingQuotes(trimmed)
        if hasTraversalInValue(candidate) || candidate.contains("/") || candidate.contains("\\") {
            throw FormLinkParseError.pathTraversal("表单 ID 包含非法路径字符: \(candidate)")
        }
        do {
            _ = try LaiBaoAPIClient.validatePathID(candidate)
            return ParsedFormLink(formID: candidate, source: "raw")
        } catch {
            throw FormLinkParseError.unrecognized("无效的表单 ID: \(error.localizedDescription)")
        }
    }

    private static func parseFormIDFromURL(_ rawURL: String, depth: Int) throws -> ParsedFormLink {
        guard let components = URLComponents(string: rawURL),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host?.lowercased(), !host.isEmpty else {
            throw FormLinkParseError.invalidURL("不支持的链接格式: \(rawURL)")
        }

        // Block path traversal across raw, percent-encoded, and multi-layer decoded path forms.
        if hasURLPathTraversal(rawURL: rawURL, components: components) {
            throw FormLinkParseError.pathTraversal("链接路径包含非法穿越字符: \(rawURL)")
        }

        // Recognize s.qun100.com/link/<shortCode> and NEVER treat shortCode as formId.
        // Also reject malformed paths on s.qun100.com (e.g., //link/<code>, /foo/<code>, /link/).
        if isShortLinkURL(components: components), let url = components.url {
            throw FormLinkParseError.shortLinkNeedsResolve(url: url)
        }
        if host == "s.qun100.com" {
            throw FormLinkParseError.invalidURL("无效的短链路径: \(rawURL)（仅支持 https://s.qun100.com/link/<shortCode>）")
        }

        // Check query parameters (using percentEncodedQuery to preserve encoded & and = inside nested values).
        if let rawQuery = components.percentEncodedQuery, !rawQuery.isEmpty {
            if let parsed = try extractFromQueryString(rawQuery, depth: depth) {
                return parsed
            }
        }

        // Check hash-route query parameters (e.g., #/detail?formId=...).
        if let rawFragment = components.percentEncodedFragment,
           let qIdx = rawFragment.firstIndex(of: "?") {
            let fragQuery = String(rawFragment[rawFragment.index(after: qIdx)...])
            if let parsed = try extractFromQueryString(fragQuery, depth: depth) {
                return parsed
            }
        }

        let isQun100Host = host != "s.qun100.com" && (
            host == "qun100.com" || host.hasSuffix(".qun100.com")
                || host == "qun100.net" || host.hasSuffix(".qun100.net")
        )

        let segments = components.path
            .split(separator: "/")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if segments.count >= 2 {
            let firstLower = segments[0].lowercased()
            // /v1/form/<id>, /v2/form/<id>, /v3/form/<id>
            if (firstLower == "v1" || firstLower == "v2" || firstLower == "v3"),
               segments.count >= 3,
               segments[1].lowercased() == "form" {
                let candidate = segments[2]
                try validateExtractedFormID(candidate)
                return ParsedFormLink(formID: candidate, source: "url_path")
            }
            // Known white-label brand paths: /<brand>/<prefix>/<formId> or /<brand>/<formId>
            if knownSharePrefixes.contains(firstLower), let candidate = segments.last {
                try validateExtractedFormID(candidate)
                return ParsedFormLink(formID: candidate, source: "url_path")
            }
            // Fallback for other qun100.{com,net} paths: take final segment.
            if isQun100Host, let candidate = segments.last {
                try validateExtractedFormID(candidate)
                return ParsedFormLink(formID: candidate, source: "url_path")
            }
        }

        throw FormLinkParseError.unrecognized(
            "无法从该链接中提取表单 ID（支持 qun100.com / qun100.net 活动链接、s.qun100.com 短链或含 formId / address / q / scene 参数的链接）"
        )
    }

    private static func extractFromQueryString(_ rawQuery: String, depth: Int) throws -> ParsedFormLink? {
        let pairs = parseQueryPairs(rawQuery)

        func value(forAny names: [String]) -> String? {
            let loweredNames = names.map { $0.lowercased() }
            for want in names {
                if let pair = pairs.first(where: { $0.key == want }), !pair.value.isEmpty {
                    return pair.value
                }
            }
            for pair in pairs {
                if loweredNames.contains(pair.key.lowercased()), !pair.value.isEmpty {
                    return pair.value
                }
            }
            return nil
        }

        // 1. `q`: full URL scanned via WeChat QR code.
        if let qVal = value(forAny: ["q"]) {
            let decoded = percentDecodeQueryComponent(qVal) ?? qVal
            let parsed = try parseFormIDDepth(decoded, depth: depth + 1)
            return ParsedFormLink(formID: parsed.formID, source: "url_q")
        }

        // 2. `address`: launchApp?type=<p>&address=<encodeURIComponent(miniPath)> (supports single & double encoding).
        if let addrVal = value(forAny: ["address"]) {
            if hasTraversalInValue(addrVal) {
                throw FormLinkParseError.pathTraversal("address 参数包含非法路径穿越字符")
            }
            var decoded = addrVal
            if !decoded.contains("?") && !decoded.contains("=") && decoded.contains("%") {
                if let unesc = percentDecodeQueryComponent(decoded), !unesc.isEmpty, unesc != decoded {
                    if hasTraversalInValue(unesc) {
                        throw FormLinkParseError.pathTraversal("address 参数包含非法路径穿越字符")
                    }
                    decoded = unesc
                }
            }
            // Extra decode probe to block deeper-encoded traversal payloads (e.g., %25252e).
            var probe = decoded
            for _ in 0..<2 where probe.contains("%") {
                guard let unesc = percentDecodeQueryComponent(probe), unesc != probe else { break }
                if hasTraversalInValue(unesc) {
                    throw FormLinkParseError.pathTraversal("address 参数包含非法路径穿越字符")
                }
                probe = unesc
            }
            let parsed = try parseFormIDDepth(decoded, depth: depth + 1)
            return ParsedFormLink(formID: parsed.formID, source: "url_address")
        }

        // 3. Explicit `formId` / `formid` / `form_id`.
        if let fid = value(forAny: ["formId", "formid", "form_id"]) {
            try validateExtractedFormID(fid)
            return ParsedFormLink(formID: fid, source: "url_query")
        }

        // 4. `scene`: `"<formId>,<formType>"`.
        if let sceneVal = value(forAny: ["scene"]) {
            let decoded = percentDecodeQueryComponent(sceneVal) ?? sceneVal
            let first = decoded.split(separator: ",", omittingEmptySubsequences: false)
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            try validateExtractedFormID(first)
            return ParsedFormLink(formID: first, source: "url_scene")
        }

        // 5. Generic `id` fallback.
        if let idVal = value(forAny: ["id"]) {
            try validateExtractedFormID(idVal)
            return ParsedFormLink(formID: idVal, source: "url_query")
        }

        if hasTraversalInValue(rawQuery) {
            throw FormLinkParseError.pathTraversal("查询参数包含非法路径穿越字符")
        }
        return nil
    }

    // MARK: - Validation & Helper Utilities

    private static func validateExtractedFormID(_ candidate: String) throws {
        if hasTraversalInValue(candidate) || candidate.contains("/") || candidate.contains("\\") {
            throw FormLinkParseError.pathTraversal("链接中的表单 ID 包含非法路径字符: \(candidate)")
        }
        do {
            _ = try LaiBaoAPIClient.validatePathID(candidate)
        } catch {
            throw FormLinkParseError.invalidURL("链接中的表单 ID 非法: \(error.localizedDescription)")
        }
    }

    private static func isShortLinkURL(components: URLComponents) -> Bool {
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              allowedShortLinkHosts.contains(host) else {
            return false
        }
        let rawPath = components.percentEncodedPath
        guard rawPath.lowercased().hasPrefix("/link/") else {
            return false
        }
        let rest = String(rawPath.dropFirst("/link/".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        return !rest.isEmpty
    }

    private static func hasURLPathTraversal(rawURL: String, components: URLComponents) -> Bool {
        func checkLayer(_ value: String) -> Bool {
            let lower = value.lowercased()
            return value.contains("..")
                || value.contains("\\")
                || lower.contains("%2e")
                || lower.contains("%2f")
                || lower.contains("%5c")
        }

        if checkLayer(components.percentEncodedPath) || checkLayer(components.path) {
            return true
        }

        // Also inspect the raw path substring before `?` / `#` directly in case URLComponents normalized anything.
        if let schemeRange = rawURL.range(of: "://") {
            let afterScheme = rawURL[schemeRange.upperBound...]
            if let slashIdx = afterScheme.firstIndex(of: "/") {
                var rawPath = afterScheme[slashIdx...]
                if let qIdx = rawPath.firstIndex(of: "?") {
                    rawPath = rawPath[..<qIdx]
                }
                if let hIdx = rawPath.firstIndex(of: "#") {
                    rawPath = rawPath[..<hIdx]
                }
                if checkLayer(String(rawPath)) {
                    return true
                }
            }
        }

        // Iteratively unescape up to 3 layers to catch double/triple-encoded traversal (%252e%252e, %255c, etc.).
        var current = components.percentEncodedPath
        for _ in 0..<3 where current.contains("%") {
            guard let unescaped = current.removingPercentEncoding, unescaped != current else {
                break
            }
            if checkLayer(unescaped) {
                return true
            }
            current = unescaped
        }
        return false
    }

    private static func hasTraversalInValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        return value.contains("..")
            || value.contains("\\")
            || lower.contains(".%2e")
            || lower.contains("%2e.")
            || lower.contains("%2e%2e")
            || lower.contains("%5c")
    }

    private static func findEmbeddedURLs(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: embeddedURLPattern, options: []) else {
            return []
        }
        let nsText = text as NSString
        let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
        return matches.map { nsText.substring(with: $0.range) }
    }

    private static func trimURLTrailingPunct(_ raw: String) -> String {
        var str = raw
        let trailingPunct: Set<Character> = [",", ";", ":", "!", "?", ")", "'", "\"", "]"]
        while let last = str.last {
            if last == "." {
                if str.hasSuffix("..") || str.hasSuffix("/.") {
                    break
                }
                str.removeLast()
                continue
            }
            if trailingPunct.contains(last) {
                str.removeLast()
                continue
            }
            break
        }
        return str
    }

    private static func trimWrappingQuotes(_ input: String) -> String {
        var str = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(String, String)] = [
            ("\"", "\""),
            ("'", "'"),
            ("「", "」"),
            ("『", "』"),
            ("“", "”"),
            ("‘", "’")
        ]
        for (open, close) in pairs {
            if str.hasPrefix(open), str.hasSuffix(close), str.count > open.count + close.count {
                str = String(str.dropFirst(open.count).dropLast(close.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return str
    }

    private static func looksLikeFormQuery(_ input: String) -> Bool {
        let lower = input.lowercased()
        let prefixes = ["formid=", "form_id=", "q=", "scene=", "id=", "address="]
        return prefixes.contains { lower.hasPrefix($0) }
    }

    private static func parseQueryPairs(_ rawQuery: String) -> [(key: String, value: String)] {
        var results: [(key: String, value: String)] = []
        for segment in rawQuery.split(separator: "&", omittingEmptySubsequences: true) {
            let part = String(segment)
            if let eqIdx = part.firstIndex(of: "=") {
                let rawKey = String(part[..<eqIdx])
                let rawVal = String(part[part.index(after: eqIdx)...])
                let key = (percentDecodeQueryComponent(rawKey) ?? rawKey).trimmingCharacters(in: .whitespacesAndNewlines)
                let val = (percentDecodeQueryComponent(rawVal) ?? rawVal).trimmingCharacters(in: .whitespacesAndNewlines)
                results.append((key: key, value: val))
            } else {
                let key = (percentDecodeQueryComponent(part) ?? part).trimmingCharacters(in: .whitespacesAndNewlines)
                results.append((key: key, value: ""))
            }
        }
        return results
    }

    private static func percentDecodeQueryComponent(_ raw: String) -> String? {
        raw.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }
}
