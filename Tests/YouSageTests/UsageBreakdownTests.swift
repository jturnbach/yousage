import Foundation
import Testing
@testable import YouSage

/// Fixed zone so bucketing tests do not depend on the machine's locale.
private let newYork = TimeZone(identifier: "America/New_York")!

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = newYork
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ date: Date, _ model: String, input: Int = 1_000) -> UsageEvent {
    UsageEvent(date: date, model: model, totals: TokenTotals(input: input, messages: 1))
}

@Test func sevenDaysAreAlwaysReturnedEvenFromNoEvents() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.count == 7)
    #expect(b.totals.total == 0)
    #expect(b.cost.amount == 0)
    #expect(b.cost.isComplete)
}

@Test func daysAreOldestFirstAndOnlyTheLastIsToday() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.first!.day == cal.startOfDay(for: at(2026, 7, 3)))
    #expect(b.days.last!.day == cal.startOfDay(for: at(2026, 7, 9)))
    #expect(b.days.filter(\.isToday).count == 1)
    #expect(b.days.last!.isToday)
}

@Test func aDayWithNoActivityIsPresentAndEmptyRatherThanAbsent() {
    let events = [event(at(2026, 7, 9), "claude-opus-4-8")]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.count == 7)
    #expect(b.days[0].totals.total == 0)
    #expect(b.days[0].byFamily.isEmpty)
    #expect(b.days[6].totals.total == 1_000)
}

@Test func eventsOutsideTheSpanAreExcluded() {
    let events = [
        event(at(2026, 7, 1), "claude-opus-4-8"),   // 8 days ago — out
        event(at(2026, 7, 3), "claude-opus-4-8"),   // oldest day in span
        event(at(2026, 7, 9), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.totals.total == 2_000)
    #expect(b.totals.messages == 2)
}

@Test func bucketingSurvivesSpringForward() {
    // 2026-03-08 is 23 hours long in America/New_York.
    let events = [
        event(at(2026, 3, 8, 1, 30), "claude-opus-4-8"),   // before the jump
        event(at(2026, 3, 8, 3, 30), "claude-opus-4-8"),   // after the jump
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 3, 10), calendar: cal)
    let march8 = b.days.first { $0.day == cal.startOfDay(for: at(2026, 3, 8)) }
    #expect(march8?.totals.total == 2_000)
}

@Test func bucketingSurvivesFallBack() {
    // 2026-11-01 is 25 hours long; 01:30 occurs twice.
    let events = [
        event(at(2026, 11, 1, 1, 30), "claude-opus-4-8"),
        event(at(2026, 11, 1, 23, 0), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 11, 3), calendar: cal)
    let nov1 = b.days.first { $0.day == cal.startOfDay(for: at(2026, 11, 1)) }
    #expect(nov1?.totals.total == 2_000)
}

@Test func opusVersionsFoldToOneFamilySegmentButStayTwoCostRows() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-opus-4-7"),
        event(at(2026, 7, 9), "claude-haiku-4-5"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let today = b.days.last!
    #expect(today.byFamily.map(\.family) == [.opus, .haiku])
    #expect(today.byFamily.first!.totals.total == 2_000)   // both Opus versions
    #expect(b.models.map(\.displayName).sorted() == ["Haiku 4.5", "Opus 4.7", "Opus 4.8"])
}

@Test func familySegmentsFollowDeclarationOrderNotInsertionOrder() {
    let events = [
        event(at(2026, 7, 9), "claude-haiku-4-5"),
        event(at(2026, 7, 9), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.last!.byFamily.map(\.family) == [.opus, .haiku])
}

@Test func modelsSortByCostNotByTokens() {
    // Haiku has more tokens; Opus costs more. Cost wins.
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 2_000_000),   // $10.00
        event(at(2026, 7, 9), "claude-haiku-4-5", input: 3_000_000),  // $3.00
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.models.map(\.displayName) == ["Opus 4.8", "Haiku 4.5"])
    #expect(b.models[0].cost.amount == 10.0)
    #expect(b.models[1].cost.amount == 3.0)
    #expect(b.totals.total == 5_000_000)
}

@Test func anUnpriceableModelIsOtherAndForcesALowerBound() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 1_000_000),   // $5.00
        event(at(2026, 7, 9), "gpt-5", input: 1_000_000),             // unpriceable
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.cost.amount == 5.0)
    #expect(b.cost.unpricedModels == ["gpt-5"])
    #expect(b.cost.isComplete == false)
    #expect(b.cost.display.hasPrefix("≥"))
    #expect(b.models.first(where: { $0.model == "gpt-5" })?.family == .other)
}

@Test func kindsAlwaysAppearInDeclarationOrderEvenWhenZero() {
    let events = [UsageEvent(date: at(2026, 7, 9), model: "claude-opus-4-8",
                             totals: TokenTotals(input: 5, output: 0, cacheCreation: 0,
                                                 cacheRead: 70, messages: 1))]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.kinds.map(\.kind) == [.cacheRead, .cacheWrite, .output, .input])
    #expect(b.kinds.map(\.count) == [70, 0, 0, 5])
}

@Test func perDayCostsSumToTheTotalCost() {
    let events = [
        event(at(2026, 7, 7), "claude-opus-4-8", input: 1_000_000),
        event(at(2026, 7, 9), "claude-haiku-4-5", input: 2_000_000),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let summed = b.days.reduce(0.0) { $0 + $1.cost.amount }
    #expect(abs(summed - b.cost.amount) < 1e-9)
    #expect(abs(b.cost.amount - 7.0) < 1e-9)   // $5.00 + $2.00
}
