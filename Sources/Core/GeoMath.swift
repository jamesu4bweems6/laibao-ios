import Foundation

/// Errors thrown by coordinate validation.
public enum GeoMathError: LocalizedError, Sendable, Equatable {
    case nonFiniteCoordinate
    case latitudeOutOfRange(Double)
    case longitudeOutOfRange(Double)
    case zeroCoordinate

    public var errorDescription: String? {
        switch self {
        case .nonFiniteCoordinate:
            return "坐标包含非法的 NaN 或 Inf 值"
        case .latitudeOutOfRange(let lat):
            return "纬度超出 [-90, 90] 范围: \(lat)"
        case .longitudeOutOfRange(let lng):
            return "经度超出 [-180, 180] 范围: \(lng)"
        case .zeroCoordinate:
            return "坐标不能为 (0, 0)"
        }
    }
}

/// A geographic latitude/longitude coordinate pair.
public struct GeoPoint: Codable, Hashable, Sendable {
    public var lat: Double
    public var lng: Double

    public init(lat: Double, lng: Double) {
        self.lat = lat
        self.lng = lng
    }

    /// Formats the point with 6 decimal places (`"lat,lng"`).
    public var formatted: String {
        GeoMath.format(self)
    }
}

/// Location submission mode aligned with `location.js` in the WeChat Mini Program:
/// - `current` (0): Current location within 300m fine-tuning (`SPECIFIED_LOCATION.active == false`).
/// - `specified` (1): Geofenced target anchor(s) (`SPECIFIED_LOCATION.active == true && !optionalPosition`).
/// - `free` (2): Free map selection (`optionalPosition == true` or no `SPECIFIED_LOCATION`).
public enum LocationType: Int, Codable, Hashable, Sendable {
    case current = 0
    case specified = 1
    case free = 2

    public var displayName: String {
        switch self {
        case .current:
            return "仅限当前位置"
        case .specified:
            return "指定围栏打卡"
        case .free:
            return "自由选点"
        }
    }
}

/// A single geofence target anchor defined inside `config.SPECIFIED_LOCATION`.
public struct LocationAnchor: Codable, Hashable, Sendable, Identifiable {
    public var specifiedAddress: String
    public var address: String
    public var latitude: Double
    public var longitude: Double
    public var scope: Double

    public var id: String {
        "\(specifiedAddress)|\(address)|\(latitude)|\(longitude)|\(scope)"
    }

    public var point: GeoPoint {
        GeoPoint(lat: latitude, lng: longitude)
    }

    public var displayName: String {
        if !specifiedAddress.isEmpty { return specifiedAddress }
        if !address.isEmpty { return address }
        return point.formatted
    }

    public init(
        specifiedAddress: String,
        address: String = "",
        latitude: Double,
        longitude: Double,
        scope: Double = 500
    ) {
        self.specifiedAddress = specifiedAddress
        self.address = address
        self.latitude = latitude
        self.longitude = longitude
        self.scope = scope > 0 ? scope : 500
    }
}

/// Parsed `SPECIFIED_LOCATION` constraint configuration extracted from a `LOCATION` field.
public struct SpecifiedLocation: Codable, Hashable, Sendable {
    public var locationType: LocationType
    public var active: Bool
    public var optionalPosition: Bool
    public var setupAddress: String
    public var anchors: [LocationAnchor]

    public init(
        locationType: LocationType,
        active: Bool,
        optionalPosition: Bool = false,
        setupAddress: String = "",
        anchors: [LocationAnchor] = []
    ) {
        self.locationType = locationType
        self.active = active
        self.optionalPosition = optionalPosition
        self.setupAddress = setupAddress
        self.anchors = anchors
    }
}

/// GeoJSON Point (`coordinates` order is `[longitude, latitude]`).
public struct GeoJSONPoint: Codable, Hashable, Sendable {
    public var type: String
    public var coordinates: [Double]

    public init(type: String = "Point", coordinates: [Double]) {
        self.type = type
        self.coordinates = coordinates
    }

    public init(point: GeoPoint) {
        self.type = "Point"
        self.coordinates = [point.lng, point.lat]
    }
}

/// Wire-accurate submission value for `LOCATION` fields across all 3 `LocationType` modes.
public struct LocationPayloadValue: Codable, Hashable, Sendable {
    public var locationType: LocationType
    public var address: String
    public var title: String
    public var location: GeoJSONPoint
    public var latitude: Double
    public var longitude: Double
    public var specifiedAddress: String
    public var setupLatitude: Double
    public var setupLongitude: Double
    public var setupAddress: String

    public init(
        locationType: LocationType,
        address: String,
        title: String,
        location: GeoJSONPoint,
        latitude: Double = 0,
        longitude: Double = 0,
        specifiedAddress: String = "",
        setupLatitude: Double = 0,
        setupLongitude: Double = 0,
        setupAddress: String = ""
    ) {
        self.locationType = locationType
        self.address = address
        self.title = title
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.specifiedAddress = specifiedAddress
        self.setupLatitude = setupLatitude
        self.setupLongitude = setupLongitude
        self.setupAddress = setupAddress
    }

    private enum CodingKeys: String, CodingKey {
        case address
        case title
        case location
        case latitude
        case longitude
        case specifiedAddress
        case setupLatitude
        case setupLongitude
        case setupAddress
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
        let title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        let location = try container.decodeIfPresent(GeoJSONPoint.self, forKey: .location)
            ?? GeoJSONPoint(coordinates: [0, 0])
        let lat = try container.decodeIfPresent(Double.self, forKey: .latitude)
            ?? (location.coordinates.count >= 2 ? location.coordinates[1] : 0)
        let lng = try container.decodeIfPresent(Double.self, forKey: .longitude)
            ?? (location.coordinates.count >= 2 ? location.coordinates[0] : 0)
        let hasSetupKeys = container.contains(.setupLatitude)
            || container.contains(.setupLongitude)
            || container.contains(.specifiedAddress)
            || container.contains(.setupAddress)
        let specifiedAddress = try container.decodeIfPresent(String.self, forKey: .specifiedAddress) ?? ""
        let setupLatitude = try container.decodeIfPresent(Double.self, forKey: .setupLatitude) ?? 0
        let setupLongitude = try container.decodeIfPresent(Double.self, forKey: .setupLongitude) ?? 0
        let setupAddress = try container.decodeIfPresent(String.self, forKey: .setupAddress) ?? ""

        let detectedType: LocationType
        if hasSetupKeys {
            if !specifiedAddress.isEmpty || setupLatitude != 0 || setupLongitude != 0 {
                detectedType = .specified
            } else {
                detectedType = .current
            }
        } else {
            detectedType = .free
        }

        self.init(
            locationType: detectedType,
            address: address,
            title: title,
            location: location,
            latitude: lat,
            longitude: lng,
            specifiedAddress: specifiedAddress,
            setupLatitude: setupLatitude,
            setupLongitude: setupLongitude,
            setupAddress: setupAddress
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch locationType {
        case .current, .specified:
            try container.encode(address, forKey: .address)
            try container.encode(title, forKey: .title)
            try container.encode(location, forKey: .location)
            try container.encode(specifiedAddress, forKey: .specifiedAddress)
            try container.encode(setupLongitude, forKey: .setupLongitude)
            try container.encode(setupLatitude, forKey: .setupLatitude)
            try container.encode(setupAddress, forKey: .setupAddress)
        case .free:
            try container.encode(location, forKey: .location)
            try container.encode(address, forKey: .address)
            try container.encode(title, forKey: .title)
            try container.encode(latitude, forKey: .latitude)
            try container.encode(longitude, forKey: .longitude)
        }
    }

    /// Converts this value into a `JSONValue` matching the exact wire JSON keys for its `locationType`.
    public func toJSONValue() -> JSONValue {
        let geoJSON: JSONValue = .object([
            "type": .string(location.type),
            "coordinates": .array(location.coordinates.map { .double($0) })
        ])
        switch locationType {
        case .current, .specified:
            return .object([
                "address": .string(address),
                "title": .string(title),
                "location": geoJSON,
                "specifiedAddress": .string(specifiedAddress),
                "setupLongitude": .double(setupLongitude),
                "setupLatitude": .double(setupLatitude),
                "setupAddress": .string(setupAddress)
            ])
        case .free:
            return .object([
                "location": geoJSON,
                "address": .string(address),
                "title": .string(title),
                "latitude": .double(latitude),
                "longitude": .double(longitude)
            ])
        }
    }
}

/// Result of matching a user coordinate against geofence anchors.
public struct AnchorMatch: Sendable, Equatable {
    public let anchor: LocationAnchor
    public let index: Int
    public let distanceMeters: Double
    public let isWithinScope: Bool

    public init(anchor: LocationAnchor, index: Int, distanceMeters: Double, isWithinScope: Bool) {
        self.anchor = anchor
        self.index = index
        self.distanceMeters = distanceMeters
        self.isWithinScope = isWithinScope
    }
}

/// Coordinate math, GCJ-02 <-> WGS-84 conversion, Haversine distance, pole-safe jitter,
/// and `LOCATION` field geofence payload builder with 100% parity to `laibao/internal/loc`.
public enum GeoMath {
    public static let earthRadiusMeters: Double = 6_378_137.0
    private static let ellipsoidA: Double = 6_378_245.0
    private static let ellipsoidEE: Double = 0.00669342162296594323

    /// Validates that latitude is in `[-90, 90]`, longitude is in `[-180, 180]`, both are finite,
    /// and the pair is not `(0, 0)`.
    public static func validateCoord(lat: Double, lng: Double) throws {
        guard lat.isFinite, lng.isFinite else {
            throw GeoMathError.nonFiniteCoordinate
        }
        guard lat >= -90.0 && lat <= 90.0 else {
            throw GeoMathError.latitudeOutOfRange(lat)
        }
        guard lng >= -180.0 && lng <= 180.0 else {
            throw GeoMathError.longitudeOutOfRange(lng)
        }
        guard !(lat == 0.0 && lng == 0.0) else {
            throw GeoMathError.zeroCoordinate
        }
    }

    /// Returns `true` if the point lies outside mainland China's GCJ-02 bounding box.
    public static func outOfChina(_ point: GeoPoint) -> Bool {
        point.lng < 72.004 || point.lng > 137.8347 || point.lat < 0.8293 || point.lat > 55.8271
    }

    private static func transformLat(_ x: Double, _ y: Double) -> Double {
        var ret = -100.0 + 2.0 * x + 3.0 * y + 0.2 * y * y + 0.1 * x * y + 0.2 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(y * .pi) + 40.0 * sin(y / 3.0 * .pi)) * 2.0 / 3.0
        ret += (160.0 * sin(y / 12.0 * .pi) + 320.0 * sin(y * .pi / 30.0)) * 2.0 / 3.0
        return ret
    }

    private static func transformLng(_ x: Double, _ y: Double) -> Double {
        var ret = 300.0 + x + 2.0 * y + 0.1 * x * x + 0.1 * x * y + 0.1 * sqrt(abs(x))
        ret += (20.0 * sin(6.0 * x * .pi) + 20.0 * sin(2.0 * x * .pi)) * 2.0 / 3.0
        ret += (20.0 * sin(x * .pi) + 40.0 * sin(x / 3.0 * .pi)) * 2.0 / 3.0
        ret += (150.0 * sin(x / 12.0 * .pi) + 300.0 * sin(x / 30.0 * .pi)) * 2.0 / 3.0
        return ret
    }

    /// Converts raw GPS (WGS-84) coordinates into GCJ-02 (AMap / Tencent / Apple China) coordinates.
    public static func wgs84ToGCJ02(_ point: GeoPoint) -> GeoPoint {
        if outOfChina(point) {
            return point
        }
        var dLat = transformLat(point.lng - 105.0, point.lat - 35.0)
        var dLng = transformLng(point.lng - 105.0, point.lat - 35.0)
        let radLat = point.lat / 180.0 * .pi
        var magic = sin(radLat)
        magic = 1.0 - ellipsoidEE * magic * magic
        let sqrtMagic = sqrt(magic)
        dLat = (dLat * 180.0) / ((ellipsoidA * (1.0 - ellipsoidEE)) / (magic * sqrtMagic) * .pi)
        dLng = (dLng * 180.0) / (ellipsoidA / sqrtMagic * cos(radLat) * .pi)
        return GeoPoint(lat: point.lat + dLat, lng: point.lng + dLng)
    }

    /// Inverse conversion from GCJ-02 to WGS-84 via fixed-point iteration (up to 30 iterations, 1e-9° tolerance).
    public static func gcj02ToWGS84(_ point: GeoPoint) -> GeoPoint {
        if outOfChina(point) {
            return point
        }
        var wgs = point
        for _ in 0..<30 {
            let g = wgs84ToGCJ02(wgs)
            let dLat = g.lat - point.lat
            let dLng = g.lng - point.lng
            if abs(dLat) < 1e-9 && abs(dLng) < 1e-9 {
                break
            }
            wgs.lat -= dLat
            wgs.lng -= dLng
        }
        return wgs
    }

    /// Great-circle Haversine distance in meters (earth radius 6,378,137m), clamped to `[0, 1]` to prevent antipodal NaN,
    /// rounded to the nearest millimeter.
    public static func distanceMeters(_ p1: GeoPoint, _ p2: GeoPoint) -> Double {
        let rad = Double.pi / 180.0
        let lat1 = p1.lat * rad
        let lat2 = p2.lat * rad
        let deltaLat = lat1 - lat2
        let deltaLng = (p1.lng - p2.lng) * rad
        let sinHalfLat = sin(deltaLat / 2.0)
        let sinHalfLng = sin(deltaLng / 2.0)
        var h = sinHalfLat * sinHalfLat + cos(lat1) * cos(lat2) * sinHalfLng * sinHalfLng
        if h > 1.0 {
            h = 1.0
        } else if h < 0.0 {
            h = 0.0
        }
        let d = 2.0 * asin(sqrt(h))
        return (d * earthRadiusMeters * 1000.0).rounded() / 1000.0
    }

    /// Applies uniform disk random jitter within `radiusMeters` around `point`.
    /// Automatically skips near poles (`|lat| > 89.9`) to avoid `cos(lat)` division-by-zero NaN/Inf.
    public static func jitter(_ point: GeoPoint, radiusMeters: Double) -> GeoPoint {
        var rng = SystemRandomNumberGenerator()
        return jitter(point, radiusMeters: radiusMeters, using: &rng)
    }

    /// Deterministic/injectable-RNG variant of `jitter(_:radiusMeters:)`.
    public static func jitter<G: RandomNumberGenerator>(
        _ point: GeoPoint,
        radiusMeters: Double,
        using generator: inout G
    ) -> GeoPoint {
        guard radiusMeters > 0, radiusMeters.isFinite else {
            return point
        }
        guard abs(point.lat) <= 89.9 else {
            return point
        }
        let u1 = Double.random(in: 0.0...1.0, using: &generator)
        let u2 = Double.random(in: 0.0..<1.0, using: &generator)
        let r = radiusMeters * sqrt(u1)
        let theta = u2 * 2.0 * .pi
        let dNorth = r * sin(theta)
        let dEast = r * cos(theta)
        var lat = point.lat + dNorth / 111_320.0
        if lat > 90.0 {
            lat = 90.0
        } else if lat < -90.0 {
            lat = -90.0
        }
        var lng = point.lng + dEast / (111_320.0 * cos(point.lat * .pi / 180.0))
        while lng > 180.0 {
            lng -= 360.0
        }
        while lng < -180.0 {
            lng += 360.0
        }
        return GeoPoint(lat: round6(lat), lng: round6(lng))
    }

    private static func round6(_ value: Double) -> Double {
        (value * 1_000_000.0).rounded() / 1_000_000.0
    }

    /// Formats a point as `"lat,lng"` with 6 decimal places.
    public static func format(_ point: GeoPoint) -> String {
        String(format: "%.6f,%.6f", point.lat, point.lng)
    }

    /// Extracts `SPECIFIED_LOCATION` geofence configuration from a `LOCATION` field's `config`.
    /// Returns `nil` when `SPECIFIED_LOCATION` is absent (indicating free selection mode `locationType == 2`).
    public static func extractSpecifiedLocation(from fieldConfig: [String: JSONValue]?) -> SpecifiedLocation? {
        guard let fieldConfig,
              let sl = fieldConfig["SPECIFIED_LOCATION"]?.objectValue else {
            return nil
        }
        let active = sl["active"]?.boolValue ?? false
        let content = sl["content"]?.objectValue
        let optionalPosition = content?["optionalPosition"]?.boolValue ?? false

        if !active {
            let setupAddr = content?["address"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return SpecifiedLocation(
                locationType: .current,
                active: false,
                optionalPosition: false,
                setupAddress: setupAddr,
                anchors: []
            )
        }

        if optionalPosition {
            return SpecifiedLocation(
                locationType: .free,
                active: true,
                optionalPosition: true,
                setupAddress: "",
                anchors: []
            )
        }

        var anchors: [LocationAnchor] = []
        if let locs = content?["locations"]?.arrayValue, !locs.isEmpty {
            for item in locs {
                if let dict = item.objectValue {
                    anchors.append(parseAnchor(dict))
                }
            }
        } else if let content {
            let anchor = parseAnchor(content)
            if !anchor.specifiedAddress.isEmpty || !anchor.address.isEmpty || anchor.latitude != 0 || anchor.longitude != 0 {
                anchors.append(anchor)
            }
        }

        return SpecifiedLocation(
            locationType: .specified,
            active: true,
            optionalPosition: false,
            setupAddress: "",
            anchors: anchors
        )
    }

    private static func parseAnchor(_ dict: [String: JSONValue]) -> LocationAnchor {
        let rawScope = dict["scope"]?.doubleValue ?? 0
        let scope = rawScope > 0 ? rawScope : 500
        return LocationAnchor(
            specifiedAddress: dict["specifiedAddress"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            address: dict["address"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            latitude: dict["latitude"]?.doubleValue ?? 0,
            longitude: dict["longitude"]?.doubleValue ?? 0,
            scope: scope
        )
    }

    /// Picks the best matching anchor for `userPoint`:
    /// prefers the nearest anchor within its geofence `scope`; otherwise falls back to the nearest anchor overall.
    public static func pickNearestAnchor(userPoint: GeoPoint, anchors: [LocationAnchor]) -> AnchorMatch? {
        guard !anchors.isEmpty else { return nil }
        var bestIn: AnchorMatch?
        var bestAny: AnchorMatch?

        for (index, anchor) in anchors.enumerated() {
            let dist = distanceMeters(userPoint, anchor.point)
            let scope = anchor.scope > 0 ? anchor.scope : 500
            let inRange = dist <= scope

            if bestAny == nil || dist < bestAny!.distanceMeters {
                bestAny = AnchorMatch(anchor: anchor, index: index, distanceMeters: dist, isWithinScope: inRange)
            }
            if inRange && (bestIn == nil || dist < bestIn!.distanceMeters) {
                bestIn = AnchorMatch(anchor: anchor, index: index, distanceMeters: dist, isWithinScope: true)
            }
        }
        return bestIn ?? bestAny
    }

    /// Builds a wire-accurate `LocationPayloadValue` for the given `userPoint` and optional `SpecifiedLocation`.
    /// For `locationType == .specified`, `setupLatitude` / `setupLongitude` / `specifiedAddress` are populated from
    /// the matched **anchor** coordinates (NEVER from `userPoint`!).
    public static func buildLocationValue(
        userPoint: GeoPoint,
        addr: String,
        title: String,
        specified: SpecifiedLocation?,
        anchorIndex: Int? = nil
    ) -> LocationPayloadValue {
        let geo = GeoJSONPoint(point: userPoint)

        guard let spec = specified, spec.locationType != .free else {
            return LocationPayloadValue(
                locationType: .free,
                address: addr,
                title: title,
                location: geo,
                latitude: userPoint.lat,
                longitude: userPoint.lng
            )
        }

        if spec.locationType == .current {
            let setupAddr = spec.setupAddress.isEmpty ? addr : spec.setupAddress
            return LocationPayloadValue(
                locationType: .current,
                address: addr,
                title: title,
                location: geo,
                specifiedAddress: "",
                setupLatitude: 0,
                setupLongitude: 0,
                setupAddress: setupAddr
            )
        }

        // LocationType.specified (1): setupLatitude / setupLongitude / specifiedAddress use anchor coordinates.
        let chosenAnchor: LocationAnchor?
        if let idx = anchorIndex, spec.anchors.indices.contains(idx) {
            chosenAnchor = spec.anchors[idx]
        } else {
            chosenAnchor = pickNearestAnchor(userPoint: userPoint, anchors: spec.anchors)?.anchor
        }

        var finalAddr = addr
        var finalTitle = title
        var specAddr = ""
        var setupLat = 0.0
        var setupLng = 0.0

        if let anchor = chosenAnchor {
            if finalAddr.isEmpty {
                finalAddr = anchor.address
            }
            specAddr = anchor.specifiedAddress
            if !anchor.specifiedAddress.isEmpty {
                finalTitle = anchor.specifiedAddress
            }
            setupLat = anchor.latitude
            setupLng = anchor.longitude
        }

        return LocationPayloadValue(
            locationType: .specified,
            address: finalAddr,
            title: finalTitle,
            location: geo,
            specifiedAddress: specAddr,
            setupLatitude: setupLat,
            setupLongitude: setupLng,
            setupAddress: ""
        )
    }
}
