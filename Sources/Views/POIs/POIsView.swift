import SwiftUI
import UIKit

/// Saved POI pool management + native MapKit POI picker + GCJ-02 <-> WGS-84 converter & distance calculator.
struct POIsView: View {
    private enum ConvertDirection: String, CaseIterable, Hashable, Sendable {
        case gcjToWgs
        case wgsToGcj

        var title: String {
            switch self {
            case .gcjToWgs: return "GCJ-02 → WGS-84"
            case .wgsToGcj: return "WGS-84 → GCJ-02"
            }
        }
    }

    @Environment(AppState.self) private var appState

    @State private var showMapAddPOI = false
    @State private var showManualAddPOI = false
    @State private var editingPOI: POIItem?

    // Coordinate converter state
    @State private var convertDirection: ConvertDirection = .gcjToWgs
    @State private var convLatText: String = "39.908823"
    @State private var convLngText: String = "116.397470"

    // Distance calculator state
    @State private var distLatA: String = ""
    @State private var distLngA: String = ""
    @State private var distLatB: String = ""
    @State private var distLngB: String = ""

    var body: some View {
        NavigationStack {
            List {
                quickAddSection
                poiPoolSection
                coordinateConverterSection
                distanceCalculatorSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("点位与工具")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showMapAddPOI = true
                    } label: {
                        Label("地图选点新增", systemImage: "mappin.and.ellipse")
                    }
                }
            }
            .sheet(isPresented: $showMapAddPOI) {
                MapPickerSheet(
                    savedPOIs: appState.pois,
                    confirmButtonTitle: "保存为新 POI"
                ) { selection in
                    let item = POIItem(
                        lat: selection.point.lat,
                        lng: selection.point.lng,
                        addr: selection.addr,
                        title: selection.title,
                        wgs84: false
                    )
                    savePOI(item)
                }
            }
            .sheet(isPresented: $showManualAddPOI) {
                POIEditorSheet(existingPOI: nil) { item in
                    savePOI(item)
                }
            }
            .sheet(item: $editingPOI) { poi in
                POIEditorSheet(existingPOI: poi) { item in
                    savePOI(item)
                }
            }
        }
    }

    // MARK: - Sections

    private var quickAddSection: some View {
        Section {
            HStack(spacing: 10) {
                Button {
                    showMapAddPOI = true
                } label: {
                    Label("地图选点新增 POI", systemImage: "map.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)

                Button {
                    showManualAddPOI = true
                } label: {
                    Label("手动录入", systemImage: "plus.circle")
                        .font(.subheadline)
                }
                .buttonStyle(.glass)
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
        }
    }

    private var poiPoolSection: some View {
        Section("已保存 POI 点位池（\(appState.pois.count)）") {
            if appState.pois.isEmpty {
                ContentUnavailableView(
                    "点位池为空",
                    systemImage: "mappin.slash",
                    description: Text("添加常用打卡点位后，可在动态填报与提醒计划中一键选用或随机抽取。")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(appState.pois) { poi in
                    Button {
                        editingPOI = poi
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(poi.title.isEmpty ? "未命名点位" : poi.title)
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Spacer()
                                GlassStatusPill(
                                    title: poi.wgs84 ? "WGS-84" : "GCJ-02",
                                    tint: poi.wgs84 ? .orange : .blue
                                )
                            }
                            if !poi.addr.isEmpty {
                                Text(poi.addr)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text("GCJ-02：\(poi.gcj02Point.formatted)")
                                Text("WGS-84：\(poi.wgs84Point.formatted)")
                            }
                            .font(.caption.monospaced())
                            .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 3)
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deletePOI(poi)
                        } label: {
                            Label("删除", systemImage: "trash")
                        }
                    }
                }
            }
        }
    }

    private var coordinateConverterSection: some View {
        Section("坐标系转换工具（GCJ-02 ↔ WGS-84）") {
            GlassSegmentedControl(
                items: ConvertDirection.allCases,
                selection: $convertDirection,
                title: \.title,
                tint: .accentColor
            )
            .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))

            HStack(spacing: 8) {
                TextField("纬度 lat", text: $convLatText)
                    .keyboardType(.decimalPad)
                    .font(.body.monospaced())
                Divider()
                TextField("经度 lng", text: $convLngText)
                    .keyboardType(.decimalPad)
                    .font(.body.monospaced())
            }

            if let converted = convertedCoordinate {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(convertDirection == .gcjToWgs ? "转换结果（WGS-84）" : "转换结果（GCJ-02）")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(converted.point.formatted)
                            .font(.body.monospaced().weight(.semibold))
                            .textSelection(.enabled)
                        if converted.outOfChina {
                            Text("该坐标位于中国大陆范围外，不施加 GCJ-02 偏移")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button {
                        UIPasteboard.general.string = converted.point.formatted
                        appState.showToast("已复制转换坐标 \(converted.point.formatted)")
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }
            } else {
                Text("请输入合法的非零经纬度（纬度 -90~90，经度 -180~180）")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var distanceCalculatorSection: some View {
        Section("两点 Haversine 距离计算") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("点 A")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !appState.pois.isEmpty {
                        Menu("从 POI 填充") {
                            ForEach(appState.pois) { poi in
                                Button(poi.title.isEmpty ? poi.addr : poi.title) {
                                    let gcj = poi.gcj02Point
                                    distLatA = String(format: "%.6f", gcj.lat)
                                    distLngA = String(format: "%.6f", gcj.lng)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
                HStack(spacing: 8) {
                    TextField("纬度 A", text: $distLatA)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                    Divider()
                    TextField("经度 A", text: $distLngA)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("点 B")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !appState.pois.isEmpty {
                        Menu("从 POI 填充") {
                            ForEach(appState.pois) { poi in
                                Button(poi.title.isEmpty ? poi.addr : poi.title) {
                                    let gcj = poi.gcj02Point
                                    distLatB = String(format: "%.6f", gcj.lat)
                                    distLngB = String(format: "%.6f", gcj.lng)
                                }
                            }
                        }
                        .font(.caption)
                    }
                }
                HStack(spacing: 8) {
                    TextField("纬度 B", text: $distLatB)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                    Divider()
                    TextField("经度 B", text: $distLngB)
                        .keyboardType(.decimalPad)
                        .font(.body.monospaced())
                }
            }

            if let dist = calculatedDistanceMeters {
                HStack {
                    Text("球面直线距离")
                        .font(.subheadline)
                    Spacer()
                    GlassStatusPill(
                        title: dist >= 1000
                            ? String(format: "%.2f 米（%.3f km）", dist, dist / 1000.0)
                            : String(format: "%.2f 米", dist),
                        systemImage: "ruler",
                        tint: .green
                    )
                }
            }
        }
    }

    // MARK: - Computed & Actions

    private var convertedCoordinate: (point: GeoPoint, outOfChina: Bool)? {
        guard let lat = Double(convLatText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(convLngText.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? GeoMath.validateCoord(lat: lat, lng: lng)) != nil else {
            return nil
        }
        let input = GeoPoint(lat: lat, lng: lng)
        let out = GeoMath.outOfChina(input)
        let converted = convertDirection == .gcjToWgs
            ? GeoMath.gcj02ToWGS84(input)
            : GeoMath.wgs84ToGCJ02(input)
        return (point: converted, outOfChina: out)
    }

    private var calculatedDistanceMeters: Double? {
        guard let latA = Double(distLatA.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lngA = Double(distLngA.trimmingCharacters(in: .whitespacesAndNewlines)),
              let latB = Double(distLatB.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lngB = Double(distLngB.trimmingCharacters(in: .whitespacesAndNewlines)),
              (try? GeoMath.validateCoord(lat: latA, lng: lngA)) != nil,
              (try? GeoMath.validateCoord(lat: latB, lng: lngB)) != nil else {
            return nil
        }
        return GeoMath.distanceMeters(GeoPoint(lat: latA, lng: lngA), GeoPoint(lat: latB, lng: lngB))
    }

    private func savePOI(_ poi: POIItem) {
        do {
            _ = try appState.workspaceStore.upsertPOI(poi)
            appState.refreshWorkspace()
            appState.showToast("已保存点位「\(poi.title.isEmpty ? poi.gcj02Point.formatted : poi.title)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }

    private func deletePOI(_ poi: POIItem) {
        do {
            _ = try appState.workspaceStore.deletePOI(id: poi.id)
            appState.refreshWorkspace()
            appState.showToast("已删除点位「\(poi.title)」")
        } catch {
            appState.showToast(error.localizedDescription, isError: true)
        }
    }
}

// MARK: - POI Editor Sheet

private struct POIEditorSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    let existingPOI: POIItem?
    let onSave: (POIItem) -> Void

    @State private var title: String
    @State private var addr: String
    @State private var latText: String
    @State private var lngText: String
    @State private var wgs84: Bool
    @State private var showMapPicker: Bool = false
    @State private var errorMessage: String?

    init(existingPOI: POIItem?, onSave: @escaping (POIItem) -> Void) {
        self.existingPOI = existingPOI
        self.onSave = onSave
        _title = State(initialValue: existingPOI?.title ?? "")
        _addr = State(initialValue: existingPOI?.addr ?? "")
        _latText = State(initialValue: existingPOI.map { String(format: "%.6f", $0.lat) } ?? "")
        _lngText = State(initialValue: existingPOI.map { String(format: "%.6f", $0.lng) } ?? "")
        _wgs84 = State(initialValue: existingPOI?.wgs84 ?? false)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("点位信息") {
                    TextField("点位名称（title）", text: $title)
                    TextField("详细地址（address）", text: $addr)
                    HStack {
                        TextField("纬度 lat", text: $latText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospaced())
                        TextField("经度 lng", text: $lngText)
                            .keyboardType(.decimalPad)
                            .font(.body.monospaced())
                    }
                    Toggle("该坐标为 WGS-84（否则按 GCJ-02 存储）", isOn: $wgs84)

                    Button {
                        showMapPicker = true
                    } label: {
                        Label("在地图上微调坐标", systemImage: "map.fill")
                    }
                    .buttonStyle(.glass)
                }

                if let errorMessage {
                    Section {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(existingPOI == nil ? "新增 POI 点位" : "编辑 POI 点位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                }
            }
            .sheet(isPresented: $showMapPicker) {
                let lat = Double(latText) ?? 0
                let lng = Double(lngText) ?? 0
                let initPt: GeoPoint? = (try? GeoMath.validateCoord(lat: lat, lng: lng)) != nil
                    ? (wgs84 ? GeoMath.wgs84ToGCJ02(GeoPoint(lat: lat, lng: lng)) : GeoPoint(lat: lat, lng: lng))
                    : nil
                MapPickerSheet(
                    initialPoint: initPt,
                    initialAddr: addr,
                    initialTitle: title,
                    savedPOIs: appState.pois,
                    confirmButtonTitle: "应用该坐标"
                ) { selection in
                    let pt = wgs84 ? GeoMath.gcj02ToWGS84(selection.point) : selection.point
                    latText = String(format: "%.6f", pt.lat)
                    lngText = String(format: "%.6f", pt.lng)
                    addr = selection.addr
                    title = selection.title
                }
            }
        }
    }

    private func save() {
        errorMessage = nil
        guard let lat = Double(latText.trimmingCharacters(in: .whitespacesAndNewlines)),
              let lng = Double(lngText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            errorMessage = "请输入有效的数字经纬度"
            return
        }
        do {
            try GeoMath.validateCoord(lat: lat, lng: lng)
        } catch {
            errorMessage = error.localizedDescription
            return
        }

        let cleanAddr = addr.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let coordText = GeoPoint(lat: lat, lng: lng).formatted

        let item = POIItem(
            id: existingPOI?.id ?? UUID().uuidString,
            lat: lat,
            lng: lng,
            addr: cleanAddr.isEmpty ? coordText : cleanAddr,
            title: cleanTitle.isEmpty ? (cleanAddr.isEmpty ? coordText : cleanAddr) : cleanTitle,
            wgs84: wgs84
        )
        onSave(item)
        dismiss()
    }
}
