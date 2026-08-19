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
