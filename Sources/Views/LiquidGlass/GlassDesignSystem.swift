import SwiftUI

// MARK: - GlassStatusPill

/// Compact refractive status badge using native iOS 26/27 Liquid Glass.
struct GlassStatusPill: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = .accentColor
    var isInteractive: Bool = false

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.semibold))
                    .imageScale(.small)
            }
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .glassEffect(
            .regular.tint(tint.opacity(0.26)).interactive(isInteractive),
            in: .capsule
        )
        .opacity(appearsActive ? 1.0 : 0.78)
        .animation(.easeInOut(duration: 0.2), value: appearsActive)
    }
}

// MARK: - GlassFloatingActionBar

/// Floating bottom Liquid Glass dock grouped inside `GlassEffectContainer`
/// so adjacent buttons fluidly blend and dim gently when the scene is inactive.
struct GlassFloatingActionBar<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: () -> Content

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GlassEffectContainer(spacing: spacing) {
            HStack(spacing: spacing) {
                content()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
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
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(items, id: \.self) { item in
                    let isSelected = selection == item
                    Button {
                        withAnimation(.snappy(duration: 0.28, extraBounce: 0.08)) {
                            selection = item
                        }
                    } label: {
                        HStack(spacing: 5) {
                            if let icon = systemImage?(item) {
                                Image(systemName: icon)
                                    .font(.subheadline.weight(.semibold))
                            }
                            Text(title(item))
                                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                                .lineLimit(1)
                                .minimumScaleFactor(0.85)
                        }
                        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                Capsule()
                                    .fill(.clear)
                                    .glassEffect(
                                        .regular.tint(tint.opacity(0.28)).interactive(),
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
            .padding(4)
            .background(Color(.tertiarySystemFill).opacity(0.65), in: Capsule())
        }
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
                .foregroundStyle(isActive ? Color.accentColor : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(resolvedGlass, in: .circle)
        .accessibilityLabel(accessibilityLabel)
    }

    private var resolvedGlass: Glass {
        if let tint {
            return .regular.tint(tint.opacity(0.28)).interactive()
        }
        if isActive {
            return .regular.tint(Color.accentColor.opacity(0.26)).interactive()
        }
        return .regular.interactive()
    }
}

// MARK: - GlassToastBanner

/// Non-intrusive floating Liquid Glass toast notification.
struct GlassToastBanner: View {
    let message: String
    var isError: Bool = false
    var onDismiss: (() -> Void)? = nil

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isError ? Color.orange : Color.accentColor)

                Text(message)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)

                if let onDismiss {
                    Button {
                        onDismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(6)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭提示")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .glassEffect(
                .regular.tint((isError ? Color.orange : Color.accentColor).opacity(0.18)),
                in: .capsule
            )
        }
        .opacity(appearsActive ? 1.0 : 0.78)
        .padding(.horizontal, 16)
    }
}

// MARK: - LiquidGlassBackground

/// Atmospheric mesh backdrop used exclusively behind the Auth Gate screen
/// so floating Liquid Glass cards refract genuine depth and specular light.
struct LiquidGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    private let meshPoints: [SIMD2<Float>] = [
        SIMD2(0.0, 0.0), SIMD2(0.5, 0.0), SIMD2(1.0, 0.0),
        SIMD2(0.0, 0.5), SIMD2(0.55, 0.45), SIMD2(1.0, 0.5),
        SIMD2(0.0, 1.0), SIMD2(0.5, 1.0), SIMD2(1.0, 1.0)
    ]

    private var meshColors: [Color] {
        if colorScheme == .dark {
            return [
                Color(red: 0.04, green: 0.09, blue: 0.20),
                Color(red: 0.07, green: 0.16, blue: 0.34),
                Color(red: 0.05, green: 0.11, blue: 0.24),
                Color(red: 0.06, green: 0.19, blue: 0.36),
                Color(red: 0.09, green: 0.28, blue: 0.46),
                Color(red: 0.08, green: 0.14, blue: 0.30),
                Color(red: 0.03, green: 0.07, blue: 0.15),
                Color(red: 0.05, green: 0.13, blue: 0.25),
                Color(red: 0.04, green: 0.08, blue: 0.18)
            ]
        } else {
            return [
                Color(red: 0.85, green: 0.93, blue: 1.00),
                Color(red: 0.76, green: 0.88, blue: 0.99),
                Color(red: 0.87, green: 0.94, blue: 0.99),
                Color(red: 0.80, green: 0.92, blue: 0.98),
                Color(red: 0.69, green: 0.85, blue: 0.99),
                Color(red: 0.84, green: 0.90, blue: 0.99),
                Color(red: 0.91, green: 0.96, blue: 1.00),
                Color(red: 0.83, green: 0.92, blue: 0.99),
                Color(red: 0.89, green: 0.94, blue: 1.00)
            ]
        }
    }

    var body: some View {
        ZStack {
            MeshGradient(
                width: 3,
                height: 3,
                points: meshPoints,
                colors: meshColors
            )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.accentColor.opacity(colorScheme == .dark ? 0.32 : 0.22),
                            .clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 240
                    )
                )
                .frame(width: 440, height: 440)
                .offset(x: -110, y: -190)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            Color.cyan.opacity(colorScheme == .dark ? 0.24 : 0.18),
                            .clear
                        ],
                        center: .center,
                        startRadius: 10,
                        endRadius: 220
                    )
                )
                .frame(width: 380, height: 380)
                .offset(x: 130, y: 220)
        }
        .ignoresSafeArea()
    }
}
