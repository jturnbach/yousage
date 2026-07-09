import Testing
@testable import YouSage

/// One million tokens of each kind, so a cost assertion reads as the rate itself.
private let oneMillionInput = TokenTotals(input: 1_000_000)
private let oneMillionOutput = TokenTotals(output: 1_000_000)
private let oneMillionCacheWrites = TokenTotals(cacheCreation: 1_000_000)
private let oneMillionCacheReads = TokenTotals(cacheRead: 1_000_000)

@Test func exactModelIDPricesFromTheTable() {
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-4-8") == 5.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-sonnet-4-6") == 3.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-fable-5") == 10.0)
}

@Test func trailingDateStampIsStrippedBeforeLookup() {
    #expect(Pricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    #expect(Pricing.cost(oneMillionInput, model: "claude-haiku-4-5-20251001") == 1.0)
}

@Test func bracketedVariantIsStrippedBeforeLookup() {
    #expect(Pricing.normalize("claude-opus-4-8[1m]") == "claude-opus-4-8")
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-4-8[1m]") == 5.0)
}

@Test func unknownPointReleaseFallsBackToItsFamilyRate() {
    #expect(Pricing.cost(oneMillionInput, model: "claude-sonnet-9-3") == 3.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-7-0-20301231") == 5.0)
}

@Test func unrecognizedModelIsUnpricedRatherThanFree() {
    #expect(Pricing.cost(oneMillionInput, model: "gpt-5") == nil)
    #expect(Pricing.cost(oneMillionInput, model: "unknown") == nil)
}

@Test func outputBillsAtTheOutputRate() {
    #expect(Pricing.cost(oneMillionOutput, model: "claude-opus-4-8") == 25.0)
}

@Test func cacheWritesBillAtOnePointTwoFiveTimesInput() {
    #expect(Pricing.cost(oneMillionCacheWrites, model: "claude-opus-4-8") == 6.25)
}

@Test func cacheReadsBillAtOneTenthOfInput() {
    #expect(Pricing.cost(oneMillionCacheReads, model: "claude-opus-4-8") == 0.5)
}

@Test func emptyTotalsCostNothingYetAreStillPriced() {
    #expect(Pricing.cost(TokenTotals(), model: "claude-opus-4-8") == 0.0)
}

@Test func legacyGenerationIDsAreUnpricedRatherThanMispricedAsCurrent() {
    // Claude 3 Opus listed at $15/$75, not the current Opus $5/$25. An
    // unanchored family match would confidently return the wrong number.
    #expect(Pricing.cost(oneMillionInput, model: "claude-3-opus-20240229") == nil)
    #expect(Pricing.cost(oneMillionInput, model: "claude-3-haiku-20240307") == nil)
}

@Test func aBareFamilyWordIsNotAModelID() {
    #expect(Pricing.cost(oneMillionInput, model: "opus") == nil)
}
