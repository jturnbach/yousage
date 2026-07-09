import Testing
@testable import YouSage

@Test func aCompleteEstimateRendersAsAPlainAmount() {
    #expect(CostEstimate(amount: 4.12).display == "$4.12")
    #expect(CostEstimate(amount: 27.6).display == "$27.60")
}

@Test func anEstimateWithUnpricedModelsRendersAsALowerBound() {
    let estimate = CostEstimate(amount: 27.6, unpricedModels: ["claude-zeta-9"])
    #expect(estimate.isComplete == false)
    #expect(estimate.display == "≥ $27.60")
}

@Test func anEstimateWithNoUnpricedModelsIsComplete() {
    #expect(CostEstimate(amount: 0).isComplete)
}
