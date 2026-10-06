import SwiftUI

/// Chart colours, keyed on model family.
///
/// The assignment is fixed and takes no context: colour follows the entity, never
/// its rank. If it depended on which families were present in the current week,
/// dropping Sonnet would repaint Haiku, and a reader who learned "Haiku is green"
/// would be misled.
///
/// Every value below was checked with a palette validator in both modes: all four
/// sit inside the lightness band, clear the chroma floor, hold ≥ 3:1 against their
/// surface, and keep a worst adjacent colour-vision-deficiency separation of
/// ΔE 19.6 against a ≥ 12 target. The terracotta is stepped darker on the dark
/// surface because `#D97757` sits at OKLCH L 0.672, just over the dark band's
/// 0.67 ceiling.
enum ChartPalette {
    /// nil means the family has no brand hue — draw it in the system's secondary
    /// label colour and call it "Other".
    static func hex(for family: ModelFamily, scheme: ColorScheme) -> UInt32? {
        let dark = scheme == .dark
        switch family {
        case .opus:   return dark ? 0xD3714E : 0xD97757
        case .sonnet: return dark ? 0x3987E5 : 0x2A78D6
        case .haiku:  return dark ? 0x3AA63A : 0x008300
        case .fable:  return dark ? 0x9085E9 : 0x4A3AA7
        case .other:  return nil
        }
    }

    static func color(for family: ModelFamily, scheme: ColorScheme) -> Color {
        guard let hex = hex(for: family, scheme: scheme) else {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(hex: hex)
    }

    /// The token-kind chart is a single series, so it gets a single hue. Shading
    /// its bars darker-where-bigger would encode bar length twice.
    static func sequentialHex(_ scheme: ColorScheme) -> UInt32 {
        scheme == .dark ? 0xD3714E : 0xD97757
    }

    static func sequential(_ scheme: ColorScheme) -> Color {
        Color(hex: sequentialHex(scheme))
    }

    /// The onion skin's ink. Deliberately not a model colour: the previous period
    /// is not a model, and borrowing one would make last week's Opus look like
    /// this week's. Muted, because it is context for the current line rather than
    /// a rival to it.
    static func ghost(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .secondaryLabelColor).opacity(scheme == .dark ? 0.8 : 0.65)
    }

    /// The current period's own total, drawn only when the window holds more than
    /// one family — with one, the family line already *is* the total, and a second
    /// line on top of it would be a duplicate the reader has to rule out.
    static func totalLine(_ scheme: ColorScheme) -> Color {
        Color(nsColor: .labelColor).opacity(scheme == .dark ? 0.55 : 0.45)
    }

    /// The activity grid's ramp: one hue, four steps of ink, plus the empty cell.
    /// Stepped in OKLCH so the four are evenly spaced to the eye rather than
    /// evenly spaced in sRGB, which would bunch the two darkest together.
    ///
    /// Light mode runs the way the request reads and the way ink behaves on
    /// paper: pale orange for a quiet day, dark brown for a heavy one. Dark mode
    /// cannot run the same direction — a brown cell on a near-black card is the
    /// *least* visible thing on the page, so the busiest day would recede exactly
    /// where it should shout. It runs dim-to-luminous instead, which keeps the
    /// thing the ramp actually encodes: more ink, more usage.
    static func heat(level: Int, scheme: ColorScheme) -> Color {
        let dark = scheme == .dark
        switch max(0, min(level, 4)) {
        case 1:  return dark ? Color(oklch: 0.340, 0.050, 46) : Color(oklch: 0.925, 0.045, 62)
        case 2:  return dark ? Color(oklch: 0.450, 0.085, 46) : Color(oklch: 0.845, 0.085, 56)
        case 3:  return dark ? Color(oklch: 0.565, 0.110, 46) : Color(oklch: 0.735, 0.125, 48)
        case 4:  return dark ? Color(oklch: 0.685, 0.130, 48) : Color(oklch: 0.545, 0.115, 40)
        // A day with nothing on it is still a day, so it keeps a cell — held just
        // above the card so the grid reads as a grid, never as scattered marks.
        default: return Color.primary.opacity(dark ? 0.085 : 0.06)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
