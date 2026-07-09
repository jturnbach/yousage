import Testing
@testable import YouSage

@Test func modelDisplayNameStripsEveryPrefixAndSuffix() {
    #expect(modelDisplayName("claude-opus-4-8") == "Opus 4.8")
    #expect(modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(modelDisplayName("claude-opus-4-8[1m]") == "Opus 4.8")
    // Previously rendered "Claude opus.4.8": the old loop stripped one prefix, not both.
    #expect(modelDisplayName("anthropic.claude-opus-4-8") == "Opus 4.8")
}

@Test func modelDisplayNamePassesUnknownIDsThroughLightlyCleaned() {
    #expect(modelDisplayName("gpt-5") == "Gpt 5")
    #expect(modelDisplayName("claude-sonnet-5") == "Sonnet 5")
}

@Test func modelTokensDisplayNameDelegatesToTheFreeFunction() {
    let t = ModelTokens(model: "anthropic.claude-opus-4-8", totals: TokenTotals())
    #expect(t.displayName == "Opus 4.8")
}

@Test func familyResolvesCurrentGenerations() {
    #expect(ModelFamily(modelID: "claude-opus-4-8") == .opus)
    #expect(ModelFamily(modelID: "anthropic.claude-opus-4-8") == .opus)
    #expect(ModelFamily(modelID: "claude-sonnet-5") == .sonnet)
    #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
    #expect(ModelFamily(modelID: "claude-fable-5") == .fable)
    #expect(ModelFamily(modelID: "claude-opus-9-0") == .opus)   // future release
}

@Test func familyRejectsLegacyGenerationsAndNonModels() {
    // Same refusal pricing makes: a past generation is not the current family.
    #expect(ModelFamily(modelID: "claude-3-opus-20240229") == .other)
    #expect(ModelFamily(modelID: "claude-opusglobular") == .other)
    #expect(ModelFamily(modelID: "gpt-5") == .other)
    #expect(ModelFamily(modelID: "") == .other)
}

@Test func mythosIsOtherNotFable() {
    // Mythos prices like Fable but is a different model. Labelling it "Fable"
    // on screen would be a lie.
    #expect(ModelFamily(modelID: "claude-mythos-5") == .other)
}

@Test func tokenKindReadsTheCounterItNames() {
    let t = TokenTotals(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, messages: 1)
    #expect(TokenKind.input.count(in: t) == 1)
    #expect(TokenKind.output.count(in: t) == 2)
    #expect(TokenKind.cacheWrite.count(in: t) == 3)   // cacheCreation
    #expect(TokenKind.cacheRead.count(in: t) == 4)
    #expect(TokenKind.allCases == [.cacheRead, .cacheWrite, .output, .input])
}
