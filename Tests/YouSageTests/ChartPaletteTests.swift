import SwiftUI
import Testing
@testable import YouSage

@Test func hexesMatchTheValidatedPalette() {
    // Validated for lightness band, chroma floor, 3:1 contrast, and CVD
    // separation (worst adjacent ΔE 19.6, target ≥ 12) in both modes.
    #expect(ChartPalette.hex(for: .opus, scheme: .light) == 0xD97757)
    #expect(ChartPalette.hex(for: .opus, scheme: .dark) == 0xD3714E)
    #expect(ChartPalette.hex(for: .sonnet, scheme: .light) == 0x2A78D6)
    #expect(ChartPalette.hex(for: .sonnet, scheme: .dark) == 0x3987E5)
    #expect(ChartPalette.hex(for: .haiku, scheme: .light) == 0x008300)
    #expect(ChartPalette.hex(for: .haiku, scheme: .dark) == 0x3AA63A)
    #expect(ChartPalette.hex(for: .fable, scheme: .light) == 0x4A3AA7)
    #expect(ChartPalette.hex(for: .fable, scheme: .dark) == 0x9085E9)
}

@Test func otherHasNoHexAndDefersToTheSystemColour() {
    #expect(ChartPalette.hex(for: .other, scheme: .light) == nil)
    #expect(ChartPalette.hex(for: .other, scheme: .dark) == nil)
}

@Test func everyColouredFamilyIsDistinctWithinAScheme() {
    for scheme in [ColorScheme.light, .dark] {
        let hexes = ModelFamily.allCases.compactMap { ChartPalette.hex(for: $0, scheme: scheme) }
        #expect(hexes.count == 4)
        #expect(Set(hexes).count == 4)
    }
}

@Test func aFamilysColourDependsOnNothingButItself() {
    // Colour follows the entity, never its rank: dropping Sonnet from a week
    // must not repaint Haiku. `hex` takes no context, so this holds by
    // construction — the test pins the property against a future refactor.
    let before = ChartPalette.hex(for: .haiku, scheme: .light)
    let subset: [ModelFamily] = [.opus, .haiku]
    let after = subset.compactMap { $0 == .haiku ? ChartPalette.hex(for: $0, scheme: .light) : nil }.first
    #expect(before == after)
}

@Test func theSequentialHueIsTheBrandTerracotta() {
    // The token-kind chart is one series, so it takes one colour.
    #expect(ChartPalette.sequentialHex(.light) == 0xD97757)
    #expect(ChartPalette.sequentialHex(.dark) == 0xD3714E)
}
