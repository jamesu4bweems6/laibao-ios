import Foundation

/// Errors thrown while assembling a `SubmitPayload` from a `CheckinDraft`.
public enum PayloadBuildError: LocalizedError, Sendable, Equatable {
    case emptyPOIPool
    case invalidCoordinate(String)
    case missingRequiredField(cid: String, title: String, type: String, hint: String)
    case invalidFieldValue(cid: String, title: String, detail: String)
    case noSubmittableFields

    public var errorDescription: String? {
        switch self {
        case .emptyPOIPool:
            return "POI 点位池为空，请先添加点位或手动输入经纬度"
        case .invalidCoordinate(let detail):
            return detail
        case .missingRequiredField(let cid, let title, let type, let hint):
            return "必填字段 \(cid)（\(title)，类型 \(type)）无法自动填写：\(hint)"
        case .invalidFieldValue(let cid, let title, let detail):
            return "字段 \(cid)（\(title)）的值无效：\(detail)"
        case .noSubmittableFields:
            return "没有可提交的字段：请填写至少一个字段值"
        }
    }
}

/// Immutable value draft for building a check-in / form submission payload.
/// Safe to pass across Swift 6 concurrency boundaries without mutating caller state.
public struct CheckinDraft: Sendable, Hashable {
    public var formID: String
    public var lat: Double
    public var lng: Double
    public var addr: String
    public var title: String
    public var wgs84: Bool
    public var jitterMeters: Double
    public var usePOIPool: Bool
    public var pois: [POIItem]
    public var anchorIndex: Int?
    public var defaultText: String
    public var fieldValues: [String: JSONValue]
    public var patch: Bool
    public var patchDate: String
    public var patchSection: String
    public var editFID: String
    public var noAutoOption: Bool
    public var dryRun: Bool

    public init(
        formID: String,
        lat: Double = 0,
        lng: Double = 0,
        addr: String = "",
        title: String = "",
        wgs84: Bool = false,
        jitterMeters: Double = 0,
        usePOIPool: Bool = false,
        pois: [POIItem] = [],
        anchorIndex: Int? = nil,
        defaultText: String = "",
        fieldValues: [String: JSONValue] = [:],
        patch: Bool = false,
        patchDate: String = "",
        patchSection: String = "",
        editFID: String = "",
        noAutoOption: Bool = false,
        dryRun: Bool = false
    ) {
        self.formID = formID
        self.lat = lat
        self.lng = lng
        self.addr = addr
        self.title = title
        self.wgs84 = wgs84
        self.jitterMeters = jitterMeters
        self.usePOIPool = usePOIPool
        self.pois = pois
        self.anchorIndex = anchorIndex
        self.defaultText = defaultText
        self.fieldValues = fieldValues
        self.patch = patch
        self.patchDate = patchDate
        self.patchSection = patchSection
        self.editFID = editFID
        self.noAutoOption = noAutoOption
        self.dryRun = dryRun
    }
}

/// Assembles wire-accurate `SubmitPayload` structures aligned with `writeModule.js` / `problem.js` / `location.js` / `timePicker.js`.
public enum PayloadBuilder {
    /// Structured / format-validated field types that MUST NEVER be auto-filled with `"签到"`.
    private static let nonAutoFillableTypes: Set<String> = [
        "AREA", "MULTI_LEVEL_SELECT",
        "NUMBER", "NUMBER_FLOAT", "DIGIT",
        "TELEPHONE", "ID_CARD", "EMAIL", "URL", "BANK_CARD",
        "IMAGE", "THUMBNAIL", "VIDEO", "AUDIO", "FILE",
        "MATRIX", "TABLE", "CHECK", "RATING", "RESERVATION", "RANKING",
        "EXAM_CHOICE", "EXAM_COMPLETION", "EXAM_SUBJECTIVE", "SIGNATURE", "COURSE"
    ]

    /// Builds a `SubmitPayload`, human-readable warnings, and optional resolved GCJ-02 point without mutating `draft`.
    public static func build(
        form: ActInfo,
        draft: CheckinDraft,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> (payload: SubmitPayload, warnings: [String], resolvedPoint: GeoPoint?) {
        var warnings: [String] = []

        if form.status != 2 {
            warnings.append("表单当前状态为「\(form.statusText)」")
        }

        // 1. Resolve location coordinates immutably (POI pool -> WGS-84->GCJ-02 -> jitter).
        var resolvedLat = draft.lat
        var resolvedLng = draft.lng
        var resolvedWGS84 = draft.wgs84
        var resolvedAddr = draft.addr.trimmingCharacters(in: .whitespacesAndNewlines)
        var resolvedTitle = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)

        if draft.usePOIPool || (resolvedLat == 0 && resolvedLng == 0 && !draft.pois.isEmpty) {
            guard !draft.pois.isEmpty else {
                throw PayloadBuildError.emptyPOIPool
            }
            let picked = draft.pois[Int.random(in: 0..<draft.pois.count)]
            do {
                try picked.validate()
            } catch {
                throw PayloadBuildError.invalidCoordinate("POI 点位无效: \(error.localizedDescription)")
            }
            resolvedLat = picked.lat
            resolvedLng = picked.lng
            resolvedWGS84 = picked.wgs84
            if resolvedAddr.isEmpty {
                resolvedAddr = picked.addr.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if resolvedTitle.isEmpty {
                resolvedTitle = picked.title.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        var resolvedPoint: GeoPoint?
        if resolvedLat != 0 || resolvedLng != 0 {
            do {
                try GeoMath.validateCoord(lat: resolvedLat, lng: resolvedLng)
            } catch {
                throw PayloadBuildError.invalidCoordinate("定位坐标无效: \(error.localizedDescription)")
            }
            var pt = GeoPoint(lat: resolvedLat, lng: resolvedLng)
            if resolvedWGS84 {
                pt = GeoMath.wgs84ToGCJ02(pt)
            }
            if draft.jitterMeters > 0 {
                pt = GeoMath.jitter(pt, radiusMeters: draft.jitterMeters)
            }
            resolvedPoint = pt
            if resolvedAddr.isEmpty {
                resolvedAddr = GeoMath.format(pt)
            }
            if resolvedTitle.isEmpty {
                resolvedTitle = resolvedAddr
            }
        }

        // 2. Assemble `showQuestions` (ALL visible fields) and `catalogs` (answered fields).
        var catalogValues: [CatalogValue] = []
        var showQuestions: [String] = []

        for field in form.fields {
            guard field.isVisible else { continue }
            showQuestions.append(field.cid)

            if let overrideValue = draft.fieldValues[field.cid] {
                if overrideValue.isNull {
                    if field.must {
                        throw PayloadBuildError.missingRequiredField(
                            cid: field.cid,
                            title: field.title,
                            type: field.type,
                            hint: "覆写值不能为空"
                        )
                    }
                    continue
                }
                let item = try buildOverrideItem(field: field, value: overrideValue)
                catalogValues.append(item)
                continue
            }

            let built = try buildDefaultItem(
                field: field,
                draft: draft,
                resolvedPoint: resolvedPoint,
                resolvedAddr: resolvedAddr,
                resolvedTitle: resolvedTitle,
                now: now,
                timeZone: timeZone
            )
            if let warn = built.warning {
                warnings.append(warn)
            }
            if let item = built.item {
                catalogValues.append(item)
            } else if field.must {
                throw requiredFieldError(for: field)
            }
        }

        guard !catalogValues.isEmpty else {
            throw PayloadBuildError.noSubmittableFields
        }

        let editFID = draft.editFID.trimmingCharacters(in: .whitespacesAndNewlines)
        var payload = SubmitPayload(
            fid: editFID,
            catalogs: catalogValues,
            showQuestions: showQuestions,
            examUsedTime: nil,
            formVersion: form.version,
            subscribe: [:],
            patch: false,
            patchDate: "",
            patchTimeSection: ""
        )

        // Strictly strip patch* fields in edit mode (aligned with writeModule.js getSubmitParams()).
        if editFID.isEmpty && draft.patch {
            payload.patch = true
            payload.patchDate = draft.patchDate
            payload.patchTimeSection = draft.patchSection
        }

        return (payload: payload, warnings: warnings, resolvedPoint: resolvedPoint)
    }

    /// Formats a `Date` for `DATE` form fields (`"yyyy-MM-dd HH:mm"`, aligned with `timePicker.js`).
    public static func formatDateValue(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Extracts a clean display filename from an image URL for `imageDetails`.
    public static func fileName(from urlString: String) -> String {
        var clean = urlString
        if let cutIdx = clean.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            clean = String(clean[..<cutIdx])
        }
        var base = clean
        if let slashIdx = base.lastIndex(of: "/") {
            base = String(base[base.index(after: slashIdx)...])
        }
        if base.isEmpty {
            return "图片.jpg"
        }
        if !base.contains(".") {
            return base + ".jpg"
        }
        return base
    }

    /// Converts an existing `RecordItem`'s catalogs into a `[String: JSONValue]` dictionary suitable
    /// for pre-filling `CheckinDraft.fieldValues` when editing a previous submission.
    public static func draftFieldValues(from record: RecordItem) -> [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        for item in record.catalogs where !item.cid.isEmpty && !item.value.isNull {
            out[item.cid] = item.value
        }
        return out
    }

    // MARK: - Private Builders

    private static func buildOverrideItem(field: FormField, value: JSONValue) throws -> CatalogValue {
        let ft = field.normalizedType

        switch ft {
        case "IMAGE":
            guard let arr = value.arrayValue else {
                throw PayloadBuildError.invalidFieldValue(
                    cid: field.cid,
                    title: field.title,
                    detail: "图片字段的值必须是 URL 字符串数组"
                )
            }
            var cleanURLs: [String] = []
            var details: [ImageDetail] = []
            for element in arr {
                guard let rawURL = element.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !rawURL.isEmpty else {
                    continue
                }
                cleanURLs.append(rawURL)
                details.append(ImageDetail(url: rawURL, fileName: fileName(from: rawURL)))
            }
            if cleanURLs.isEmpty && field.must {
                throw PayloadBuildError.invalidFieldValue(
                    cid: field.cid,
                    title: field.title,
                    detail: "必填图片字段至少需要一个有效图片 URL"
                )
            }
            return CatalogValue(
                cid: field.cid,
                type: field.type,
                value: .array(cleanURLs.map { .string($0) }),
                imageDetails: details.isEmpty ? nil : details
            )

        case "AREA":
            guard var dict = value.objectValue else {
                throw PayloadBuildError.invalidFieldValue(
                    cid: field.cid,
                    title: field.title,
                    detail: #"地区字段必须为对象 {"province","city","district","address"}"#
                )
            }
            for key in ["province", "city", "district", "address"] where dict[key] == nil {
                dict[key] = .string("")
            }
            return CatalogValue(cid: field.cid, type: field.type, value: .object(dict))

        case "MULTI_LEVEL_SELECT":
            guard let dict = value.objectValue else {
                throw PayloadBuildError.invalidFieldValue(
                    cid: field.cid,
                    title: field.title,
                    detail: #"多级选择字段必须为对象 {"pathCids":[...]}"#
                )
            }
            guard dict["pathCids"] != nil else {
                throw PayloadBuildError.invalidFieldValue(
                    cid: field.cid,
                    title: field.title,
                    detail: "多级选择字段缺少 pathCids 字段"
                )
            }
            return CatalogValue(cid: field.cid, type: field.type, value: .object(dict))

        case "RADIO_V2", "RADIO":
            if let cid = value.stringValue {
                return CatalogValue(
                    cid: field.cid,
                    type: field.type,
                    value: .object(["cid": .string(cid), "customValue": .string("")])
                )
            }
            return CatalogValue(cid: field.cid, type: field.type, value: value)

        case "CHECKBOX_V2", "CHECKBOX", "CHOICE":
            if let arr = value.arrayValue {
                let normalized: [JSONValue] = arr.map { elem in
                    if let cid = elem.stringValue {
                        return .object(["cid": .string(cid), "customValue": .string("")])
                    }
                    return elem
                }
                return CatalogValue(cid: field.cid, type: field.type, value: .array(normalized))
            }
            return CatalogValue(cid: field.cid, type: field.type, value: value)

        default:
            return CatalogValue(cid: field.cid, type: field.type, value: value)
        }
    }

    private static func buildDefaultItem(
        field: FormField,
        draft: CheckinDraft,
        resolvedPoint: GeoPoint?,
        resolvedAddr: String,
        resolvedTitle: String,
        now: Date,
        timeZone: TimeZone
    ) throws -> (item: CatalogValue?, warning: String?) {
        let ft = field.normalizedType

        switch ft {
        case "LOCATION":
            guard let pt = resolvedPoint else {
                if field.must {
                    throw PayloadBuildError.invalidCoordinate(
                        "必填定位字段 \(field.cid)（\(field.title)）缺少有效经纬度坐标"
                    )
                }
                return (nil, nil)
            }

            let spec = GeoMath.extractSpecifiedLocation(from: field.config)
            var warning: String?
            if let spec, spec.locationType == .specified, !spec.anchors.isEmpty {
                let effectiveAnchors: [LocationAnchor]
                if let idx = draft.anchorIndex, spec.anchors.indices.contains(idx) {
                    effectiveAnchors = [spec.anchors[idx]]
                } else {
                    effectiveAnchors = spec.anchors
                }
                if let match = GeoMath.pickNearestAnchor(userPoint: pt, anchors: effectiveAnchors),
                   !match.isWithinScope {
                    warning = "定位字段 \(field.cid) 距围栏锚点「\(match.anchor.displayName)」约 \(Int(match.distanceMeters.rounded()))m（允许范围 \(Int(match.anchor.scope.rounded()))m），服务端可能校验失败"
                }
            }

            let locVal = GeoMath.buildLocationValue(
                userPoint: pt,
                addr: resolvedAddr,
                title: resolvedTitle,
                specified: spec,
                anchorIndex: draft.anchorIndex
            )
            return (CatalogValue(cid: field.cid, type: field.type, value: locVal.toJSONValue()), warning)

        case "WORD":
            guard field.must else { return (nil, nil) }
            if let preset = field.presetNameList, preset.fillType.isChooseOnly {
                return (nil, nil)
            }
            let trimmedDefault = draft.defaultText.trimmingCharacters(in: .whitespacesAndNewlines)
            let text = trimmedDefault.isEmpty ? "签到" : draft.defaultText
            return (CatalogValue(cid: field.cid, type: field.type, value: .string(text)), nil)

        case "RADIO_V2", "RADIO":
            guard field.must else { return (nil, nil) }
            let options = field.options
            guard let first = options.first, !draft.noAutoOption else {
                return (nil, nil)
            }
            let val: JSONValue = .object(["cid": .string(first), "customValue": .string("")])
            let warn = "字段 \(field.cid)（\(field.title)）未指定答案，已自动选择第一个选项 \(first)"
            return (CatalogValue(cid: field.cid, type: field.type, value: val), warn)

        case "CHECKBOX_V2", "CHECKBOX", "CHOICE":
            guard field.must else { return (nil, nil) }
            let options = field.options
            guard let first = options.first, !draft.noAutoOption else {
                return (nil, nil)
            }
            let val: JSONValue = .array([.object(["cid": .string(first), "customValue": .string("")])])
            let warn = "字段 \(field.cid)（\(field.title)）未指定答案，已自动选择第一个选项 \(first)"
            return (CatalogValue(cid: field.cid, type: field.type, value: val), warn)

        case "DATE":
            guard field.must else { return (nil, nil) }
            let formatted = formatDateValue(now, timeZone: timeZone)
            return (CatalogValue(cid: field.cid, type: field.type, value: .string(formatted)), nil)

        default:
            if nonAutoFillableTypes.contains(ft) {
                return (nil, nil)
            }
            if field.must {
                return (nil, "字段 \(field.cid) 类型 \(field.type) 不支持自动填写")
            }
            return (nil, nil)
        }
    }

    private static func requiredFieldError(for field: FormField) -> PayloadBuildError {
        if field.hasPresetNameList {
            return .missingRequiredField(cid: field.cid, title: field.title, type: field.type, hint: "请从预设名单中选择一项")
        }
        let hint: String
        switch field.normalizedType {
        case "AREA":
            hint = #"请提供省市区对象 {"province":"","city":"","district":"","address":""}"#
        case "MULTI_LEVEL_SELECT":
            hint = #"请提供多级选择对象 {"pathCids":["..."]}"#
        case "NUMBER", "NUMBER_FLOAT", "DIGIT":
            hint = "请提供合法数值"
        case "TELEPHONE":
            hint = "请提供合法手机号/电话号码"
        case "ID_CARD":
            hint = "请提供合法身份证号"
        case "EMAIL":
            hint = "请提供合法电子邮箱"
        case "URL":
            hint = "请提供合法网址"
        case "BANK_CARD":
            hint = "请提供合法银行卡号"
        case "IMAGE":
            hint = "请提供图片 URL 数组"
        case "RADIO_V2", "RADIO":
            hint = "请选择一个选项"
        case "CHECKBOX_V2", "CHECKBOX", "CHOICE":
            hint = "请至少选择一个选项"
        default:
            hint = "请在表单中填写该字段"
        }
        return .missingRequiredField(cid: field.cid, title: field.title, type: field.type, hint: hint)
    }
}
