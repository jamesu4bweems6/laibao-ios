import Foundation
import XCTest
@testable import LaiBao

private final class ShortLinkMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?
    private nonisolated(unsafe) static var hitCount: Int = 0

    static func configure(_ newHandler: @escaping @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
        hitCount = 0
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
        hitCount = 0
    }

    static func currentHitCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return hitCount
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentHandler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            Self.hitCount += 1
            return Self.handler
        }()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        do {
            let (response, data) = try currentHandler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

final class FormLinkParserTests: XCTestCase {
    override func tearDown() {
        ShortLinkMockURLProtocol.reset()
        super.tearDown()
    }

    func testParseAllSevenBrandURLsAndShareFormats() throws {
        let cases: [(input: String, expectedID: String, expectedSource: String)] = [
            ("  6543210  ", "6543210", "raw"),
            ("「form_abc-123」", "form_abc-123", "raw"),
            ("https://www.qun100.com/laibaoshu/0p/6543210?type=3", "6543210", "url_path"),
            ("https://www.qun100.net/detail/0b/9876543?type=1", "9876543", "url_path"),
            ("https://www.qun100.com/pro/0p/111222?type=2", "111222", "url_path"),
            ("https://www.qun100.com/lanbao/0p/445566?type=5", "445566", "url_path"),
            ("https://www.qun100.net/ssp/0a/334455?type=4", "334455", "url_path"),
            ("https://www.qun100.com/qbsc/0p/667788?type=6", "667788", "url_path"),
            ("https://www.qun100.com/jlyy/123p/778899?type=7", "778899", "url_path"),
            ("【每日签到打卡】\n请点击链接参与：（https://www.qun100.com/laibaoshu/0p/556677?type=3）。\n截止今日 18:00", "556677", "url_path"),
            ("https://www.qun100.com/pages/detail?formId=246810&foo=bar", "246810", "url_query"),
            ("/subPackages/activityDetail/pages/detail/main?formId=135790", "135790", "url_query"),
            ("/subPackages/activityDetail/detail/share/7321247?&formId=1911520788713021441", "1911520788713021441", "url_query"),
            ("https://www.qun100.com/open?q=https%3A%2F%2Fwww.qun100.com%2Flaibaoshu%2F0p%2F314159%3Ftype%3D3", "314159", "url_q"),
            ("https://www.qun100.com/open?scene=888999%2CACTIVITY_V2", "888999", "url_scene"),
            ("https://form.qun100.com/v3/form/f100", "f100", "url_path"),
            ("https://www.qun100.com/share?id=112233", "112233", "url_query"),
            ("#小程序://来豹接龙/AbCdEf\nhttps://www.qun100.com/lanbao/0p/445566?type=5", "445566", "url_path"),
            ("https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2FactivityDetail%2Fdetail%2Fshare%2F7321247%3F%26formId%3D1911520788713021441", "1911520788713021441", "url_address"),
            ("https://www.qun100.net/launchApp?type=1&address=%2FsubPackages%2FactivityDetail%2Fpages%2Fdetail%2Fmain%3Fscene%3D888999%252CACTIVITY_V2", "888999", "url_address"),
            ("https://www.qun100.com/launchApp?type=3&address=%252FsubPackages%252FactivityDetail%252Fdetail%252Fshare%252F7321247%253F%2526formId%253D1911520788713021441", "1911520788713021441", "url_address")
        ]

        for testCase in cases {
            let parsed = try FormLinkParser.parseFormID(testCase.input)
            XCTAssertEqual(parsed.formID, testCase.expectedID, "Mismatch for input: \(testCase.input)")
            XCTAssertEqual(parsed.source, testCase.expectedSource, "Source mismatch for input: \(testCase.input)")
        }
    }

    func testShortLinkNeedsResolveAndMalformedShortHostRejected() {
        let shortInputs = [
            "https://s.qun100.com/link/anWmr0eO8Hb",
            "https://S.QUN100.COM/link/anWmr0eO8Hb",
            "【每日打卡接龙】\n点击链接参与：https://s.qun100.com/link/anWmr0eO8Hb。\n感谢配合",
            "打卡通知\nhttps://s.qun100.com/link/anWmr0eO8Hb\n#小程序://来豹接龙/AbCdEf"
        ]

        for input in shortInputs {
            XCTAssertThrowsError(try FormLinkParser.parseFormID(input)) { error in
                guard case FormLinkParseError.shortLinkNeedsResolve(let url) = error else {
                    XCTFail("Expected shortLinkNeedsResolve for \(input), got \(error)")
                    return
                }
                XCTAssertTrue(url.absoluteString.hasSuffix("/link/anWmr0eO8Hb"))
            }
            XCTAssertNotNil(FormLinkParser.extractShortLink(from: input))
        }

        // Malformed paths on s.qun100.com must be rejected (never treated as formId or valid short link).
        for malformed in [
            "https://s.qun100.com//link/anWmr0eO8Hb",
            "https://s.qun100.com/foo/anWmr0eO8Hb",
            "https://s.qun100.com/link/"
        ] {
            XCTAssertThrowsError(try FormLinkParser.parseFormID(malformed)) { error in
                if case FormLinkParseError.shortLinkNeedsResolve = error {
                    XCTFail("Malformed s.qun100.com path must NOT trigger shortLinkNeedsResolve: \(malformed)")
                }
            }
        }
    }

    func testWeChatShortLinkGuidance() {
        for input in [
            "#小程序://来豹接龙/xYz123AbC",
            "快来接龙打卡\n#小程序://群报数/9kLmNoPqRs"
        ] {
            XCTAssertThrowsError(try FormLinkParser.parseFormID(input)) { error in
                XCTAssertEqual(error as? FormLinkParseError, .wechatShortLink)
                XCTAssertTrue(error.localizedDescription.contains("我的接龙列表"))
            }
        }
    }

    func testMultiLayerPathTraversalBlocked() {
        let badInputs = [
            "",
            "   ",
            "../secret",
            "a\\b",
            "foo/bar",
            "id\u{0000}bad",
            "https://www.qun100.com/laibaoshu/0p/..",
            "https://www.qun100.com/laibaoshu/0p/..%2Fadmin",
            "https://www.qun100.com/laibaoshu/0p/%252e%252e/123",
            "https://www.qun100.com/launchApp/%252e%252e/x?type=3&address=%2FsubPackages%2FactivityDetail%2Fdetail%2Fshare%2F7321247%3F%26formId%3D1911520788713021441",
            "https://www.qun100.com/laibaoshu/.%2e/secret",
            "https://www.qun100.com/laibaoshu/%2e./secret",
            "https://www.qun100.com/laibaoshu/%5cadmin",
            "https://www.qun100.com/open?formId=../etc/passwd",
            "https://www.qun100.com/open?scene=..%2Fbad,ACTIVITY_V2",
            "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F..%2Fsecret%3FformId%3D123",
            "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F.%252e%2Fsecret%3FformId%3D123",
            "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F%252e.%2Fsecret%3FformId%3D123",
            "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F%5csecret%3FformId%3D123",
            "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F%255csecret%3FformId%3D123",
            "https://www.qun100.com/launchApp?type=3&address=%252FsubPackages%252F.%25252e%252Fsecret%253FformId%253D123",
            "/subPackages/../secret?formId=123",
            "https://s.qun100.com/link/..%2fadmin",
            "https://example.com/unrelated/page"
        ]

        for bad in badInputs {
            XCTAssertThrowsError(try FormLinkParser.parseFormID(bad), "Should reject bad input: \(bad)")
        }
    }

    func testResolveShortLinkWithMockedURLProtocolAndSSRFGuards() async throws {
        let launchLocation = "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2FactivityDetail%2Fdetail%2Fshare%2F7321247%3F%26formId%3D1911520788713021441"

        ShortLinkMockURLProtocol.configure { request in
            guard let url = request.url else {
                throw URLError(.badURL)
            }
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))

            func redirect(_ status: Int, to location: String) -> (HTTPURLResponse, Data) {
                let resp = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Location": location]
                )!
                return (resp, Data())
            }

            switch url.path {
            case "/link/anWmr0eO8Hb":
                return redirect(302, to: launchLocation)
            case "/link/hop1":
                return redirect(301, to: "/link/hop2")
            case "/link/hop2":
                return redirect(302, to: launchLocation)
            case "/link/loop":
                return redirect(302, to: "/link/loop")
            case "/link/evil":
                return redirect(302, to: "https://evil.example.com/launchApp?formId=1911520788713021441")
            case "/link/downgrade":
                return redirect(302, to: "http://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2FactivityDetail%2Fdetail%2Fshare%2F7321247%3F%26formId%3D1911520788713021441")
            case "/link/badport":
                return redirect(302, to: "https://www.qun100.com:8443/launchApp?type=3&address=%2FsubPackages%2FactivityDetail%2Fdetail%2Fshare%2F7321247%3F%26formId%3D1911520788713021441")
            case "/link/badaddr":
                return redirect(302, to: "https://www.qun100.com/launchApp?type=3&address=%2FsubPackages%2F..%2Fsecret%3FformId%3D123")
            case "/link/no_redirect":
                let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data("ok".utf8))
            default:
                let resp = HTTPURLResponse(url: url, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
                return (resp, Data())
            }
        }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ShortLinkMockURLProtocol.self]
        let mockSession = URLSession(configuration: config)

        // 1. Offline URL resolves with 0 network requests.
        let offline = try await FormLinkParser.resolveFormID(launchLocation, session: mockSession)
        XCTAssertEqual(offline.formID, "1911520788713021441")
        XCTAssertEqual(offline.source, "url_address")
        XCTAssertNil(offline.resolvedURL)
        XCTAssertEqual(ShortLinkMockURLProtocol.currentHitCount(), 0)

        // 2. Single-hop 302 short link in multi-line share text.
        let singleHop = try await FormLinkParser.resolveFormID(
            "【打卡】\nhttps://s.qun100.com/link/anWmr0eO8Hb。",
            session: mockSession
        )
        XCTAssertEqual(singleHop.formID, "1911520788713021441")
        XCTAssertEqual(singleHop.source, "short_link")
        XCTAssertEqual(singleHop.resolvedURL, launchLocation)

        // 3. Two-hop relative redirect within allowlist.
        let twoHop = try await FormLinkParser.resolveFormID(
            "https://s.qun100.com/link/hop1",
            session: mockSession
        )
        XCTAssertEqual(twoHop.formID, "1911520788713021441")
        XCTAssertEqual(twoHop.source, "short_link")

        // 4. Pre-flight SSRF blocks must make ZERO network hits.
        let hitsBefore = ShortLinkMockURLProtocol.currentHitCount()
        for preflightBlocked in [
            "http://s.qun100.com/link/anWmr0eO8Hb",
            "https://s.qun100.com:8443/link/anWmr0eO8Hb",
            "https://evil.example.com/link/abc",
            "https://s.qun100.com//link/anWmr0eO8Hb",
            "https://s.qun100.com/link/..%2fadmin"
        ] {
            do {
                _ = try await FormLinkParser.resolveFormID(preflightBlocked, session: mockSession)
                XCTFail("Expected pre-flight SSRF rejection for \(preflightBlocked)")
            } catch {
                // Expected.
            }
        }
        XCTAssertEqual(ShortLinkMockURLProtocol.currentHitCount(), hitsBefore)

        // 5. Post-hop SSRF / downgrade / port / traversal / loop / 200 rejections.
        for postHopBlocked in [
            "https://s.qun100.com/link/evil",
            "https://s.qun100.com/link/downgrade",
            "https://s.qun100.com/link/badport",
            "https://s.qun100.com/link/badaddr",
            "https://s.qun100.com/link/loop",
            "https://s.qun100.com/link/no_redirect"
        ] {
            do {
                _ = try await FormLinkParser.resolveFormID(postHopBlocked, session: mockSession)
                XCTFail("Expected post-hop rejection for \(postHopBlocked)")
            } catch {
                // Expected.
            }
        }
    }
}
