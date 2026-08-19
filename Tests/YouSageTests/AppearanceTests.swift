import AppKit
import Testing
@testable import YouSage

@Test func appearanceDefaultsToFollowingTheSystem() {
    #expect(Appearance.default == .system)
    // Nothing stored is the first launch, which must follow macOS rather than
    // pick a side on the user's behalf.
    #expect(Appearance(stored: nil) == .system)
    #expect(Appearance(stored: "nonsense-from-an-older-build") == .system)
}

@Test func appearanceRoundTripsThroughItsStoredValue() {
    for appearance in Appearance.allCases {
        #expect(Appearance(stored: appearance.rawValue) == appearance)
    }
}

@Test func followingTheSystemMeansNoAppearanceOfOurOwn() {
    // nil is what keeps the app tracking the system setting while it runs; a
    // resolved .aqua would freeze it at whatever macOS happened to be at launch.
    #expect(Appearance.system.appearanceName == nil)
    #expect(Appearance.light.appearanceName == .aqua)
    #expect(Appearance.dark.appearanceName == .darkAqua)
}

@Test func eachAppearanceNamesItselfForThePicker() {
    #expect(Appearance.system.displayName == "System")
    #expect(Appearance.light.displayName == "Light")
    #expect(Appearance.dark.displayName == "Dark")
    #expect(Appearance.allCases == [.system, .light, .dark])
}
