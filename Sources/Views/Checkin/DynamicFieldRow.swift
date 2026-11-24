import SwiftUI
import UIKit

/// Mutable location editor draft bound to `LOCATION` fields inside `CheckinView`.
struct LocationFieldState: Equatable {
    var latText: String = ""
    var lngText: String = ""
    var addr: String = ""
    var title: String = ""
    var wgs84: Bool = false
    var jitterMeters: Double = 15
    var usePOIPool: Bool = false
    var anchorIndex: Int? = nil

    var parsedLat: Double {
        Double(latText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    var parsedLng: Double {
        Double(lngText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    var gcj02PreviewPoint: GeoPoint? {
        let lat = parsedLat
        let lng = parsedLng
        guard (try? GeoMath.validateCoord(lat: lat, lng: lng)) != nil else {
            return nil
        }
        let raw = GeoPoint(lat: lat, lng: lng)
        return wgs84 ? GeoMath.wgs84ToGCJ02(raw) : raw
    }

    mutating func applyMapSelection(_ selection: MapPickerSelection) {
        let outputPoint = wgs84 ? GeoMath.gcj02ToWGS84(selection.point) : selection.point
        latText = String(format: "%.6f", outputPoint.lat)
        lngText = String(format: "%.6f", outputPoint.lng)
        addr = selection.addr
        title = selection.title
        usePOIPool = false
    }

    mutating func applyPOI(_ poi: POIItem) {
        latText = String(format: "%.6f", poi.lat)
        lngText = String(format: "%.6f", poi.lng)
        addr = poi.addr
        title = poi.title
        wgs84 = poi.wgs84
        usePOIPool = false
    }
}

/// Renders native SwiftUI controls for every supported LaiBao / QunBaoShu dynamic field type.
struct DynamicFieldRow: View {
    let field: FormField
    @Binding var fieldValues: [String: JSONValue]
    @Binding var locationState: LocationFieldState
    let savedPOIs: [POIItem]
    let onOpenMapPicker: (FormField) -> Void

    @State private var newImageURL: String = ""
    @State private var dateSelection: Date = Date()
    @State private var dateInitialized: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            fieldHeader

            switch field.normalizedType {
            case "LOCATION":
                locationEditor
            case "WORD":
                wordEditor
            case "RADIO_V2", "RADIO":
                radioEditor
            case "CHECKBOX_V2", "CHECKBOX", "CHOICE":
                checkboxEditor
            case "DATE":
                dateEditor
            case "AREA":
                areaEditor
            case "MULTI_LEVEL_SELECT":
                multiLevelEditor
            case "IMAGE":
                imageEditor
            case "NUMBER", "NUMBER_FLOAT", "DIGIT":
                typedTextEditor(placeholder: "请输入数值", keyboard: .decimalPad)
            case "TELEPHONE":
                typedTextEditor(placeholder: "请输入手机号或电话号码", keyboard: .phonePad)
            case "ID_CARD":
                typedTextEditor(placeholder: "请输入身份证号", keyboard: .asciiCapable)
            case "EMAIL":
                typedTextEditor(placeholder: "请输入电子邮箱", keyboard: .emailAddress)
            case "URL":
                typedTextEditor(placeholder: "请输入网址（https://...）", keyboard: .URL)
            case "BANK_CARD":
                typedTextEditor(placeholder: "请输入银行卡号", keyboard: .numberPad)
            default:
                wordEditor
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Header

    private var fieldHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if field.must {
                Text("*")
                    .font(.headline)
                    .foregroundStyle(.red)
            }
            Text(field.title)
                .font(.headline)
            Spacer()
            Text(field.type)
                .font(.caption2.monospaced())
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Color(.tertiarySystemFill), in: Capsule())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - LOCATION

    @ViewBuilder
    private var locationEditor: some View {
        let spec = field.specifiedLocation

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                GlassStatusPill(
                    title: spec?.locationType.displayName ?? LocationType.free.displayName,
                    systemImage: "location.circle.fill",
                    tint: spec?.locationType == .specified ? .green : .blue
                )
                if let match = currentAnchorMatch(spec: spec) {
                    let dist = Int(match.distanceMeters.rounded())
                    let scope = Int(match.anchor.scope.rounded())
                    GlassStatusPill(
                        title: match.isWithinScope ? "围栏内 \(dist)/\(scope)m" : "超出 \(dist)/\(scope)m",
                        systemImage: match.isWithinScope ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: match.isWithinScope ? .green : .orange
                    )
                }
            }

            if let spec, spec.locationType == .specified, !spec.anchors.isEmpty {
                if spec.anchors.count > 1 {
                    Picker("指定围栏锚点", selection: $locationState.anchorIndex) {
                        Text("自动匹配最近锚点").tag(Int?.none)
                        ForEach(spec.anchors.indices, id: \.self) { idx in
                            let anchor = spec.anchors[idx]
                            Text("\(anchor.displayName)（\(Int(anchor.scope))m）")
                                .tag(Optional(idx))
                        }
                    }
                    .pickerStyle(.menu)
                } else if let anchor = spec.anchors.first {
                    Text("围栏中心：\(anchor.displayName) · 半径 \(Int(anchor.scope)) 米")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("从 POI 点位池随机抽取（共 \(savedPOIs.count) 个）", isOn: $locationState.usePOIPool)
                .font(.subheadline)

            if !locationState.usePOIPool {
                HStack(spacing: 8) {
                    Button {
                        onOpenMapPicker(field)
                    } label: {
                        Label("地图选点", systemImage: "map.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                    if !savedPOIs.isEmpty {
                        Menu {
                            ForEach(savedPOIs) { poi in
                                Button(poi.title.isEmpty ? poi.addr : poi.title) {
                                    locationState.applyPOI(poi)
                                }
                            }
                        } label: {
                            Label("选择 POI", systemImage: "mappin.and.ellipse")
                                .font(.subheadline)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }

                HStack(spacing: 8) {
                    TextField("纬度 lat", text: $locationState.latText)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                    TextField("经度 lng", text: $locationState.lngText)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                        .padding(8)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }

                Toggle("输入为 WGS-84 坐标（提交自动转 GCJ-02）", isOn: $locationState.wgs84)
                    .font(.caption)

                TextField("地点名称（title）", text: $locationState.title)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                TextField("详细地址（address）", text: $locationState.addr)
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("随机抖动半径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(locationState.jitterMeters)) 米")
                        .font(.caption.monospacedDigit().weight(.semibold))
                }
                Slider(value: $locationState.jitterMeters, in: 0...200, step: 5)
            }
        }
    }

    private func currentAnchorMatch(spec: SpecifiedLocation?) -> AnchorMatch? {
        guard let spec, spec.locationType == .specified, !spec.anchors.isEmpty,
              let pt = locationState.gcj02PreviewPoint else {
            return nil
        }
        if let idx = locationState.anchorIndex, spec.anchors.indices.contains(idx) {
            return GeoMath.pickNearestAnchor(userPoint: pt, anchors: [spec.anchors[idx]])
        }
        return GeoMath.pickNearestAnchor(userPoint: pt, anchors: spec.anchors)
    }

    // MARK: - WORD & Typed Text

    private var wordEditor: some View {
        TextField(
            field.must ? "必填文本（留空时仅 WORD 类型默认填「签到」）" : "选填文本",
            text: stringValueBinding,
            axis: .vertical
        )
        .lineLimit(2...5)
        .padding(10)
        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private func typedTextEditor(placeholder: String, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: stringValueBinding)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }

    private var stringValueBinding: Binding<String> {
        Binding(
            get: {
                fieldValues[field.cid]?.stringValue
                    ?? fieldValues[field.cid]?.coercedStringValue
                    ?? ""
            },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    fieldValues.removeValue(forKey: field.cid)
                } else {
                    fieldValues[field.cid] = .string(newValue)
                }
            }
        )
    }

    // MARK: - RADIO

    @ViewBuilder
    private var radioEditor: some View {
        let options = field.optionItems
        if options.isEmpty {
            typedTextEditor(placeholder: "输入选项 cid", keyboard: .default)
        } else {
            let selectedCID = currentSelectedRadioCID
            VStack(spacing: 6) {
                ForEach(options) { option in
                    let isSelected = selectedCID == option.cid
                    Button {
                        if isSelected && !field.must {
                            fieldValues.removeValue(forKey: field.cid)
                        } else {
                            fieldValues[field.cid] = .object([
                                "cid": .string(option.cid),
                                "customValue": .string("")
                            ])
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(option.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var currentSelectedRadioCID: String {
        guard let val = fieldValues[field.cid] else { return "" }
        if let s = val.stringValue { return s }
        return val["cid"]?.coercedStringValue ?? ""
    }

    // MARK: - CHECKBOX

    @ViewBuilder
    private var checkboxEditor: some View {
        let options = field.optionItems
        if options.isEmpty {
            typedTextEditor(placeholder: "输入选项 cid", keyboard: .default)
        } else {
            let selectedSet = currentSelectedCheckboxCIDs
            VStack(spacing: 6) {
                ForEach(options) { option in
                    let isSelected = selectedSet.contains(option.cid)
                    Button {
                        var next = selectedSet
                        if isSelected {
                            next.remove(option.cid)
                        } else {
                            next.insert(option.cid)
                        }
                        let ordered = options.map(\.cid).filter { next.contains($0) }
                        if ordered.isEmpty {
                            fieldValues.removeValue(forKey: field.cid)
                        } else {
                            fieldValues[field.cid] = .array(
                                ordered.map { .object(["cid": .string($0), "customValue": .string("")]) }
                            )
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(option.label)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer()
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill).opacity(0.6),
                            in: RoundedRectangle(cornerRadius: 10)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var currentSelectedCheckboxCIDs: Set<String> {
        guard let arr = fieldValues[field.cid]?.arrayValue else { return [] }
        var set = Set<String>()
        for elem in arr {
            if let s = elem.stringValue, !s.isEmpty {
                set.insert(s)
            } else if let cid = elem["cid"]?.coercedStringValue, !cid.isEmpty {
                set.insert(cid)
            }
        }
        return set
    }

    // MARK: - DATE (`YYYY-MM-DD HH:mm`)

    private var dateEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            let currentText = fieldValues[field.cid]?.stringValue ?? ""
            DatePicker(
                "选择时间",
                selection: Binding(
                    get: {
                        if let parsed = Self.parseDateString(currentText) {
                            return parsed
                        }
                        return dateSelection
                    },
                    set: { newDate in
                        dateSelection = newDate
                        fieldValues[field.cid] = .string(PayloadBuilder.formatDateValue(newDate))
                    }
                ),
                displayedComponents: [.date, .hourAndMinute]
            )
            .datePickerStyle(.compact)

            HStack(spacing: 8) {
                Text(currentText.isEmpty ? "提交时自动填入当前时间（YYYY-MM-DD HH:mm）" : "提交值：\(currentText)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("此刻") {
                    let now = Date()
                    dateSelection = now
                    fieldValues[field.cid] = .string(PayloadBuilder.formatDateValue(now))
                }
                .buttonStyle(.glass)
                .controlSize(.mini)

                if !currentText.isEmpty && !field.must {
                    Button("清空") {
                        fieldValues.removeValue(forKey: field.cid)
                    }
                    .buttonStyle(.glass)
                    .controlSize(.mini)
                }
            }
        }
        .onAppear {
            if !dateInitialized {
                dateInitialized = true
                if let existing = fieldValues[field.cid]?.stringValue,
                   let parsed = Self.parseDateString(existing) {
                    dateSelection = parsed
                }
            }
        }
    }

    private static func parseDateString(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = fmt
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }

    // MARK: - AREA (4 fields)

    private var areaEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("省（province）", text: areaBinding("province"))
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                TextField("市（city）", text: areaBinding("city"))
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
            TextField("区 / 县（district）", text: areaBinding("district"))
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            TextField("详细地址（address）", text: areaBinding("address"))
                .padding(8)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func areaBinding(_ key: String) -> Binding<String> {
        Binding(
            get: {
                fieldValues[field.cid]?[key]?.stringValue ?? ""
            },
            set: { newValue in
                var dict = fieldValues[field.cid]?.objectValue ?? [
                    "province": .string(""),
                    "city": .string(""),
                    "district": .string(""),
                    "address": .string("")
                ]
                dict[key] = .string(newValue)
                let allEmpty = ["province", "city", "district", "address"].allSatisfy {
                    (dict[$0]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                if allEmpty {
                    fieldValues.removeValue(forKey: field.cid)
                } else {
                    fieldValues[field.cid] = .object(dict)
                }
            }
        )
    }

    // MARK: - MULTI_LEVEL_SELECT

    private var multiLevelEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextField("输入 pathCids（逗号分隔，例如 cid1,cid2）", text: Binding(
                get: {
                    let arr = fieldValues[field.cid]?["pathCids"]?.arrayValue ?? []
                    return arr.compactMap(\.coercedStringValue).joined(separator: ",")
                },
                set: { newValue in
                    let parts = newValue
                        .split(separator: ",")
                        .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                    if parts.isEmpty {
                        fieldValues.removeValue(forKey: field.cid)
                    } else {
                        fieldValues[field.cid] = .object([
                            "pathCids": .array(parts.map { .string($0) })
                        ])
                    }
                }
            ))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.body.monospaced())
            .padding(10)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))

            Text(#"提交格式：{"pathCids": ["..."]}"#)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - IMAGE URL List

    private var imageEditor: some View {
        let urls = currentImageURLs
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(urls.indices, id: \.self) { idx in
                let url = urls[idx]
                HStack(spacing: 8) {
                    Image(systemName: "photo")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PayloadBuilder.fileName(from: url))
                            .font(.caption.weight(.medium))
                        Text(url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(role: .destructive) {
                        var next = urls
                        next.remove(at: idx)
                        saveImageURLs(next)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                }
                .padding(8)
                .background(Color(.tertiarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
            }

            HStack(spacing: 8) {
                TextField("粘贴图片 URL（https://...）", text: $newImageURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(8)
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))

                Button("添加") {
                    let trimmed = newImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    saveImageURLs(urls + [trimmed])
                    newImageURL = ""
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        saveImageURLs(urls + [pasted])
                    }
                } label: {
                    Image(systemName: "doc.on.clipboard")
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .accessibilityLabel("粘贴图片链接")
            }
        }
    }

    private var currentImageURLs: [String] {
        (fieldValues[field.cid]?.arrayValue ?? []).compactMap {
            $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func saveImageURLs(_ urls: [String]) {
        if urls.isEmpty {
            fieldValues.removeValue(forKey: field.cid)
        } else {
            fieldValues[field.cid] = .array(urls.map { .string($0) })
        }
    }
}
