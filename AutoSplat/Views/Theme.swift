import SwiftUI

enum Theme {
    // MARK: - Backgrounds
    static let bgPrimary = Color(red: 0.051, green: 0.067, blue: 0.090)      // #0D1117
    static let bgSecondary = Color(red: 0.086, green: 0.106, blue: 0.133)    // #161B22
    static let bgTertiary = Color(red: 0.110, green: 0.137, blue: 0.200)     // #1C2333
    static let borderSubtle = Color(red: 0.129, green: 0.149, blue: 0.176)   // #21262D

    // MARK: - Accents
    static let accentCyan = Color(red: 0.0, green: 0.898, blue: 1.0)         // #00E5FF
    static let accentTeal = Color(red: 0.0, green: 0.706, blue: 0.847)       // #00B4D8
    static let accentPurple = Color(red: 0.486, green: 0.227, blue: 0.929)   // #7C3AED
    static let success = Color(red: 0.024, green: 0.839, blue: 0.627)        // #06D6A0
    static let error = Color(red: 1.0, green: 0.420, blue: 0.420)            // #FF6B6B
    static let warning = Color(red: 0.984, green: 0.749, blue: 0.141)        // #FBBF24

    // MARK: - Text
    static let textPrimary = Color(red: 0.902, green: 0.929, blue: 0.953)    // #E6EDF3
    static let textSecondary = Color(red: 0.545, green: 0.580, blue: 0.620)  // #8B949E
    static let textTertiary = Color(red: 0.282, green: 0.310, blue: 0.345)   // #484F58

    // MARK: - Gradients
    static let cyanGradient = LinearGradient(
        colors: [accentCyan, accentTeal],
        startPoint: .leading, endPoint: .trailing
    )
    static let borderGlow = AngularGradient(
        colors: [accentCyan, accentPurple, accentCyan],
        center: .center
    )

    // MARK: - Dimensions
    static let panelWidth: CGFloat = 280
    static let panelCollapsedWidth: CGFloat = 44
    static let panelCornerRadius: CGFloat = 16
    static let panelInset: CGFloat = 12
    static let sliderTrackHeight: CGFloat = 4
    static let sliderThumbSize: CGFloat = 16

    // MARK: - Glass modifier
    static func glass(cornerRadius: CGFloat = panelCornerRadius) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(bgSecondary.opacity(0.65))
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(accentCyan.opacity(0.12), lineWidth: 1)
            )
    }

    // MARK: - Section Header Style
    static func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(textSecondary)
            .kerning(1.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
            .padding(.bottom, 4)
    }
}

// MARK: - Custom Components

struct CyanSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double> = 0...100
    var label: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(value))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.accentCyan)
            }
            GeometryReader { geo in
                let fraction = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
                let thumbX = fraction * geo.size.width

                ZStack(alignment: .leading) {
                    // Track
                    Capsule()
                        .fill(Theme.bgPrimary)
                        .overlay(Capsule().strokeBorder(Theme.borderSubtle, lineWidth: 1))

                    // Fill
                    Capsule()
                        .fill(Theme.cyanGradient)
                        .frame(width: max(0, thumbX))

                    // Thumb
                    Circle()
                        .fill(Theme.bgSecondary)
                        .overlay(Circle().strokeBorder(Theme.accentCyan, lineWidth: 2))
                        .frame(width: Theme.sliderThumbSize, height: Theme.sliderThumbSize)
                        .offset(x: max(0, min(thumbX - Theme.sliderThumbSize / 2, geo.size.width - Theme.sliderThumbSize)))
                }
                .frame(height: Theme.sliderTrackHeight)
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag in
                            let fraction = max(0, min(1, drag.location.x / geo.size.width))
                            value = range.lowerBound + fraction * (range.upperBound - range.lowerBound)
                        }
                )
            }
            .frame(height: 20)
        }
    }
}

struct CyanToggle: View {
    @Binding var isOn: Bool
    var label: String

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Theme.accentCyan.opacity(0.3) : Theme.bgPrimary)
                    .overlay(Capsule().strokeBorder(isOn ? Theme.accentCyan : Theme.borderSubtle, lineWidth: 1))
                    .frame(width: 40, height: 22)

                Circle()
                    .fill(isOn ? Theme.accentCyan : Theme.textSecondary)
                    .frame(width: 16, height: 16)
                    .padding(.horizontal, 3)
            }
            .animation(.spring(response: 0.25), value: isOn)
            .onTapGesture { isOn.toggle() }
        }
    }
}

struct GhostButton: View {
    let title: String
    let icon: String?
    var accent: Color = Theme.accentCyan
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 12, weight: .medium))
                }
                Text(title)
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isHovered ? accent : Theme.textSecondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(
                Capsule()
                    .fill(isHovered ? accent.opacity(0.1) : .clear)
                    .overlay(Capsule().strokeBorder(accent.opacity(isHovered ? 0.5 : 0.25), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

struct GradientPillButton: View {
    let title: String
    let icon: String?
    var isDisabled: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(
                Capsule()
                    .fill(isDisabled
                          ? AnyShapeStyle(Theme.textTertiary)
                          : AnyShapeStyle(Theme.cyanGradient))
            )
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .opacity(isDisabled ? 0.5 : 1)
    }
}

struct CyanProgressBar: View {
    var value: Double // 0-1

    @State private var shimmerOffset: CGFloat = -200

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Theme.bgPrimary)
                    .overlay(Capsule().strokeBorder(Theme.borderSubtle, lineWidth: 1))

                Capsule()
                    .fill(Theme.cyanGradient)
                    .frame(width: max(0, geo.size.width * value))
                    .overlay(
                        LinearGradient(
                            colors: [.clear, .white.opacity(0.3), .clear],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: 60)
                        .offset(x: shimmerOffset)
                        .mask(Capsule())
                    )
            }
        }
        .frame(height: 4)
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                shimmerOffset = 300
            }
        }
    }
}

struct StatusDot: View {
    var color: Color
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .overlay(
                Circle()
                    .fill(color.opacity(0.4))
                    .frame(width: isPulsing ? 16 : 8, height: isPulsing ? 16 : 8)
            )
            .onAppear {
                withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}
