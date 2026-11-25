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

    mutating func applyAnchor(_ anchor: LocationAnchor) {
        let outputPoint = wgs84 ? GeoMath.gcj02ToWGS84(anchor.point) : anchor.point
        latText = String(format: "%.6f", outputPoint.lat)
        lngText = String(format: "%.6f", outputPoint.lng)
        addr = anchor.address.isEmpty ? anchor.specifiedAddress : anchor.address
        title = anchor.specifiedAddress.isEmpty ? anchor.address : anchor.specifiedAddress
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
    @State private var imageHint: String?
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
        .padding(.vertical, 6)
    }

    // MARK: - Header

    private var fieldHeader: some View {
        let presentation = FieldTypePresentation.forType(field.normalizedType)
        return HStack(alignment: .top, spacing: 8) {
            Text(field.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 6)

            HStack(spacing: 5) {
                if field.must {
                    StatusBadge(title: "必填", tint: .red)
                }
                StatusBadge(
                    title: presentation.label,
                    systemImage: presentation.systemImage,
                    tint: presentation.tint
                )
            }
        }
    }

    // MARK: - LOCATION

    @ViewBuilder
    private var locationEditor: some View {
        let spec = field.specifiedLocation

        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                StatusBadge(
                    title: spec?.locationType.displayName ?? LocationType.free.displayName,
                    systemImage: "location.circle.fill",
                    tint: spec?.locationType == .specified ? Color.green : Color.blue
                )
                if let match = currentAnchorMatch(spec: spec) {
                    let dist = Int(match.distanceMeters.rounded())
                    let scope = Int(match.anchor.scope.rounded())
                    StatusBadge(
                        title: match.isWithinScope ? "围栏内 \(dist)/\(scope)m" : "超出 \(dist)/\(scope)m",
                        systemImage: match.isWithinScope ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                        tint: match.isWithinScope ? Color.green : Color.orange,
                        monospaced: true
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
                    .font(.subheadline)
                } else if let anchor = spec.anchors.first {
                    Text("围栏中心：\(anchor.displayName) · 半径 \(Int(anchor.scope)) 米")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Toggle("从 POI 点位池随机抽取（共 \(savedPOIs.count) 个）", isOn: $locationState.usePOIPool)
                .font(.subheadline)

            if locationState.usePOIPool {
                if savedPOIs.isEmpty {
                    InlineFeedbackBanner(
                        message: "当前 POI 点位池为空，请先在「点位」页添加常用点位，或关闭此开关手动选点。",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: .orange
                    )
                }
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    Button {
                        onOpenMapPicker(field)
                    } label: {
                        Label("地图选点", systemImage: "map.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)

                    if let spec, spec.locationType == .specified, let targetAnchor = preferredAnchor(for: spec) {
                        Button {
                            withAnimation(.snappy(duration: 0.2)) {
                                locationState.applyAnchor(targetAnchor)
                                fieldValues.removeValue(forKey: field.cid)
                            }
                        } label: {
                            Label("填入围栏中心", systemImage: "scope")
                                .font(.subheadline)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }

                    if !savedPOIs.isEmpty {
                        Menu {
                            ForEach(savedPOIs) { poi in
                                Button(poi.title.isEmpty ? poi.addr : poi.title) {
                                    locationState.applyPOI(poi)
                                    fieldValues.removeValue(forKey: field.cid)
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
                    VStack(alignment: .leading, spacing: 4) {
                        Text("纬度 Lat")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("39.908823", text: $locationState.latText)
                            .keyboardType(.decimalPad)
                            .font(.subheadline.monospaced())
                            .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("经度 Lng")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField("116.397470", text: $locationState.lngText)
                            .keyboardType(.decimalPad)
                            .font(.subheadline.monospaced())
                            .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                    }
                }

                Toggle("输入为 WGS-84 坐标（提交自动转 GCJ-02）", isOn: $locationState.wgs84)
                    .font(.caption)

                if locationState.wgs84, let gcj = locationState.gcj02PreviewPoint {
                    Text("实际提交 GCJ-02：\(gcj.formatted)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("地点名称（title）")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("如：教学楼 / 写字楼名称", text: $locationState.title)
                        .font(.subheadline)
                        .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("详细地址（address）")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("省市区街道门牌号", text: $locationState.addr)
                        .font(.subheadline)
                        .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("随机抖动半径")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusBadge(
                        title: "±\(Int(locationState.jitterMeters)) m",
                        tint: locationState.jitterMeters > 0 ? Color.orange : Color.secondary,
                        monospaced: true
                    )
                }
                Slider(value: $locationState.jitterMeters, in: 0...200, step: 5)
            }
        }
    }

    private func preferredAnchor(for spec: SpecifiedLocation) -> LocationAnchor? {
        if let idx = locationState.anchorIndex, spec.anchors.indices.contains(idx) {
            return spec.anchors[idx]
        }
        return spec.anchors.first
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
        .mobileInputField()
    }

    private func typedTextEditor(placeholder: String, keyboard: UIKeyboardType) -> some View {
        TextField(placeholder, text: stringValueBinding)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .mobileInputField()
    }

    private var stringValueBinding: Binding<String> {
        Binding(
            get: {
                fieldValues[field.cid]?.stringValue
                    ?? fieldValues[field.cid]?.coercedStringValue
                    ?? ""
            },
            set: { newValue in
                if newValue.isEmpty {
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
            VStack(spacing: 8) {
                ForEach(options) { option in
                    let isSelected = selectedCID == option.cid
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if isSelected && !field.must {
                                fieldValues.removeValue(forKey: field.cid)
                            } else {
                                fieldValues[field.cid] = .object([
                                    "cid": .string(option.cid),
                                    "customValue": .string("")
                                ])
                            }
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                                .font(.body)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(option.label)
                                .font(.subheadline.weight(isSelected ? .medium : .regular))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
            VStack(spacing: 8) {
                ForEach(options) { option in
                    let isSelected = selectedSet.contains(option.cid)
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
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
                        }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                                .font(.body)
                                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                            Text(option.label)
                                .font(.subheadline.weight(isSelected ? .medium : .regular))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .frame(minHeight: 44)
                        .background(
                            isSelected ? Color.accentColor.opacity(0.12) : Color(.tertiarySystemFill).opacity(0.55),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
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
                        if let parsed = UIFormatters.parseFlexibleDate(currentText) {
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
                Text(currentText.isEmpty ? "留空将自动填当前时间" : currentText)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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
                   let parsed = UIFormatters.parseFlexibleDate(existing) {
                    dateSelection = parsed
                }
            }
        }
    }

    // MARK: - AREA (4 fields)

    private var areaEditor: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                TextField("省（province）", text: areaBinding("province"))
                    .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
                TextField("市（city）", text: areaBinding("city"))
                    .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
            }
            TextField("区 / 县（district）", text: areaBinding("district"))
                .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
            TextField("详细地址（address）", text: areaBinding("address"))
                .mobileInputField(verticalPadding: 8, horizontalPadding: 10)
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
            .font(.subheadline.monospaced())
            .mobileInputField()

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
                HStack(spacing: 10) {
                    AsyncImage(url: URL(string: url)) { phase in
                        switch phase {
                        case .success(let image):
                            image
                                .resizable()
                                .scaledToFill()
                        default:
                            ZStack {
                                Color(.tertiarySystemFill)
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(width: 44, height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text(PayloadBuilder.fileName(from: url))
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                        Text(url)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    Button(role: .destructive) {
                        var next = urls
                        next.remove(at: idx)
                        saveImageURLs(next)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("移除图片")
                }
                .padding(8)
                .background(
                    Color(.tertiarySystemFill).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
            }

            TextField("输入或粘贴图片 URL（https://...）", text: $newImageURL)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline)
                .mobileInputField(verticalPadding: 8, horizontalPadding: 10)

            HStack(spacing: 8) {
                Button {
                    let trimmed = newImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        imageHint = "请先输入图片链接"
                        return
                    }
                    imageHint = nil
                    saveImageURLs(urls + [trimmed])
                    newImageURL = ""
                } label: {
                    Label("添加链接", systemImage: "plus")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.glass)
                .controlSize(.small)

                Button {
                    if let pasted = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        imageHint = nil
                        saveImageURLs(urls + [pasted])
                    } else {
                        imageHint = "剪贴板为空"
                    }
                } label: {
                    Label("从剪贴板粘贴", systemImage: "doc.on.clipboard")
                        .font(.caption)
                }
                .buttonStyle(.glass)
                .controlSize(.small)
            }

            if let imageHint {
                Text(imageHint)
                    .font(.caption2)
                    .foregroundStyle(.orange)
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
