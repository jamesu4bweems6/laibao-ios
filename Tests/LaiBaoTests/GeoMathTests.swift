import Foundation
import XCTest
@testable import LaiBao

final class GeoMathTests: XCTestCase {
    private struct SeededRNG: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { self.state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    func testBeijingAndShanghaiGCJ02WGS84ConversionAccuracy() {
        let beijingWGS = GeoPoint(lat: 39.9042, lng: 116.4074)
        let beijingGCJ = GeoMath.wgs84ToGCJ02(beijingWGS)
        let beijingOffset = GeoMath.distanceMeters(beijingWGS, beijingGCJ)
        XCTAssertGreaterThan(beijingOffset, 200.0)
        XCTAssertLessThan(beijingOffset, 800.0)

        let beijingRoundTrip = GeoMath.gcj02ToWGS84(beijingGCJ)
        XCTAssertLessThan(abs(beijingRoundTrip.lat - beijingWGS.lat), 1e-6)
        XCTAssertLessThan(abs(beijingRoundTrip.lng - beijingWGS.lng), 1e-6)
        XCTAssertLessThan(GeoMath.distanceMeters(beijingRoundTrip, beijingWGS), 0.2)

        let shanghaiWGS = GeoPoint(lat: 31.2304, lng: 121.4737)
        let shanghaiGCJ = GeoMath.wgs84ToGCJ02(shanghaiWGS)
        let shanghaiOffset = GeoMath.distanceMeters(shanghaiWGS, shanghaiGCJ)
        XCTAssertGreaterThan(shanghaiOffset, 200.0)
        XCTAssertLessThan(shanghaiOffset, 800.0)

        let shanghaiRoundTrip = GeoMath.gcj02ToWGS84(shanghaiGCJ)
        XCTAssertLessThan(abs(shanghaiRoundTrip.lat - shanghaiWGS.lat), 1e-6)
        XCTAssertLessThan(abs(shanghaiRoundTrip.lng - shanghaiWGS.lng), 1e-6)
        XCTAssertLessThan(GeoMath.distanceMeters(shanghaiRoundTrip, shanghaiWGS), 0.2)
    }

    func testOutOfChinaIdentityConversion() {
        let nyc = GeoPoint(lat: 40.7128, lng: -74.0060)
        XCTAssertTrue(GeoMath.outOfChina(nyc))
        XCTAssertEqual(GeoMath.wgs84ToGCJ02(nyc), nyc)
        XCTAssertEqual(GeoMath.gcj02ToWGS84(nyc), nyc)

        let tokyo = GeoPoint(lat: 35.6762, lng: 139.6503)
        XCTAssertTrue(GeoMath.outOfChina(tokyo))
        XCTAssertEqual(GeoMath.wgs84ToGCJ02(tokyo), tokyo)
    }

    func testValidateCoordRejectsInvalidValues() {
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: .nan, lng: 116.4))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: 39.9, lng: .infinity))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: 90.1, lng: 116.4))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: -90.1, lng: 116.4))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: 39.9, lng: 180.1))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: 39.9, lng: -180.1))
        XCTAssertThrowsError(try GeoMath.validateCoord(lat: 0.0, lng: 0.0))

        XCTAssertNoThrow(try GeoMath.validateCoord(lat: 39.9042, lng: 116.4074))
    }

    func testHaversineDistanceAndAntipodalClamping() {
        let beijing = GeoPoint(lat: 39.9042, lng: 116.4074)
        let shanghai = GeoPoint(lat: 31.2304, lng: 121.4737)
        XCTAssertEqual(GeoMath.distanceMeters(beijing, beijing), 0.0)

        let dist = GeoMath.distanceMeters(beijing, shanghai)
        XCTAssertGreaterThan(dist, 1_050_000)
        XCTAssertLessThan(dist, 1_090_000)

        // Antipodal points must not produce NaN due to floating-point overshoot above 1.0.
        let p1 = GeoPoint(lat: 0.0, lng: 0.0)
        let p2 = GeoPoint(lat: 0.0, lng: 180.0)
        let antipodal = GeoMath.distanceMeters(p1, p2)
        XCTAssertFalse(antipodal.isNaN)
        XCTAssertGreaterThan(antipodal, 20_000_000)
    }

    func testJitterNormalAndPoleSafe() {
        var rng = SeededRNG(seed: 42)
        let origin = GeoPoint(lat: 39.9042, lng: 116.4074)
        for _ in 0..<50 {
            let moved = GeoMath.jitter(origin, radiusMeters: 50, using: &rng)
            XCTAssertTrue(moved.lat.isFinite && moved.lng.isFinite)
            // Allow minor rounding tolerance from 6-decimal rounding.
            XCTAssertLessThanOrEqual(GeoMath.distanceMeters(origin, moved), 52.0)
        }

        // Near pole (|lat| > 89.9) must skip jitter cleanly without NaN/Inf.
        let northPole = GeoPoint(lat: 89.95, lng: 10.0)
        let unchanged = GeoMath.jitter(northPole, radiusMeters: 100, using: &rng)
        XCTAssertEqual(unchanged, northPole)
        XCTAssertTrue(unchanged.lat.isFinite && unchanged.lng.isFinite)
    }

    func testLocationType0CurrentLocationPayload() throws {
        let config: [String: JSONValue] = [
            "SPECIFIED_LOCATION": .object([
                "active": .bool(false),
                "content": .object([
                    "address": .string("北京市海淀区预设地址")
                ])
            ])
        ]
        let spec = GeoMath.extractSpecifiedLocation(from: config)
        XCTAssertNotNil(spec)
        XCTAssertEqual(spec?.locationType, .current)

        let userPt = GeoPoint(lat: 39.9800, lng: 116.3100)
        let payload = GeoMath.buildLocationValue(userPoint: userPt, addr: "实时地址", title: "中关村", specified: spec)
        XCTAssertEqual(payload.locationType, .current)
        XCTAssertEqual(payload.setupLatitude, 0)
        XCTAssertEqual(payload.setupLongitude, 0)
        XCTAssertEqual(payload.specifiedAddress, "")
        XCTAssertEqual(payload.setupAddress, "北京市海淀区预设地址")
        XCTAssertEqual(payload.location.coordinates, [116.3100, 39.9800])

        let data = try JSONEncoder().encode(payload)
        let json = try JSONValue.parse(from: data)
        XCTAssertEqual(json["setupLatitude"]?.doubleValue, 0)
        XCTAssertEqual(json["setupLongitude"]?.doubleValue, 0)
        XCTAssertEqual(json["specifiedAddress"]?.stringValue, "")
        XCTAssertEqual(json["setupAddress"]?.stringValue, "北京市海淀区预设地址")
        XCTAssertNil(json["latitude"])
        XCTAssertNil(json["longitude"])
    }

    func testLocationType1SpecifiedUsesAnchorCoordsNotUserCoords() throws {
        let config: [String: JSONValue] = [
            "SPECIFIED_LOCATION": .object([
                "active": .bool(true),
                "content": .object([
                    "optionalPosition": .bool(false),
                    "locations": .array([
                        .object([
                            "specifiedAddress": .string("远端分部"),
                            "address": .string("上海市浦东新区"),
                            "latitude": .double(31.2304),
                            "longitude": .double(121.4737),
                            "scope": .double(300)
                        ]),
                        .object([
                            "specifiedAddress": .string("总部办公楼A座"),
                            "address": .string("北京市海淀区海淀路1号"),
                            "latitude": .double(39.9805),
                            "longitude": .double(116.3105),
                            "scope": .double(500)
                        ])
                    ])
                ])
            ])
        ]

        let spec = GeoMath.extractSpecifiedLocation(from: config)
        XCTAssertEqual(spec?.locationType, .specified)
        XCTAssertEqual(spec?.anchors.count, 2)

        let userPt = GeoPoint(lat: 39.9800, lng: 116.3100)
        let match = GeoMath.pickNearestAnchor(userPoint: userPt, anchors: spec?.anchors ?? [])
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.index, 1)
        XCTAssertEqual(match?.isWithinScope, true)

        let payload = GeoMath.buildLocationValue(userPoint: userPt, addr: "用户当前位置", title: "用户标题", specified: spec)
        XCTAssertEqual(payload.locationType, .specified)
        // User coordinates in GeoJSON `location.coordinates` ([lng, lat]).
        XCTAssertEqual(payload.location.coordinates, [116.3100, 39.9800])
        // Anchor coordinates in `setupLatitude` / `setupLongitude` / `specifiedAddress` (NOT user coordinates!).
        XCTAssertEqual(payload.setupLatitude, 39.9805)
        XCTAssertEqual(payload.setupLongitude, 116.3105)
        XCTAssertEqual(payload.specifiedAddress, "总部办公楼A座")
        XCTAssertEqual(payload.title, "总部办公楼A座")
        XCTAssertEqual(payload.setupAddress, "")

        let data = try JSONEncoder().encode(payload)
        let json = try JSONValue.parse(from: data)
        XCTAssertEqual(json["setupLatitude"]?.doubleValue, 39.9805)
        XCTAssertEqual(json["setupLongitude"]?.doubleValue, 116.3105)
        XCTAssertEqual(json["specifiedAddress"]?.stringValue, "总部办公楼A座")
        XCTAssertNil(json["latitude"])
        XCTAssertNil(json["longitude"])
    }

    func testLocationType2FreeSelectionPayload() throws {
        let config: [String: JSONValue] = [
            "SPECIFIED_LOCATION": .object([
                "active": .bool(true),
                "content": .object([
                    "optionalPosition": .bool(true)
                ])
            ])
        ]
        let spec = GeoMath.extractSpecifiedLocation(from: config)
        XCTAssertEqual(spec?.locationType, .free)

        let userPt = GeoPoint(lat: 39.9042, lng: 116.4074)
        let payload = GeoMath.buildLocationValue(userPoint: userPt, addr: "天安门广场", title: "天安门", specified: spec)
        XCTAssertEqual(payload.locationType, .free)
        XCTAssertEqual(payload.latitude, 39.9042)
        XCTAssertEqual(payload.longitude, 116.4074)

        let data = try JSONEncoder().encode(payload)
        let json = try JSONValue.parse(from: data)
        XCTAssertEqual(json["latitude"]?.doubleValue, 39.9042)
        XCTAssertEqual(json["longitude"]?.doubleValue, 116.4074)
        XCTAssertNil(json["setupLatitude"])
        XCTAssertNil(json["setupLongitude"])
        XCTAssertNil(json["specifiedAddress"])
    }
}
