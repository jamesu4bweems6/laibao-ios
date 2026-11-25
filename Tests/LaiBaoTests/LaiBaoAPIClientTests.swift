import Foundation
import XCTest
@testable import LaiBao

private final class APIClientMockURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var handler: (@Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data))?

    static func configure(_ newHandler: @escaping @Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handler = newHandler
    }

    static func reset() {
        lock.lock()
        defer { lock.unlock() }
        handler = nil
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentHandler: (@Sendable (URLRequest, Data?) throws -> (HTTPURLResponse, Data))? = {
            Self.lock.lock()
            defer { Self.lock.unlock() }
            return Self.handler
        }()

        guard let currentHandler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }

        let bodyData = Self.extractBody(from: request)
        do {
            let (response, data) = try currentHandler(request, bodyData)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func extractBody(from request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int = 0

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        value = 0
    }

    func current() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class LaiBaoAPIClientTests: XCTestCase {
    override func tearDown() {
        APIClientMockURLProtocol.reset()
        super.tearDown()
    }

    private func makeMockClient(
        baseURL: String = "https://form.qun100.com",
        token: String = "tok-test-123456"
    ) -> LaiBaoAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [APIClientMockURLProtocol.self]
        let session = URLSession(configuration: config)
        return LaiBaoAPIClient(baseURL: baseURL, token: token, session: session)
    }

    private static func jsonResponse(url: URL, status: Int = 200, body: String) -> (HTTPURLResponse, Data) {
        let resp = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        return (resp, Data(body.utf8))
    }

    func testServerTimeEpochMillisFallbackAndNoStoreHeader() async throws {
        let counter = LockedCounter()
        APIClientMockURLProtocol.configure { request, _ in
            XCTAssertEqual(request.url?.path, "/v1/server-time")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            let call = counter.increment()
            if call == 1 {
                return Self.jsonResponse(url: request.url!, body: #"{"code":0,"data":{"epochMillis":1763900000123}}"#)
            } else {
                return Self.jsonResponse(url: request.url!, body: #"{"code":0,"data":{"serverTime":1763900000456}}"#)
            }
        }

        let client = makeMockClient()
        let ts1 = try await client.serverTime()
        XCTAssertEqual(ts1, 1_763_900_000_123)

        let ts2 = try await client.serverTime()
        XCTAssertEqual(ts2, 1_763_900_000_456)
    }

    func testLoginByCodeMinimalHeadersAndDualTokenKeys() async throws {
        let counter = LockedCounter()
        APIClientMockURLProtocol.configure { request, _ in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/v4/login")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ver"), LaiBaoAPIClient.defaultVer)
            XCTAssertNil(request.value(forHTTPHeaderField: "Client-App-Id"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if counter.increment() == 1 {
                return Self.jsonResponse(url: request.url!, body: #"{"code":0,"data":{"token":"tok-primary","fuid":"u1"}}"#)
            } else {
                return Self.jsonResponse(url: request.url!, body: #"{"code":0,"data":{"wxLoginAccessToken":"tok-legacy","fuid":"u2"}}"#)
            }
        }

        let client = makeMockClient(token: "existing-should-not-send")
        let res1 = try await client.loginByCode("wx-code-1")
        XCTAssertEqual(res1.token, "tok-primary")
        XCTAssertEqual(res1.fuid, "u1")

        let res2 = try await client.loginByCode("wx-code-2")
        XCTAssertEqual(res2.token, "tok-legacy")
        XCTAssertEqual(res2.fuid, "u2")
    }

    func testMyRecordsOwnerFallbackFormDataDtoList13362AndLastRecord() async throws {
        let authCalls = LockedCounter()
        let page2Calls = LockedCounter()

        APIClientMockURLProtocol.configure { request, _ in
            let url = request.url!
            switch url.path {
            case "/v1/f_ok/form_data/owner":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Form-Id"), "f_ok")
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":[{"fid":"my-1","sequence":1,"createTime":"2026-11-23 08:00","catalogs":[{"cid":"11","type":"WORD","value":"正常"}]}]}"#
                )

            case "/v1/f_shop/form_data/owner":
                return Self.jsonResponse(url: url, body: #"{"code":13362,"message":"no records"}"#)
            case "/v3/f_shop/form_data":
                XCTAssertNil(url.query)
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"formDataDtoList":[{"fid":"shop-1","sequence":5,"createTime":1763856000000,"catalogs":[{"cid":"1","type":"WORD","value":"团购1"}]}]}}"#
                )

            case "/v1/f_lastonly/form_data/owner":
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":[]}"#)
            case "/v3/f_lastonly/form_data":
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":{"formDataDtoList":[]}}"#)
            case "/v1/f_lastonly/form_data/last":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"formDataDto":{"fid":"last-only-1","sequence":9,"submitTime":"2026-11-23 12:00","catalogs":[{"cid":"2","type":"WORD","value":"兜底记录"}]}}}"#
                )

            case "/v1/f_empty/form_data/owner", "/v3/f_empty/form_data", "/v1/f_empty/form_data/last":
                return Self.jsonResponse(url: url, body: #"{"code":13362,"message":"empty"}"#)

            case "/v1/f_auth/form_data/owner":
                _ = authCalls.increment()
                return Self.jsonResponse(url: url, status: 401, body: #"{"code":13686,"message":"expired"}"#)
            case "/v3/f_auth/form_data", "/v1/f_auth/form_data/last":
                _ = authCalls.increment()
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":[]}"#)

            case "/v1/f_page2/form_data/owner":
                _ = page2Calls.increment()
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":[]}"#)
            case "/v3/f_page2/form_data", "/v1/f_page2/form_data/last":
                _ = page2Calls.increment()
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":{"formDataDtoList":[{"fid":"should-not-hit"}]}}"#)

            case "/v3/f_all/form_datas":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"total":1,"list":[{"fid":"all-1","sequence":10,"nickName":"张三","labels":{"reviewLabels":["已审核"],"reviseLabels":["可修改"]}}]}}"#
                )

            default:
                return Self.jsonResponse(url: url, status: 404, body: #"{"code":404,"message":"not found"}"#)
            }
        }

        let client = makeMockClient()

        let okList = try await client.myRecords(formID: "f_ok", pageNo: 1, pageSize: 10)
        XCTAssertEqual(okList.list.count, 1)
        XCTAssertEqual(okList.list.first?.fid, "my-1")

        let shopList = try await client.myRecords(formID: "f_shop", pageNo: 1, pageSize: 10)
        XCTAssertEqual(shopList.list.count, 1)
        XCTAssertEqual(shopList.list.first?.fid, "shop-1")

        let lastOnly = try await client.myRecords(formID: "f_lastonly", pageNo: 1, pageSize: 10)
        XCTAssertEqual(lastOnly.list.count, 1)
        XCTAssertEqual(lastOnly.list.first?.fid, "last-only-1")

        let emptyList = try await client.myRecords(formID: "f_empty", pageNo: 1, pageSize: 10)
        XCTAssertTrue(emptyList.list.isEmpty)
        let emptyLast = try await client.lastRecord(formID: "f_empty")
        XCTAssertNil(emptyLast)

        let unwrappedLast = try await client.lastRecord(formID: "f_lastonly")
        XCTAssertEqual(unwrappedLast?.fid, "last-only-1")
        XCTAssertEqual(unwrappedLast?.sequenceText, "9")

        // Fatal auth error must short-circuit on call 1.
        do {
            _ = try await client.myRecords(formID: "f_auth", pageNo: 1, pageSize: 10)
            XCTFail("Expected session expired error")
        } catch let apiErr as APIError {
            XCTAssertTrue(apiErr.isSessionExpired)
        }
        XCTAssertEqual(authCalls.current(), 1)

        // Page 2 empty must not fallback.
        let p2 = try await client.myRecords(formID: "f_page2", pageNo: 2, pageSize: 10)
        XCTAssertTrue(p2.list.isEmpty)
        XCTAssertEqual(page2Calls.current(), 1)

        // All records with labels.
        let all = try await client.allRecords(formID: "f_all", pageNo: 1, pageSize: 10)
        XCTAssertEqual(all.total, 1)
        XCTAssertEqual(all.list.first?.submitter, "张三")
        XCTAssertEqual(all.list.first?.labels?.reviewLabels.count, 1)
        XCTAssertEqual(all.list.first?.labels?.reviseLabels.count, 1)
    }

    func testUpdateStripsPatchFieldsAndHandlesHTTP204() async throws {
        APIClientMockURLProtocol.configure { request, bodyData in
            XCTAssertEqual(request.httpMethod, "PUT")
            XCTAssertEqual(request.url?.path, "/v2/formA/form_data")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Form-Id"), "formA")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source-Brand"), LaiBaoAPIClient.defaultSourceBrand)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source-Platform"), LaiBaoAPIClient.defaultSourcePlatform)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source-System"), LaiBaoAPIClient.defaultSourceSystem)
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-Source-Platform-Type"), LaiBaoAPIClient.defaultSourcePlatformType)

            let parsedBody = try JSONValue.parse(from: bodyData ?? Data())
            XCTAssertNil(parsedBody["patch"])
            XCTAssertNil(parsedBody["patchDate"])
            XCTAssertNil(parsedBody["patchTimeSection"])
            XCTAssertEqual(parsedBody["fid"]?.stringValue, "fid-edit-1")

            let resp = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (resp, Data())
        }

        let client = makeMockClient()
        let payload = SubmitPayload(
            fid: "fid-edit-1",
            catalogs: [CatalogValue(cid: "1", type: "WORD", value: .string("已修改"))],
            showQuestions: ["1"],
            patch: true,
            patchDate: "2026-11-22",
            patchTimeSection: "08:00-09:00"
        )
        let result = try await client.update(formID: "formA", payload: payload)
        XCTAssertEqual(result.fid, "fid-edit-1")
    }

    func testListFormsAllThreeScopesAndLocalKeywordFilter() async throws {
        APIClientMockURLProtocol.configure { request, _ in
            let url = request.url!
            XCTAssertNil(request.value(forHTTPHeaderField: "Client-Form-Id"))
            switch url.path {
            case "/v1/participation_forms":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"participationForms":[{"formId":"1001","title":"每日健康打卡","status":2,"type":"ACTIVITY_V2","publisherNickname":"张老师","participants":"42","createTime":"2026-11-20 08:00:00","modifyTime":"2026-11-23 09:10:00"},{"formId":1002,"title":"周末聚餐报名","status":-1,"formType":"SIGNUP","publisherNickname":"李班长","participants":15,"createTime":"2026-11-10 12:00:00"}]}}"#
                )
            case "/v2/creation_forms":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"hasData":true,"creations":{"2026-10":[{"formId":"2001","title":"十月值班表","status":-2,"type":"ACTIVITY_V2","publisherNickname":"我自己","participants":"8","createTime":"2026-10-05 09:00:00"}],"2026-11":[{"formId":"2002","title":"十一月晨检打卡","status":2,"type":"ACTIVITY_V2","publisherNickname":"我自己","participants":"31","createTime":"2026-11-22 07:30:00"}]}}}"#
                )
            case "/v3/manager_forms":
                return Self.jsonResponse(
                    url: url,
                    body: #"{"code":0,"data":{"creations":{"2026-11":[{"formId":"3001","title":"研发部考勤汇总","status":3,"type":"CHECKIN","publisherNickname":"王主管","participants":19,"createTime":"2026-11-21 10:00:00"}]}}}"#
                )
            default:
                return Self.jsonResponse(url: url, status: 404, body: #"{"code":404}"#)
            }
        }

        let client = makeMockClient()

        let pList = try await client.listForms(scope: .participation, pageNo: 1, pageSize: 2)
        XCTAssertTrue(pList.hasMore)
        XCTAssertEqual(pList.items.count, 2)
        XCTAssertEqual(pList.items[0].statusText, "进行中")
        XCTAssertEqual(pList.items[0].participantCount, 42)
        XCTAssertEqual(pList.items[1].formID, "1002")

        let filtered = try await client.listForms(scope: .participation, pageNo: 1, pageSize: 2, keyword: "聚餐")
        XCTAssertEqual(filtered.items.count, 1)
        XCTAssertEqual(filtered.items[0].formID, "1002")

        let cList = try await client.listForms(scope: .creation, pageNo: 2, pageSize: 20)
        XCTAssertTrue(cList.hasMore)
        XCTAssertEqual(cList.items.map(\.formID), ["2002", "2001"])
        XCTAssertEqual(cList.items[1].statusText, "已暂停")

        let mList = try await client.listForms(scope: .manager, pageNo: 1, pageSize: 20)
        XCTAssertFalse(mList.hasMore)
        XCTAssertEqual(mList.items.count, 1)
        XCTAssertEqual(mList.items[0].statusText, "未开始")
    }

    func testFormDetailFatalShortCircuitZeroFieldAndFallback() async throws {
        let calls = LockedCounter()
        APIClientMockURLProtocol.configure { request, _ in
            _ = calls.increment()
            let url = request.url!
            switch url.path {
            case "/v3/form/authfail":
                return Self.jsonResponse(url: url, status: 401, body: #"{"code":13686,"message":"expired"}"#)
            case "/v3/form/notfound":
                return Self.jsonResponse(url: url, status: 422, body: #"{"code":13351,"message":"表单不存在"}"#)
            case "/v3/form/zerofield":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Form-Id"), "zerofield")
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":{"formId":"zerofield","status":2,"catalogs":[]}}"#)
            case "/v3/form/fallback":
                return Self.jsonResponse(url: url, status: 500, body: #"{"code":500,"message":"temp"}"#)
            case "/v1/form/fallback/profile":
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":{"title":"Fallback Title","status":2,"version":3}}"#)
            case "/v1/form/fallback/catalog":
                return Self.jsonResponse(url: url, body: #"{"code":0,"data":{"catalogs":[{"cid":"1","type":"WORD","must":true}]}}"#)
            default:
                return Self.jsonResponse(url: url, status: 404, body: #"{"code":404}"#)
            }
        }

        let client = makeMockClient()

        calls.reset()
        do {
            _ = try await client.formDetail(formID: "authfail")
            XCTFail("Expected session expired")
        } catch let err as APIError {
            XCTAssertTrue(err.isSessionExpired)
        }
        XCTAssertEqual(calls.current(), 1)

        calls.reset()
        do {
            _ = try await client.formDetail(formID: "notfound")
            XCTFail("Expected 13351 error")
        } catch let err as APIError {
            XCTAssertEqual(err.code, 13351)
        }
        XCTAssertEqual(calls.current(), 1)

        calls.reset()
        let zf = try await client.formDetail(formID: "zerofield")
        XCTAssertEqual(zf.formID, "zerofield")
        XCTAssertEqual(zf.fields.count, 0)
        XCTAssertEqual(calls.current(), 1)

        let fb = try await client.formDetail(formID: "fallback")
        XCTAssertEqual(fb.displayTitle, "Fallback Title")
        XCTAssertEqual(fb.fields.count, 1)
    }

    func testHTTPSDowngradeRedirectBlockedAndHelpers() async throws {
        APIClientMockURLProtocol.configure { request, _ in
            let resp = HTTPURLResponse(
                url: request.url!,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": "http://form.qun100.com/downgraded"]
            )!
            return (resp, Data())
        }

        let client = makeMockClient()
        do {
            _ = try await client.serverTime()
            XCTFail("Expected HTTPS downgrade redirect to be blocked")
        } catch let err as LaiBaoClientError {
            guard case .httpsDowngradeBlocked = err else {
                XCTFail("Expected httpsDowngradeBlocked, got \(err)")
                return
            }
        }

        // Directly verify HTTPSDowngradeBlockingDelegate blocks HTTPS -> HTTP and allows HTTPS -> HTTPS.
        let delegate = HTTPSDowngradeBlockingDelegate(initialScheme: "https")
        let dummySession = URLSession(configuration: .ephemeral)
        defer { dummySession.finishTasksAndInvalidate() }
        let dummyTask = dummySession.dataTask(with: URL(string: "https://form.qun100.com/start")!)
        let redirectResp = HTTPURLResponse(
            url: URL(string: "https://form.qun100.com/start")!,
            statusCode: 302,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "http://form.qun100.com/downgraded"]
        )!
        let redirectedRequest: URLRequest? = await withCheckedContinuation { continuation in
            delegate.urlSession(
                dummySession,
                task: dummyTask,
                willPerformHTTPRedirection: redirectResp,
                newRequest: URLRequest(url: URL(string: "http://form.qun100.com/downgraded")!)
            ) { nextReq in
                continuation.resume(returning: nextReq)
            }
        }
        XCTAssertNil(redirectedRequest)
        XCTAssertNotNil(delegate.blockedReason)
        XCTAssertTrue(delegate.blockedReason?.contains("降级") == true)

        XCTAssertEqual(LaiBaoAPIClient.stripAuthPrefix("  Bearer abc123  "), "abc123")
        XCTAssertEqual(LaiBaoAPIClient.maskToken("short"), "***")
        XCTAssertEqual(LaiBaoAPIClient.maskToken("1234567890123"), "12***23")
        XCTAssertEqual(LaiBaoAPIClient.maskToken("abcdefghijklmnopqrstuvwxyz"), "abcdef...wxyz")

        for code in [13351, 13354, 13362, 13408, 13552, 13616, 13617, 13618, 13619, 13620, 13686] {
            XCTAssertNotNil(APIError.describeCode(code), "Missing error description for \(code)")
        }
        XCTAssertEqual(APIError.describeCode(13362), "暂无提交记录")

        XCTAssertThrowsError(try LaiBaoAPIClient.validatePathID("../secret"))
        XCTAssertThrowsError(try LaiBaoAPIClient.validatePathID("a/b"))
        XCTAssertNoThrow(try LaiBaoAPIClient.validatePathID("65f123abc_01-ok"))
    }

    func testUsedNameListsEndpointAndCode13362Empty() async throws {
        APIClientMockURLProtocol.configure { request, _ in
            let url = request.url!
            let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Client-Form-Id"), url.path.contains("empty") ? "empty" : "f_roster")

            if url.path == "/v1/f_roster/name_list/used" {
                let dateVal = comps?.queryItems?.first(where: { $0.name == "date" })?.value
                let secVal = comps?.queryItems?.first(where: { $0.name == "timeSection" })?.value
                XCTAssertEqual(dateVal, "2026-11-25")
                XCTAssertEqual(secVal, "morning")
                let body = """
                {
                  "code": 0,
                  "data": [
                    {
                      "cid": "c_name",
                      "nameList": [
                        {"name": "张三", "groupId": "1", "status": 1, "fillNum": 1},
                        {"name": "李四", "groupId": "1", "status": 0, "fillNum": 0},
                        {"name": "已删", "groupId": "1", "status": -1, "fillNum": 0}
                      ]
                    }
                  ]
                }
                """
                return Self.jsonResponse(url: url, body: body)
            }

            if url.path == "/v1/empty/name_list/used" {
                return Self.jsonResponse(url: url, body: #"{"code": 13362, "message": "暂无提交记录", "data": null}"#)
            }

            return Self.jsonResponse(url: url, status: 404, body: #"{"code": 404, "message": "not found"}"#)
        }

        let client = makeMockClient()
        let buckets = try await client.usedNameLists(formID: "f_roster", date: "2026-11-25", timeSection: "morning")
        XCTAssertEqual(buckets.count, 1)
        XCTAssertEqual(buckets[0].cid, "c_name")
        XCTAssertEqual(buckets[0].entries.map(\.name), ["张三", "李四"])
        XCTAssertEqual(buckets[0].entries[0].fillNum, 1)
        XCTAssertEqual(buckets[0].entries[0].groupID, "1")

        let emptyBuckets = try await client.usedNameLists(formID: "empty")
        XCTAssertTrue(emptyBuckets.isEmpty)
    }
}
