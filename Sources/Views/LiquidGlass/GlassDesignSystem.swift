import SwiftUI
import UIKit

// MARK: - Cached MainActor Date Formatters

/// Shared `DateFormatter` cache isolated to `@MainActor` (Swift 6 strict-concurrency safe)
/// to avoid per-render formatter allocations across SwiftUI views.
@MainActor
enum UIFormatters {
    static let ymd: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static let ymdHM: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    static let ymdHMS: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static let ymdHMSMillis: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()

    static let hm: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm"
        return f
    }()

    static func parseFlexibleDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for formatter in [ymdHM, ymdHMS, ymd] {
            if let date = formatter.date(from: trimmed) {
                return date
            }
        }
        return nil
    }
}

// MARK: - Field Type Display Metadata

/// Maps raw LaiBao / QunBaoShu catalog types to concise localized labels and SF Symbols.
struct FieldTypePresentation: Sendable {
    let label: String
    let systemImage: String
    let tint: Color

    static func forType(_ rawType: String) -> FieldTypePresentation {
        switch rawType.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "LOCATION":
            return FieldTypePresentation(label: "位置", systemImage: "location.fill", tint: .blue)
        case "WORD":
            return FieldTypePresentation(label: "文本", systemImage: "text.alignleft", tint: .indigo)
        case "RADIO", "RADIO_V2":
            return FieldTypePresentation(label: "单选", systemImage: "largecircle.fill.circle", tint: .teal)
        case "CHECKBOX", "CHECKBOX_V2", "CHOICE":
            return FieldTypePresentation(label: "多选", systemImage: "checklist", tint: .cyan)
        case "DATE":
            return FieldTypePresentation(label: "日期", systemImage: "calendar.badge.clock", tint: .orange)
        case "AREA":
            return FieldTypePresentation(label: "地区", systemImage: "map", tint: .mint)
        case "MULTI_LEVEL_SELECT":
            return FieldTypePresentation(label: "多级", systemImage: "list.bullet.indent", tint: .purple)
        case "IMAGE":
            return FieldTypePresentation(label: "图片", systemImage: "photo.on.rectangle", tint: .pink)
        case "NUMBER", "NUMBER_FLOAT", "DIGIT":
            return FieldTypePresentation(label: "数值", systemImage: "number", tint: .blue)
        case "TELEPHONE":
            return FieldTypePresentation(label: "电话", systemImage: "phone.fill", tint: .green)
        case "ID_CARD":
            return FieldTypePresentation(label: "证件", systemImage: "person.text.rectangle", tint: .brown)
        case "EMAIL":
            return FieldTypePresentation(label: "邮箱", systemImage: "envelope.fill", tint: .blue)
        case "URL":
            return FieldTypePresentation(label: "网址", systemImage: "link", tint: .indigo)
        case "BANK_CARD":
            return FieldTypePresentation(label: "卡号", systemImage: "creditcard.fill", tint: .orange)
        default:
            let cleaned = rawType.trimmingCharacters(in: .whitespacesAndNewlines)
            return FieldTypePresentation(
                label: cleaned.isEmpty ? "字段" : cleaned,
                systemImage: "square.and.pencil",
                tint: .secondary
            )
        }
    }
}

// MARK: - StatusBadge (Content-Layer Semantic Pill)

/// Lightweight, high-contrast semantic badge designed for scrolling `List` and `Form` rows.
/// Following iOS 26's Four-Layer Rule, content rows use tinted translucent badges instead of
/// stacking heavy refractive `.glassEffect` layers on every scrolling cell.
struct StatusBadge: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var monospaced: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
            }
            Text(title)
                .font(monospaced ? .caption2.monospaced().weight(.semibold) : .caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(tint.opacity(0.13), in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(tint.opacity(0.24), lineWidth: 0.5)
        )
        .contentTransition(.numericText())
    }
}

// MARK: - GlassStatusPill (Floating Overlay Liquid Glass Badge)

/// Floating refractive status badge using native iOS 26/27 Liquid Glass.
/// Best suited for floating map overlays, QR live status banners, and floating chrome.
struct GlassStatusPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var isInteractive: Bool = false
    var lineLimit: Int = 1

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let content = HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(tint)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .minimumScaleFactor(lineLimit == 1 ? 0.84 : 0.92)
                .multilineTextAlignment(.leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)

        Group {
            if lineLimit == 1 {
                content
                    .glassEffect(
                        .regular.tint(tint.opacity(0.22)).interactive(isInteractive),
                        in: .capsule
                    )
            } else {
                content
                    .glassEffect(
                        .regular.tint(tint.opacity(0.22)).interactive(isInteractive),
                        in: .rect(cornerRadius: 16)
                    )
            }
        }
        .contentTransition(.numericText())
        .opacity(appearsActive ? 1.0 : 0.78)
        .animation(.easeInOut(duration: 0.2), value: appearsActive)
    }
}

// MARK: - IconBadge

/// Uniform continuous-rounded icon tile for list rows, login actions, and cards.
struct IconBadge: View {
    let systemImage: String
    var tint: Color = .accentColor
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
            )
    }
}

// MARK: - InlineFeedbackBanner

/// Compact, wrapping in-form banner for errors, warnings, or success summaries.
struct InlineFeedbackBanner: View {
    let message: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tint)
                .padding(.top, 1)

            Text(message)
                .font(.footnote)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(tint.opacity(0.22), lineWidth: 0.5)
        )
    }
}

// MARK: - FlowLayout

/// Pure SwiftUI wrapping horizontal flow layout so multi-badge rows and time chips wrap
/// gracefully on 375pt phones and larger Dynamic Type sizes instead of clipping.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth.isFinite ? maxWidth : nil, height: nil)
            )
            if currentX > 0 && currentX + size.width > maxWidth {
                currentX = 0
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            maxUsedWidth = max(maxUsedWidth, currentX + size.width)
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        let totalHeight = subviews.isEmpty ? 0 : currentY + lineHeight
        let resolvedWidth = maxWidth.isFinite ? min(maxWidth, ceil(maxUsedWidth)) : ceil(maxUsedWidth)
        return CGSize(width: resolvedWidth, height: totalHeight)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let maxWidth = bounds.width
        var currentX = bounds.minX
        var currentY = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(
                ProposedViewSize(width: maxWidth > 0 ? maxWidth : nil, height: nil)
            )
            if currentX > bounds.minX && (currentX - bounds.minX) + size.width > maxWidth + 0.5 {
                currentX = bounds.minX
                currentY += lineHeight + lineSpacing
                lineHeight = 0
            }
            subview.place(
                at: CGPoint(x: currentX, y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: min(size.width, maxWidth), height: size.height)
            )
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

// MARK: - Mobile Input Field & Keyboard Helpers

/// Uniform rounded input chrome for embedded text fields inside grouped forms.
private struct MobileInputFieldModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var verticalPadding: CGFloat = 10
    var horizontalPadding: CGFloat = 12

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Color(.tertiarySystemFill).opacity(0.75),
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
    }
}

/// Adds an ergonomic iOS keyboard toolbar with a trailing "完成" button so `.decimalPad`,
/// `.numberPad`, and `.phonePad` keyboards can always be dismissed cleanly.
private struct KeyboardDoneToolbarModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("完成") {
                        dismissKeyboard()
                    }
                    .font(.subheadline.weight(.semibold))
                }
            }
    }
}

@MainActor
func dismissKeyboard() {
    UIApplication.shared.sendAction(
        #selector(UIResponder.resignFirstResponder),
        to: nil,
        from: nil,
        for: nil
    )
}

extension View {
    func mobileInputField(
        cornerRadius: CGFloat = 10,
        verticalPadding: CGFloat = 10,
        horizontalPadding: CGFloat = 12
    ) -> some View {
        modifier(
            MobileInputFieldModifier(
                cornerRadius: cornerRadius,
                verticalPadding: verticalPadding,
                horizontalPadding: horizontalPadding
            )
        )
    }

    func keyboardDoneToolbar() -> some View {
        modifier(KeyboardDoneToolbarModifier())
    }
}

// MARK: - GlassFloatingActionBar

/// Floating bottom Liquid Glass dock grouped inside `GlassEffectContainer`
/// so adjacent buttons fluidly blend and dim gently when the scene is inactive.
struct GlassFloatingActionBar<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 10)
        }
        .opacity(appearsActive ? 1.0 : 0.72)
        .animation(.easeInOut(duration: 0.2), value: appearsActive)
    }
}

// MARK: - GlassSegmentedControl

/// Smooth morphing segmented selector backed by `GlassEffectContainer` + `.glassEffectID`.
struct GlassSegmentedControl<Selection: Hashable & Sendable>: View {
    let items: [Selection]
    @Binding var selection: Selection
    let title: (Selection) -> String
    var systemImage: ((Selection) -> String?)? = nil
    var tint: Color = .accentColor

    @Namespace private var glassNamespace
    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 3) {
                ForEach(items, id: \.self) { item in
                    let isSelected = selection == item
                    Button {
                        withAnimation(.snappy(duration: 0.26, extraBounce: 0.06)) {
                            selection = item
                        }
                    } label: {
                        HStack(spacing: 4) {
                            if let icon = systemImage?(item) {
                                Image(systemName: icon)
                                    .font(.caption.weight(.semibold))
                            }
                            Text(title(item))
                                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(
                                        .regular.tint(tint.opacity(0.26)).interactive(),
                                        in: .capsule
                                    )
                                    .glassEffectID("selectedSegment", in: glassNamespace)
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .padding(3)
            .background(Color(.tertiarySystemFill).opacity(0.68), in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.06), lineWidth: 0.5)
            )
        }
        .sensoryFeedback(.selection, trigger: selection)
        .opacity(appearsActive ? 1.0 : 0.78)
        .animation(.easeInOut(duration: 0.2), value: appearsActive)
    }
}

// MARK: - GlassMapControlCluster

/// Vertical or horizontal cluster of floating Liquid Glass map controls.
struct GlassMapControlCluster<Content: View>: View {
    var axis: Axis = .vertical
    var spacing: CGFloat = 10
    @ViewBuilder let content: () -> Content

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            Group {
                if axis == .vertical {
                    VStack(spacing: spacing) {
                        content()
                    }
                } else {
                    HStack(spacing: spacing) {
                        content()
                    }
                }
            }
        }
        .opacity(appearsActive ? 1.0 : 0.72)
        .animation(.easeInOut(duration: 0.2), value: appearsActive)
    }
}

/// Circular interactive Liquid Glass icon button for map and floating tool clusters.
struct GlassMapIconButton: View {
    let systemImage: String
    let accessibilityLabel: String
    var tint: Color? = nil
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(resolvedForeground)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(resolvedGlass, in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolvedForeground: Color {
        if let tint {
            return tint
        }
        return isActive ? Color.accentColor : Color.primary
    }

    private var resolvedGlass: Glass {
        if let tint {
            return .regular.tint(tint.opacity(0.24)).interactive()
        }
        if isActive {
            return .regular.tint(Color.accentColor.opacity(0.24)).interactive()
        }
        return .regular.interactive()
    }
}

// MARK: - GlassToastBanner

/// Non-intrusive floating Liquid Glass toast notification supporting multi-line text
/// and swipe-up-to-dismiss gestures.
struct GlassToastBanner: View {
    let message: String
    var isError: Bool = false
    var onDismiss: (() -> Void)? = nil

    @Environment(\.appearsActive) private var appearsActive
    @State private var dragOffsetY: CGFloat = 0

    var body: some View {
        let accent: Color = isError ? .orange : .green
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(accent)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
            }
            .padding(.leading, 14)
            .padding(.trailing, onDismiss == nil ? 14 : 8)
            .padding(.vertical, 10)
            .glassEffect(
                .regular.tint(accent.opacity(0.16)),
                in: .rect(cornerRadius: 20)
            )
            .shadow(color: Color.black.opacity(0.10), radius: 12, y: 4)
        }
        .offset(y: min(0, dragOffsetY))
        .gesture(
            DragGesture(minimumDistance: 8)
                .onChanged { value in
                    if value.translation.height < 0 {
                        dragOffsetY = value.translation.height
                    }
                }
                .onEnded { value in
                    if value.translation.height < -24 {
                        onDismiss?()
                    }
                    withAnimation(.snappy(duration: 0.2)) {
                        dragOffsetY = 0
                    }
                }
        )
        .opacity(appearsActive ? 1.0 : 0.78)
        .padding(.horizontal, 16)
    }
}
