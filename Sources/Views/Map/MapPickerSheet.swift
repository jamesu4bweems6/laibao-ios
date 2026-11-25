import CoreLocation
import MapKit
import Observation
import SwiftUI

/// Output returned when the user confirms a pin inside `MapPickerSheet`.
struct MapPickerSelection: Sendable, Hashable {
    let point: GeoPoint
    let addr: String
    let title: String
}

/// Swift 6 concurrency-safe one-shot CoreLocation delegate wrapper.
@Observable
@MainActor
final class OneShotLocationLocator: NSObject, CLLocationManagerDelegate {
    var isLocating: Bool = false
    var errorMessage: String?

    @ObservationIgnored private var manager: CLLocationManager?
    @ObservationIgnored private var completion: (@MainActor (GeoPoint) -> Void)?

    nonisolated override init() {
        super.init()
    }

    private func ensureManager() -> CLLocationManager {
        if let existing = manager {
            return existing
        }
        let created = CLLocationManager()
        created.delegate = self
        created.desiredAccuracy = kCLLocationAccuracyBest
        manager = created
        return created
    }

    func requestCurrentLocation(onLocated: @escaping @MainActor (GeoPoint) -> Void) {
        errorMessage = nil
        completion = onLocated
        isLocating = true

        let locationManager = ensureManager()
        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            locationManager.requestLocation()
        case .denied, .restricted:
            isLocating = false
            completion = nil
            errorMessage = "定位权限未开启，请在系统设置中允许使用定位"
        @unknown default:
            isLocating = false
            completion = nil
            errorMessage = "未知定位权限状态"
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard self.isLocating else { return }
            if status == .authorizedWhenInUse || status == .authorizedAlways {
                self.ensureManager().requestLocation()
            } else if status == .denied || status == .restricted {
                self.isLocating = false
                self.completion = nil
                self.errorMessage = "定位权限被拒绝"
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let coord = locations.last?.coordinate else { return }
        let wgs = GeoPoint(lat: coord.latitude, lng: coord.longitude)
        let gcj = GeoMath.wgs84ToGCJ02(wgs)
        Task { @MainActor in
            self.isLocating = false
            let callback = self.completion
            self.completion = nil
            callback?(gcj)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        let desc = error.localizedDescription
        Task { @MainActor in
            self.isLocating = false
            self.completion = nil
            self.errorMessage = "定位失败：\(desc)"
        }
    }
}

/// Native MapKit + Liquid Glass interactive location picker supporting:
/// - Tap-to-place pin via `MapReader` with haptic feedback
/// - Green `SPECIFIED_LOCATION` geofence circles + anchor pins + live distance badge
/// - Orange jitter preview circle
/// - Blue clickable saved POI pins
/// - `MKLocalSearch` + local POI search dropdown & floating glass map layer menu
/// - Compact/expandable floating glass detail card maximizing map viewport on mobile screens
struct MapPickerSheet: View {
    private enum MapLayerStyle: String, CaseIterable, Hashable, Sendable {
        case standard
        case hybrid
        case satellite

        var title: String {
            switch self {
            case .standard: return "标准地图"
            case .hybrid: return "混合卫星"
            case .satellite: return "纯卫星图"
            }
        }

        var systemImage: String {
            switch self {
            case .standard: return "map"
            case .hybrid: return "square.3.layers.3d"
            case .satellite: return "globe.asia.australia.fill"
            }
        }

        var mapStyle: MapStyle {
            switch self {
            case .standard: return .standard(elevation: .realistic)
            case .hybrid: return .hybrid(elevation: .realistic)
            case .satellite: return .imagery(elevation: .realistic)
            }
        }
    }

    private enum FocusField: Hashable {
        case search
        case title
        case addr
    }

    private struct SearchCandidate: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let gcjPoint: GeoPoint
        let isLocalPOI: Bool
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.appearsActive) private var appearsActive

    let anchors: [LocationAnchor]
    let selectedAnchorIndex: Int?
    let jitterRadiusMeters: Double
    let savedPOIs: [POIItem]
    let confirmButtonTitle: String
    let onConfirm: (MapPickerSelection) -> Void

    @State private var selectedPoint: GeoPoint
    @State private var titleText: String
    @State private var addrText: String
    @State private var layerStyle: MapLayerStyle = .standard
    @State private var cameraPosition: MapCameraPosition
    @State private var currentRegion: MKCoordinateRegion

    @State private var searchQuery: String = ""
    @State private var searchResults: [SearchCandidate] = []
    @State private var isSearching: Bool = false
    @State private var isReverseGeocoding: Bool = false
    @State private var isEditingDetails: Bool = false
    @State private var statusBanner: String?
    @State private var locator = OneShotLocationLocator()

    @State private var searchTask: Task<Void, Never>?
    @State private var reverseGeocodeTask: Task<Void, Never>?
    @FocusState private var focusedField: FocusField?

    init(
        initialPoint: GeoPoint? = nil,
        initialAddr: String = "",
        initialTitle: String = "",
        anchors: [LocationAnchor] = [],
        selectedAnchorIndex: Int? = nil,
        jitterRadiusMeters: Double = 0,
        savedPOIs: [POIItem] = [],
        confirmButtonTitle: String = "确认使用该位置",
        onConfirm: @escaping (MapPickerSelection) -> Void
    ) {
        self.anchors = anchors
        self.selectedAnchorIndex = selectedAnchorIndex
        self.jitterRadiusMeters = max(0, jitterRadiusMeters)
        self.savedPOIs = savedPOIs
        self.confirmButtonTitle = confirmButtonTitle
        self.onConfirm = onConfirm

        let fallbackPoint: GeoPoint = {
            if let initialPoint,
               (try? GeoMath.validateCoord(lat: initialPoint.lat, lng: initialPoint.lng)) != nil {
                return initialPoint
            }
            if let idx = selectedAnchorIndex, anchors.indices.contains(idx) {
                return anchors[idx].point
            }
            if let firstAnchor = anchors.first {
                return firstAnchor.point
            }
            if let firstPOI = savedPOIs.first {
                return firstPOI.gcj02Point
            }
            return GeoPoint(lat: 39.908823, lng: 116.397470)
        }()

        let region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: fallbackPoint.lat, longitude: fallbackPoint.lng),
            span: MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        )
        _selectedPoint = State(initialValue: fallbackPoint)
        _titleText = State(initialValue: initialTitle)
        _addrText = State(initialValue: initialAddr)
        _currentRegion = State(initialValue: region)
        _cameraPosition = State(initialValue: .region(region))
    }

    private var shouldShowRightControls: Bool {
        focusedField == nil && searchResults.isEmpty
    }

    var body: some View {
        NavigationStack {
            ZStack {
                mapCanvas
                    .ignoresSafeArea(edges: .bottom)

                VStack(spacing: 8) {
                    topFloatingChrome

                    Spacer(minLength: 8)

                    if shouldShowRightControls {
                        HStack {
                            Spacer()
                            rightControlCluster
                        }
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                    }

                    if focusedField != .search {
                        bottomDetailCard
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .animation(.snappy(duration: 0.24), value: shouldShowRightControls)
                .animation(.snappy(duration: 0.24), value: isEditingDetails)
            }
            .navigationTitle("地图选点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if focusedField != nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") {
                            focusedField = nil
                        }
                    }
                }
            }
            .sensoryFeedback(.selection, trigger: selectedPoint)
            .onChange(of: locator.errorMessage) { _, err in
                if let err {
                    statusBanner = err
                }
            }
            .onDisappear {
                searchTask?.cancel()
                reverseGeocodeTask?.cancel()
            }
        }
    }

    // MARK: - Map Layer

    private var mapCanvas: some View {
        MapReader { proxy in
            Map(position: $cameraPosition) {
                ForEach(anchors.indices, id: \.self) { idx in
                    let anchor = anchors[idx]
                    let coord = CLLocationCoordinate2D(latitude: anchor.latitude, longitude: anchor.longitude)
                    MapCircle(center: coord, radius: anchor.scope)
                        .foregroundStyle(Color.green.opacity(0.16))
                        .stroke(Color.green, lineWidth: 2)

                    Annotation(anchor.displayName, coordinate: coord, anchor: .bottom) {
                        Button {
                            focusedField = nil
                            selectAnchor(anchor)
                        } label: {
                            Image(systemName: "flag.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .green)
                                .shadow(color: Color.black.opacity(0.28), radius: 4, y: 2)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if jitterRadiusMeters > 0 {
                    MapCircle(
                        center: CLLocationCoordinate2D(latitude: selectedPoint.lat, longitude: selectedPoint.lng),
                        radius: jitterRadiusMeters
                    )
                    .foregroundStyle(Color.orange.opacity(0.14))
                    .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                }

                ForEach(savedPOIs) { poi in
                    let gcj = poi.gcj02Point
                    Annotation(
                        poi.title,
                        coordinate: CLLocationCoordinate2D(latitude: gcj.lat, longitude: gcj.lng),
                        anchor: .bottom
                    ) {
                        Button {
                            focusedField = nil
                            selectPOI(poi)
                        } label: {
                            Image(systemName: "mappin.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.white, .blue)
                                .shadow(color: Color.black.opacity(0.24), radius: 3, y: 1)
                        }
                        .buttonStyle(.plain)
                    }
                }

                Annotation(
                    titleText.isEmpty ? "已选点位" : titleText,
                    coordinate: CLLocationCoordinate2D(latitude: selectedPoint.lat, longitude: selectedPoint.lng),
                    anchor: .bottom
                ) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 34, height: 34)
                            .shadow(color: Color.black.opacity(0.28), radius: 5, y: 2)
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 30))
                            .foregroundStyle(Color.red)
                    }
                }
            }
            .mapStyle(layerStyle.mapStyle)
            .onMapCameraChange(frequency: .continuous) { context in
                currentRegion = context.region
            }
            .onTapGesture { screenPoint in
                focusedField = nil
                if let coord = proxy.convert(screenPoint, from: .local) {
                    let pt = GeoPoint(lat: round6(coord.latitude), lng: round6(coord.longitude))
                    selectedPoint = pt
                    searchResults = []
                    statusBanner = nil
                }
            }
        }
    }

    // MARK: - Top Floating Liquid Glass Chrome

    private var topFloatingChrome: some View {
        VStack(spacing: 8) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    TextField("搜索地点或已保存 POI...", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .focused($focusedField, equals: .search)
                        .submitLabel(.search)
                        .onSubmit {
                            performSearch()
                        }

                    if isSearching {
                        ProgressView()
                            .controlSize(.small)
                    } else if !searchQuery.isEmpty {
                        Button {
                            searchQuery = ""
                            searchResults = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("清空搜索")

                        Button("搜索") {
                            performSearch()
                        }
                        .buttonStyle(.glass)
                        .controlSize(.small)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .glassEffect(.regular, in: .capsule)
            }
            .opacity(appearsActive ? 1.0 : 0.78)

            if let match = activeAnchorMatch {
                let distInt = Int(match.distanceMeters.rounded())
                let scopeInt = Int(match.anchor.scope.rounded())
                GlassStatusPill(
                    title: match.isWithinScope
                        ? "围栏内 · 距中心 \(distInt)m / \(scopeInt)m"
                        : "超出围栏 · 距中心 \(distInt)m / \(scopeInt)m",
                    systemImage: match.isWithinScope ? "checkmark.shield.fill" : "exclamationmark.triangle.fill",
                    tint: match.isWithinScope ? Color.green : Color.orange,
                    lineLimit: 2
                )
            }

            if let statusBanner, !statusBanner.isEmpty {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) {
                        self.statusBanner = nil
                    }
                } label: {
                    GlassStatusPill(
                        title: statusBanner,
                        systemImage: "info.circle.fill",
                        tint: .orange,
                        isInteractive: true,
                        lineLimit: 2
                    )
                }
                .buttonStyle(.plain)
            }

            if !searchResults.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(searchResults) { candidate in
                            Button {
                                applySearchCandidate(candidate)
                            } label: {
                                HStack(spacing: 10) {
                                    Image(systemName: candidate.isLocalPOI ? "mappin.circle.fill" : "magnifyingglass.circle.fill")
                                        .font(.title3)
                                        .foregroundStyle(candidate.isLocalPOI ? Color.blue : Color.secondary)
                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: 6) {
                                            Text(candidate.title)
                                                .font(.subheadline.weight(.medium))
                                                .foregroundStyle(.primary)
                                                .lineLimit(1)
                                            if candidate.isLocalPOI {
                                                StatusBadge(title: "点位池", tint: .blue)
                                            }
                                        }
                                        if !candidate.subtitle.isEmpty {
                                            Text(candidate.subtitle)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(1)
                                        }
                                    }
                                    Spacer(minLength: 4)
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Divider().padding(.leading, 44)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .glassEffect(.regular, in: .rect(cornerRadius: 20))
            }
        }
    }

    // MARK: - Right Map Controls

    private var rightControlCluster: some View {
        GlassMapControlCluster(axis: .vertical, spacing: 10) {
            Menu {
                ForEach(MapLayerStyle.allCases, id: \.self) { style in
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            layerStyle = style
                        }
                    } label: {
                        if layerStyle == style {
                            Label(style.title, systemImage: "checkmark")
                        } else {
                            Label(style.title, systemImage: style.systemImage)
                        }
                    }
                }
            } label: {
                Image(systemName: layerStyle.systemImage)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(layerStyle == .standard ? Color.primary : Color.accentColor)
                    .frame(width: 44, height: 44)
                    .contentShape(Circle())
            }
            .glassEffect(layerButtonGlass, in: .circle)
            .accessibilityLabel("切换地图图层，当前：\(layerStyle.title)")

            GlassMapIconButton(
                systemImage: locator.isLocating ? "location.circle" : "location.fill",
                accessibilityLabel: "定位到当前位置",
                isActive: locator.isLocating
            ) {
                locator.requestCurrentLocation { gcjPoint in
                    selectedPoint = GeoPoint(lat: round6(gcjPoint.lat), lng: round6(gcjPoint.lng))
                    centerMap(on: selectedPoint, spanDelta: 0.004)
                    reverseGeocodeCurrentPoint()
                }
            }

            if !anchors.isEmpty {
                GlassMapIconButton(
                    systemImage: "scope",
                    accessibilityLabel: "定位到围栏锚点",
                    tint: .green
                ) {
                    let target: LocationAnchor
                    if let idx = selectedAnchorIndex, anchors.indices.contains(idx) {
                        target = anchors[idx]
                    } else {
                        target = anchors[0]
                    }
                    selectAnchor(target)
                }
            }

            GlassMapIconButton(systemImage: "plus", accessibilityLabel: "放大地图") {
                adjustZoom(factor: 0.5)
            }

            GlassMapIconButton(systemImage: "minus", accessibilityLabel: "缩小地图") {
                adjustZoom(factor: 2.0)
            }
        }
    }

    // MARK: - Bottom Liquid Glass Detail Card

    private var bottomDetailCard: some View {
        let wgs = GeoMath.gcj02ToWGS84(selectedPoint)
        let displayTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayAddr = addrText.trimmingCharacters(in: .whitespacesAndNewlines)

        return GlassEffectContainer(spacing: 10) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayTitle.isEmpty ? "轻点地图落针或反查地址" : displayTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        if !displayAddr.isEmpty && displayAddr != displayTitle {
                            Text(displayAddr)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }

                        HStack(spacing: 6) {
                            Text("GCJ-02 \(selectedPoint.formatted)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if jitterRadiusMeters > 0 {
                                StatusBadge(
                                    title: "±\(Int(jitterRadiusMeters))m",
                                    tint: .orange,
                                    monospaced: true
                                )
                            }
                        }
                    }

                    Spacer(minLength: 4)

                    Button {
                        withAnimation(.snappy(duration: 0.24)) {
                            isEditingDetails.toggle()
                            if !isEditingDetails {
                                focusedField = nil
                            }
                        }
                    } label: {
                        Label(isEditingDetails ? "收起" : "编辑", systemImage: isEditingDetails ? "chevron.down" : "pencil")
                            .font(.caption.weight(.semibold))
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                }

                if isEditingDetails {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("WGS-84（GPS）：\(wgs.formatted)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)

                        TextField("地点名称（title）", text: $titleText)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .title)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )

                        TextField("详细地址（address）", text: $addrText)
                            .textFieldStyle(.plain)
                            .focused($focusedField, equals: .addr)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                Color.primary.opacity(0.06),
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                            )
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }

                HStack(spacing: 10) {
                    Button {
                        focusedField = nil
                        reverseGeocodeCurrentPoint()
                    } label: {
                        HStack(spacing: 5) {
                            if isReverseGeocoding {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Image(systemName: "text.magnifyingglass")
                            }
                            Text("反查地址")
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(.glass)
                    .disabled(isReverseGeocoding)

                    Button {
                        focusedField = nil
                        let fallbackAddr = addrText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let fallbackTitle = titleText.trimmingCharacters(in: .whitespacesAndNewlines)
                        let finalAddr = fallbackAddr.isEmpty ? selectedPoint.formatted : fallbackAddr
                        let finalTitle = fallbackTitle.isEmpty ? finalAddr : fallbackTitle
                        onConfirm(MapPickerSelection(point: selectedPoint, addr: finalAddr, title: finalTitle))
                        dismiss()
                    } label: {
                        Text(confirmButtonTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
            }
            .padding(14)
            .glassEffect(.regular, in: .rect(cornerRadius: 24))
        }
        .opacity(appearsActive ? 1.0 : 0.78)
    }

    // MARK: - Computed Helpers & Actions

    private var layerButtonGlass: Glass {
        if layerStyle == .standard {
            return .regular.interactive()
        }
        return .regular.tint(Color.accentColor.opacity(0.24)).interactive()
    }

    private var activeAnchorMatch: AnchorMatch? {
        guard !anchors.isEmpty else { return nil }
        if let idx = selectedAnchorIndex, anchors.indices.contains(idx) {
            return GeoMath.pickNearestAnchor(userPoint: selectedPoint, anchors: [anchors[idx]])
        }
        return GeoMath.pickNearestAnchor(userPoint: selectedPoint, anchors: anchors)
    }

    private func centerMap(on point: GeoPoint, spanDelta: Double? = nil) {
        let span = spanDelta.map { MKCoordinateSpan(latitudeDelta: $0, longitudeDelta: $0) }
            ?? currentRegion.span
        let next = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: point.lat, longitude: point.lng),
            span: span
        )
        currentRegion = next
        withAnimation(.snappy(duration: 0.25)) {
            cameraPosition = .region(next)
        }
    }

    private func adjustZoom(factor: Double) {
        let nextLatDelta = min(60.0, max(0.0005, currentRegion.span.latitudeDelta * factor))
        let nextLngDelta = min(60.0, max(0.0005, currentRegion.span.longitudeDelta * factor))
        let next = MKCoordinateRegion(
            center: currentRegion.center,
            span: MKCoordinateSpan(latitudeDelta: nextLatDelta, longitudeDelta: nextLngDelta)
        )
        currentRegion = next
        withAnimation(.easeInOut(duration: 0.2)) {
            cameraPosition = .region(next)
        }
    }

    private func selectAnchor(_ anchor: LocationAnchor) {
        selectedPoint = anchor.point
        if !anchor.specifiedAddress.isEmpty {
            titleText = anchor.specifiedAddress
        }
        if !anchor.address.isEmpty {
            addrText = anchor.address
        } else if !anchor.specifiedAddress.isEmpty {
            addrText = anchor.specifiedAddress
        }
        centerMap(on: anchor.point, spanDelta: max(0.004, (anchor.scope / 111_000.0) * 3.5))
    }

    private func selectPOI(_ poi: POIItem) {
        selectedPoint = poi.gcj02Point
        titleText = poi.title
        addrText = poi.addr
        centerMap(on: selectedPoint, spanDelta: 0.004)
    }

    private func performSearch() {
        focusedField = nil
        searchTask?.cancel()

        let trimmed = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            return
        }

        let lower = trimmed.lowercased()
        let localMatches: [SearchCandidate] = savedPOIs.compactMap { poi in
            if poi.title.lowercased().contains(lower) || poi.addr.lowercased().contains(lower) {
                return SearchCandidate(
                    id: "poi:\(poi.id)",
                    title: poi.title,
                    subtitle: poi.addr,
                    gcjPoint: poi.gcj02Point,
                    isLocalPOI: true
                )
            }
            return nil
        }
        searchResults = localMatches
        isSearching = true
        statusBanner = nil

        let regionSnapshot = currentRegion
        searchTask = Task {
            defer { isSearching = false }
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = trimmed
            request.region = regionSnapshot
            do {
                let response = try await MKLocalSearch(request: request).start()
                guard !Task.isCancelled else { return }
                let remote: [SearchCandidate] = response.mapItems.prefix(12).enumerated().map { idx, item in
                    let coord = item.placemark.coordinate
                    let gcj = GeoMath.wgs84ToGCJ02(GeoPoint(lat: coord.latitude, lng: coord.longitude))
                    let rounded = GeoPoint(lat: round6(gcj.lat), lng: round6(gcj.lng))
                    return SearchCandidate(
                        id: "mk:\(idx):\(rounded.formatted)",
                        title: item.name ?? item.placemark.title ?? trimmed,
                        subtitle: item.placemark.title ?? rounded.formatted,
                        gcjPoint: rounded,
                        isLocalPOI: false
                    )
                }
                searchResults = localMatches + remote
                if searchResults.isEmpty {
                    statusBanner = "未找到匹配的地点"
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                if localMatches.isEmpty {
                    statusBanner = "地图搜索失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func applySearchCandidate(_ candidate: SearchCandidate) {
        focusedField = nil
        selectedPoint = candidate.gcjPoint
        titleText = candidate.title
        addrText = candidate.subtitle
        searchResults = []
        centerMap(on: candidate.gcjPoint, spanDelta: 0.004)
    }

    private func reverseGeocodeCurrentPoint() {
        reverseGeocodeTask?.cancel()
        isReverseGeocoding = true
        statusBanner = nil
        let wgs = GeoMath.gcj02ToWGS84(selectedPoint)
        let location = CLLocation(latitude: wgs.lat, longitude: wgs.lng)

        reverseGeocodeTask = Task {
            defer { isReverseGeocoding = false }
            do {
                let placemarks = try await CLGeocoder().reverseGeocodeLocation(location)
                guard !Task.isCancelled else { return }
                guard let placemark = placemarks.first else {
                    statusBanner = "未反查到地址信息"
                    return
                }
                let parts = [
                    placemark.administrativeArea,
                    placemark.locality,
                    placemark.subLocality,
                    placemark.thoroughfare,
                    placemark.subThoroughfare
                ]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }

                var deduped: [String] = []
                for part in parts where deduped.last != part {
                    deduped.append(part)
                }
                let builtAddr = deduped.joined()
                let name = placemark.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

                if !builtAddr.isEmpty {
                    addrText = builtAddr
                } else if !name.isEmpty {
                    addrText = name
                }
                if !name.isEmpty {
                    titleText = name
                } else if !builtAddr.isEmpty {
                    titleText = builtAddr
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                statusBanner = "反查地址失败：\(error.localizedDescription)"
            }
        }
    }

    private func round6(_ value: Double) -> Double {
        (value * 1_000_000.0).rounded() / 1_000_000.0
    }
}
