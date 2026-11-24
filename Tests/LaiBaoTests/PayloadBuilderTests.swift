import Foundation
import XCTest
@testable import LaiBao

final class PayloadBuilderTests: XCTestCase {
    func testShowQuestionsGeofenceAreaMultiLevelDateImageAndOptions() throws {
        let form = ActInfo(
            formID: "f1",
            title: "每日健康打卡",
            status: 2,
            version: .int(5),
            catalogs: [
                FormField(cid: "del", type: "WORD", status: -1, must: true, content: .string("已删题")),
                FormField(
                    cid: "loc1",
                    type: "LOCATION",
                    status: 1,
                    must: true,
                    content: .string("打卡位置"),
                    config: [
                        "SPECIFIED_LOCATION": .object([
                            "active": .bool(true),
                            "content": .object([
                                "specifiedAddress": .string("办公楼A座"),
                                "address": .string("北京市海淀区"),
                                "latitude": .double(39.9801),
                                "longitude": .double(116.3101),
                                "scope": .double(300)
                            ])
                        ])
                    ]
                ),
                FormField(cid: "opt_word", type: "WORD", status: 1, must: false, content: .string("备注（选填）")),
                FormField(cid: "req_date", type: "DATE", status: 1, must: true, content: .string("日期")),
                FormField(cid: "area1", type: "AREA", status: 1, must: true, content: .string("地区")),
                FormField(cid: "mls1", type: "MULTI_LEVEL_SELECT", status: 1, must: true, content: .string("部门")),
                FormField(cid: "img1", type: "IMAGE", status: 1, must: true, content: .string("现场照片")),
                FormField(
                    cid: "rad1",
                    type: "RADIO",
                    status: 1,
                    must: true,
                    content: .string("状态"),
                    formCatalogs: [SubCatalog(cid: "r1", role: "OPTION", status: 1, content: .string("正常"))]
                ),
                FormField(
                    cid: "chk1",
                    type: "CHECKBOX",
                    status: 1,
                    must: true,
                    content: .string("事项"),
                    formCatalogs: [SubCatalog(cid: "c1", role: "OPTION", status: 1, content: .string("已测温"))]
                )
            ]
        )

        var cal = Calendar(identifier: .gregorian)
        let utc = TimeZone(secondsFromGMT: 8 * 3600)!
        cal.timeZone = utc
        let now = cal.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 8, minute: 35))!

        let draft = CheckinDraft(
            formID: "f1",
            lat: 39.9800,
            lng: 116.3100,
            addr: "海淀路1号",
            fieldValues: [
                "area1": .object([
                    "province": .string("北京市"),
                    "city": .string("北京市"),
                    "district": .string("海淀区")
                    // `address` intentionally omitted to verify auto-completion of all 4 standard keys.
                ]),
                "mls1": .object([
                    "pathCids": .array([.string("dept-1"), .string("team-2")])
                ]),
                "img1": .array([
                    .string("https://oss.example.com/a/photo1.jpg?sign=1")
                ])
            ]
        )

        let built = try PayloadBuilder.build(form: form, draft: draft, now: now, timeZone: utc)
        let payload = built.payload

        // `showQuestions` must include ALL 8 visible fields (including unfilled optional `opt_word`), excluding deleted `del`.
        XCTAssertEqual(payload.showQuestions.count, 8)
        XCTAssertFalse(payload.showQuestions.contains("del"))
        XCTAssertTrue(payload.showQuestions.contains("opt_word"))

        let byCID = Dictionary(uniqueKeysWithValues: payload.catalogs.map { ($0.cid, $0) })
        XCTAssertNil(byCID["opt_word"])

        // DATE must format as `YYYY-MM-DD HH:mm`.
        XCTAssertEqual(byCID["req_date"]?.value.stringValue, "2026-11-23 08:35")

        // AREA must contain all 4 standard keys.
        XCTAssertEqual(byCID["area1"]?.value["province"]?.stringValue, "北京市")
        XCTAssertEqual(byCID["area1"]?.value["address"]?.stringValue, "")

        // MULTI_LEVEL_SELECT preserves `pathCids`.
        XCTAssertEqual(byCID["mls1"]?.value["pathCids"]?.arrayValue?.compactMap(\.stringValue), ["dept-1", "team-2"])

        // IMAGE populates `value` URL array + sibling `imageDetails` with stripped filename.
        XCTAssertEqual(byCID["img1"]?.value.arrayValue?.compactMap(\.stringValue), ["https://oss.example.com/a/photo1.jpg?sign=1"])
        XCTAssertEqual(byCID["img1"]?.imageDetails?.count, 1)
        XCTAssertEqual(byCID["img1"]?.imageDetails?.first?.fileName, "photo1.jpg")

        // LOCATION geofence must put anchor coords into `setupLatitude`/`setupLongitude`/`specifiedAddress`.
        let locVal = byCID["loc1"]?.value
        XCTAssertEqual(locVal?["setupLatitude"]?.doubleValue, 39.9801)
        XCTAssertEqual(locVal?["setupLongitude"]?.doubleValue, 116.3101)
        XCTAssertEqual(locVal?["specifiedAddress"]?.stringValue, "办公楼A座")
        XCTAssertEqual(locVal?["location"]?["coordinates"]?.arrayValue?.compactMap(\.doubleValue), [116.3100, 39.9800])

        // RADIO & CHECKBOX auto-selected first option with warnings.
        XCTAssertEqual(byCID["rad1"]?.value["cid"]?.stringValue, "r1")
        XCTAssertEqual(byCID["chk1"]?.value[0]?["cid"]?.stringValue, "c1")
        XCTAssertEqual(built.warnings.count, 2)
    }

    func testRejectsAutoFillForStructuredAndValidatedRequiredFields() {
        let strictTypes = [
            "AREA", "MULTI_LEVEL_SELECT",
            "NUMBER", "NUMBER_FLOAT", "DIGIT",
            "TELEPHONE", "ID_CARD", "EMAIL", "URL", "BANK_CARD",
            "IMAGE"
        ]

        for fieldType in strictTypes {
            let form = ActInfo(
                formID: "f-strict",
                status: 2,
                catalogs: [
                    FormField(cid: "1", type: fieldType, status: 1, must: true, content: .string("字段-\(fieldType)"))
                ]
            )
            let draft = CheckinDraft(formID: "f-strict", defaultText: "签到")
            XCTAssertThrowsError(
                try PayloadBuilder.build(form: form, draft: draft),
                "Required field of type \(fieldType) must NEVER be auto-filled with default text"
            )
        }
    }

    func testEditModeStripsPatchFieldsAndDoesNotMutateDraft() throws {
        let form = ActInfo(
            formID: "f-edit",
            status: 2,
            catalogs: [
                FormField(cid: "loc1", type: "LOCATION", status: 1, must: true, content: .string("定位")),
                FormField(cid: "1", type: "WORD", status: 1, must: true, content: .string("姓名"))
            ]
        )

        let draft = CheckinDraft(
            formID: "f-edit",
            usePOIPool: true,
            pois: [POIItem(lat: 39.9042, lng: 116.4074, addr: "北京地址", title: "北京点", wgs84: false)],
            defaultText: "张三",
            patch: true,
            patchDate: "2026-11-22",
            patchSection: "08:00-09:00",
            editFID: "fid-99"
        )

        let built = try PayloadBuilder.build(form: form, draft: draft)
        XCTAssertEqual(built.payload.fid, "fid-99")
        XCTAssertFalse(built.payload.patch)
        XCTAssertEqual(built.payload.patchDate, "")
        XCTAssertEqual(built.payload.patchTimeSection, "")
        XCTAssertEqual(built.resolvedPoint, GeoPoint(lat: 39.9042, lng: 116.4074))

        // Encoded JSON must omit patch/patchDate/patchTimeSection in edit mode, while retaining examUsedTime: null.
        let encoded = try JSONEncoder().encode(built.payload)
        let json = try JSONValue.parse(from: encoded)
        XCTAssertNil(json["patch"])
        XCTAssertNil(json["patchDate"])
        XCTAssertNil(json["patchTimeSection"])
        XCTAssertEqual(json["examUsedTime"], .null)

        // Original draft remains untouched.
        XCTAssertEqual(draft.lat, 0)
        XCTAssertEqual(draft.lng, 0)
        XCTAssertTrue(draft.patch)
    }

    func testOutOfScopeGeofenceEmitsWarning() throws {
        let form = ActInfo(
            formID: "f-geo",
            status: 2,
            catalogs: [
                FormField(
                    cid: "loc1",
                    type: "LOCATION",
                    status: 1,
                    must: true,
                    content: .string("定位"),
                    config: [
                        "SPECIFIED_LOCATION": .object([
                            "active": .bool(true),
                            "content": .object([
                                "specifiedAddress": .string("总部大楼"),
                                "latitude": .double(39.9801),
                                "longitude": .double(116.3101),
                                "scope": .double(100)
                            ])
                        ])
                    ]
                )
            ]
        )

        // Place user ~1.1km away from anchor.
        let draft = CheckinDraft(formID: "f-geo", lat: 39.9901, lng: 116.3101, addr: "较远位置")
        let built = try PayloadBuilder.build(form: form, draft: draft)
        XCTAssertTrue(built.warnings.contains(where: { $0.contains("总部大楼") && $0.contains("允许范围") }))
    }
}
