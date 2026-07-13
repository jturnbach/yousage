import SwiftUI

// MARK: - Colour

extension Color {
    /// The design tokens are specified in OKLCH, so they are read in OKLCH rather
    /// than hand-converted to hex and left to rot. Perceptual lightness is what
    /// makes the light and dark chip sets siblings instead of guesses, and that
    /// relationship is only legible in the original space.
    init(oklch l: Double, _ c: Double, _ hDegrees: Double) {
        let h = hDegrees * .pi / 180
        let a = c * cos(h), b = c * sin(h)

        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let (L, M, S) = (l_ * l_ * l_, m_ * m_ * m_, s_ * s_ * s_)

        let r =  4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let g = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S

        func encode(_ v: Double) -> Double {
            let c = min(max(v, 0), 1)
            return c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }
        self.init(.sRGB, red: encode(r), green: encode(g), blue: encode(bl), opacity: 1)
    }
}

extension ChartPalette {
    /// The accent the dashboard is built around: the same terracotta Opus wears,
    /// because the accent *is* the product's identity colour, not a fourth hue.
    static func accent(_ scheme: ColorScheme) -> Color {
        color(for: .opus, scheme: scheme)
    }
}

// MARK: - Chips

/// A trend chip: "▲ 18%".
///
/// The style is chosen by the caller, not derived from the sign, because the sign
/// alone does not carry the meaning. Tokens rising is just activity; *cost* rising
/// is the thing you would want to catch. Green-when-up would be a lie on the bill.
struct TrendChip: View {
    enum Style { case up, warn, neutral }

    let change: Double
    var style: Style
    var suffix: String?
    var small = false

    @Environment(\.colorScheme) private var scheme

    /// Below this, the chip would read "▲0.0%" — an arrow pointing somewhere while
    /// admitting it went nowhere. Flat is not a trend, so it draws nothing at all.
    private static let flat = 0.0005

    @ViewBuilder
    var body: some View {
        if abs(change) >= Self.flat {
            Text(label)
                .font(.system(size: small ? 10.5 : 11, weight: .semibold))
                .foregroundStyle(ink)
                .padding(.horizontal, small ? 5 : 7)
                .padding(.vertical, small ? 1 : 2)
                .background(fill, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(accessibleLabel)
        }
    }

    private var rising: Bool { change >= 0 }

    private var label: String {
        let arrow = rising ? "▲" : "▼"
        let percent = abs(change * 100)
        // Under 1% would round to "▲0%", which reads as no change at all while
        // still drawing an arrow. One decimal keeps the arrow honest.
        let value = percent < 1 ? String(format: "%.1f%%", percent)
                                : "\(Int(percent.rounded()))%"
        return [arrow + (small ? "" : " ") + value, suffix].compactMap { $0 }.joined(separator: " ")
    }

    private var accessibleLabel: String {
        let direction = rising ? "up" : "down"
        return "\(direction) \(Int(abs(change * 100).rounded())) percent \(suffix ?? "")"
    }

    private var dark: Bool { scheme == .dark }

    private var fill: Color {
        switch style {
        case .up:      return dark ? Color(oklch: 0.32, 0.05, 155) : Color(oklch: 0.90, 0.06, 155)
        case .warn:    return dark ? Color(oklch: 0.34, 0.05, 45)  : Color(oklch: 0.92, 0.05, 45)
        case .neutral: return dark ? Color(oklch: 0.33, 0.008, 55) : Color(oklch: 0.93, 0.01, 55)
        }
    }

    private var ink: Color {
        switch style {
        case .up:      return dark ? Color(oklch: 0.80, 0.10, 155) : Color(oklch: 0.45, 0.12, 155)
        case .warn:    return dark ? Color(oklch: 0.78, 0.11, 45)  : Color(oklch: 0.50, 0.13, 40)
        case .neutral: return dark ? Color(oklch: 0.72, 0.008, 55) : Color(oklch: 0.50, 0.01, 55)
        }
    }
}

extension TrendChip {
    /// Cost is the one metric where up is the direction you would want to notice,
    /// so it is the one metric whose chip changes colour with its sign.
    static func cost(_ change: Double, suffix: String? = nil, small: Bool = false) -> TrendChip {
        TrendChip(change: change, style: change >= 0 ? .warn : .up, suffix: suffix, small: small)
    }

    /// Volume metrics — tokens, messages, cache hits. Rising is activity, not a
    /// warning; falling is quiet, not a failure.
    static func volume(_ change: Double, small: Bool = false) -> TrendChip {
        TrendChip(change: change, style: change >= 0 ? .up : .neutral, small: small)
    }
}

// MARK: - Meters

/// A track with a fill. Every proportion in the dashboard — cost share, budget,
/// token kind — is one of these, so they all read as the same measurement.
struct Meter: View {
    let fraction: Double
    var fill: AnyShapeStyle
    var height: CGFloat = 7

    init(fraction: Double, fill: some ShapeStyle, height: CGFloat = 7) {
        self.fraction = fraction
        self.fill = AnyShapeStyle(fill)
        self.height = height
    }

    var body: some View {
        GeometryReader { geo in
            let radius = height / 2 + 1.5
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: radius)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: radius)
                    .fill(fill)
                    // A nonzero share always draws something. A 0.4%-of-spend bar
                    // that rounds to no pixels reads as "nothing", which is a
                    // different claim than "a little".
                    .frame(width: fraction > 0
                           ? max(geo.size.width * min(fraction, 1), 4)
                           : 0)
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)   // Every meter is direct-labelled beside it.
    }
}

// MARK: - Layout

/// An HStack whose children take fixed fractions of the width, so the hero strip's
/// 1.45 / 1 / 1 and the lower row's 1.5 / 1 survive a resize. `.frame(maxWidth:)`
/// can only split evenly, and a GeometryReader here would collapse the height.
struct WeightedHStack: Layout {
    var weights: [CGFloat]
    var spacing: CGFloat = 12

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        let widths = columnWidths(in: width, count: subviews.count)
        let height = zip(subviews, widths)
            .map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            .max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let widths = columnWidths(in: bounds.width, count: subviews.count)
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths) {
            subview.place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    private func columnWidths(in total: CGFloat, count: Int) -> [CGFloat] {
        guard count > 0 else { return [] }
        // A missing weight is 1: the layout should degrade, not trap.
        let w = (0..<count).map { $0 < weights.count ? weights[$0] : 1 }
        let sum = w.reduce(0, +)
        let free = max(total - spacing * CGFloat(count - 1), 0)
        guard sum > 0 else { return Array(repeating: free / CGFloat(count), count: count) }
        return w.map { free * $0 / sum }
    }
}

// MARK: - Cards

/// A dashboard card: the design's 14px panel, rendered on the window's glass so it
/// stays the same material as the popover rather than a flat sheet laid over it.
struct DashCard<Content: View>: View {
    var title: String?
    var padding: EdgeInsets = EdgeInsets(top: 15, leading: 16, bottom: 15, trailing: 16)
    var tinted = false
    @ViewBuilder var content: Content

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            if let title {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.14)
            }
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            // The projection card is the page's one lit surface — it is the only
            // number that looks forward, and the wash is what says so.
            if tinted {
                RoundedRectangle(cornerRadius: 14).fill(
                    LinearGradient(
                        colors: [ChartPalette.accent(scheme).opacity(scheme == .dark ? 0.22 : 0.12),
                                 .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing)
                )
            }
        }
        .glassSurface(cornerRadius: 14)
    }
}

/// The label above a metric: 12px, dimmed, optionally with a chip pushed right.
struct CardLabel<Trailing: View>: View {
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension CardLabel where Trailing == EmptyView {
    init(_ text: String) {
        self.init(text: text) { EmptyView() }
    }
}

/// A metric number. Tight tracking and a heavy weight, per the type scale — these
/// are the figures the window exists to show.
struct MetricValue: View {
    let text: String
    var size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .bold))
            .tracking(size * -0.02)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

/// Subtext under a metric: the comparison, the rate, the per-unit figure.
struct CardFootnote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
    }
}

/// An 8px rounded swatch — the model's colour, wherever its name appears without
/// a mark beside it to carry the identity.
struct ModelSwatch: View {
    let family: ModelFamily
    var size: CGFloat = 8
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(ChartPalette.color(for: family, scheme: scheme))
            .frame(width: size, height: size)
    }
}
