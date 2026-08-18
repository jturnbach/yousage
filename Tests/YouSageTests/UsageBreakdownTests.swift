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
    #expect(b.buckets.count == 7)
    #expect(b.totals.total == 0)
    #expect(b.cost.amount == 0)
    #expect(b.cost.isComplete)
}

@Test func daysAreOldestFirstAndOnlyTheLastIsToday() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.buckets.first!.start == cal.startOfDay(for: at(2026, 7, 3)))
    #expect(b.buckets.last!.start == cal.startOfDay(for: at(2026, 7, 9)))
    #expect(b.buckets.filter(\.isCurrent).count == 1)
    #expect(b.buckets.last!.isCurrent)
}

@Test func aDayWithNoActivityIsPresentAndEmptyRatherThanAbsent() {
    let events = [event(at(2026, 7, 9), "claude-opus-4-8")]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.buckets.count == 7)
    #expect(b.buckets[0].totals.total == 0)
    #expect(b.buckets[0].byFamily.isEmpty)
    #expect(b.buckets[6].totals.total == 1_000)
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
    let march8 = b.buckets.first { $0.start == cal.startOfDay(for: at(2026, 3, 8)) }
    #expect(march8?.totals.total == 2_000)
}

@Test func bucketingSurvivesFallBack() {
    // 2026-11-01 is 25 hours long; 01:30 occurs twice.
    let events = [
        event(at(2026, 11, 1, 1, 30), "claude-opus-4-8"),
        event(at(2026, 11, 1, 23, 0), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 11, 3), calendar: cal)
    let nov1 = b.buckets.first { $0.start == cal.startOfDay(for: at(2026, 11, 1)) }
    #expect(nov1?.totals.total == 2_000)
}

@Test func opusVersionsFoldToOneFamilySegmentButStayTwoCostRows() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-opus-4-7"),
        event(at(2026, 7, 9), "claude-haiku-4-5"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let today = b.buckets.last!
    #expect(today.byFamily.map(\.family) == [.opus, .haiku])
    #expect(today.byFamily.first!.totals.total == 2_000)   // both Opus versions
    #expect(b.models.map(\.displayName).sorted() == ["Haiku 4.5", "Opus 4.7", "Opus 4.8"])
}

@Test func familyTotalIsZeroOnDaysTheFamilyWasIdle() {
    let events = [
        event(at(2026, 7, 8), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-fable-5"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let yesterday = b.buckets[5], today = b.buckets[6]
    #expect(yesterday.total(of: .opus) == 1_000)
    #expect(yesterday.total(of: .fable) == 0)
    #expect(today.total(of: .opus) == 0)
    #expect(today.total(of: .fable) == 1_000)
}

@Test func familyCostIsZeroWhenIdleAndTheFamiliesSumToTheDayCost() {
    let events = [
        event(at(2026, 7, 8), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-fable-5"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let yesterday = b.buckets[5], today = b.buckets[6]

    #expect(yesterday.cost(of: .fable) == 0)
    #expect(today.cost(of: .opus) > 0)
    // Same tokens, twice the input rate: Fable is $10/M against Opus's $5/M.
    #expect(today.cost(of: .fable) == today.cost(of: .opus) * 2)
    #expect(abs(today.cost(of: .opus) + today.cost(of: .fable) - today.cost.amount) < 1e-12)
}

@Test func familySegmentsFollowDeclarationOrderNotInsertionOrder() {
    let events = [
        event(at(2026, 7, 9), "claude-haiku-4-5"),
        event(at(2026, 7, 9), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.buckets.last!.byFamily.map(\.family) == [.opus, .haiku])
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
    let summed = b.buckets.reduce(0.0) { $0 + $1.cost.amount }
    #expect(abs(summed - b.cost.amount) < 1e-9)
    #expect(abs(b.cost.amount - 7.0) < 1e-9)   // $5.00 + $2.00
}

// MARK: - Range

@Test func aDailyRangeDrawsOneBucketPerDay() {
    // `.today` is hourly and is covered by its own tests below.
    for range in UsageRange.allCases where range.unit == .day {
        let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal, range: range)
        #expect(b.buckets.count == range.days)
        #expect(b.range == range)
    }
}

@Test func aLongerRangeReachesEventsAShorterOneExcludes() {
    let events = [event(at(2026, 6, 20), "claude-opus-4-8")]   // 19 days back
    let week = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal, range: .week)
    let month = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal, range: .month)
    #expect(week.totals.total == 0)
    #expect(month.totals.total == 1_000)
}

// MARK: - Previous period

@Test func previousPeriodIsTheEqualLengthWindowEndingWhereThisOneBegins() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 500),    // in span
        event(at(2026, 7, 2), "claude-opus-4-8", input: 300),    // previous 7 days
        event(at(2026, 6, 25), "claude-opus-4-8", input: 900),   // older still — neither
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.totals.total == 500)
    #expect(b.previous?.totals.total == 300)
}

@Test func previousPeriodIsAbsentWhenItHeldNoActivity() {
    // A change from zero is not a percentage, and "we never scanned that far
    // back" looks exactly like "you were idle". Both must suppress the chip.
    let events = [event(at(2026, 7, 9), "claude-opus-4-8")]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.previous == nil)
    #expect(b.tokenChange == nil)
}

@Test func changesAreFractionsOfThePreviousValue() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 1_200),
        event(at(2026, 7, 2), "claude-opus-4-8", input: 1_000),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(abs((b.tokenChange ?? 0) - 0.2) < 1e-9)
    #expect(abs((b.costChange ?? 0) - 0.2) < 1e-9)     // one model, so cost tracks tokens
    #expect(abs((b.messageChange ?? 0) - 0.0) < 1e-9)  // one message each side
}

// MARK: - Cache hit rate

@Test func cacheHitRateIsCacheReadsShareOfEverythingSentToTheModel() {
    let events = [UsageEvent(date: at(2026, 7, 9), model: "claude-opus-4-8",
                             totals: TokenTotals(input: 10, output: 999, cacheCreation: 10,
                                                 cacheRead: 80, messages: 1))]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    // Output is generated, never read from cache, so it is not in the denominator.
    #expect(abs((b.cacheHitRate ?? 0) - 0.8) < 1e-9)
}

@Test func cacheHitRateIsAbsentWithNothingToRead() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.cacheHitRate == nil)
}

// MARK: - Month projection

@Test func monthEndProjectionExtrapolatesSpendAcrossTheWholeMonth() {
    // Half a 31-day July gone (15.5 days), $10 spent → $20 projected.
    let events = [event(at(2026, 7, 3), "claude-opus-4-8", input: 2_000_000)]  // $10
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 16, 12), calendar: cal)
    #expect(abs(b.month.spendToDate - 10) < 1e-9)
    #expect(abs(b.month.projected - 20) < 0.01)
}

@Test func lastMonthsSpendIsCarriedForTheProjectionChip() {
    let events = [
        event(at(2026, 7, 3), "claude-opus-4-8", input: 2_000_000),   // $10 this month
        event(at(2026, 6, 14), "claude-opus-4-8", input: 1_000_000),  // $5 in June
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 16, 12), calendar: cal)
    #expect(abs((b.month.previousCost ?? 0) - 5) < 1e-9)
    #expect(b.month.previousName == "June")
}

@Test func anIdlePreviousMonthCarriesNoComparison() {
    let events = [event(at(2026, 7, 3), "claude-opus-4-8", input: 2_000_000)]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 16, 12), calendar: cal)
    #expect(b.month.previousCost == nil)
    #expect(b.month.projectedChange == nil)
}

// MARK: - Today

@Test func todayIsAnHourlyRangeAndTheOthersAreDaily() {
    #expect(UsageRange.today.unit == .hour)
    #expect(UsageRange.today.days == 1)
    #expect(UsageRange.today.label == "Today")
    for range in UsageRange.allCases where range != .today {
        #expect(range.unit == .day)
    }
}

@Test func todayBucketsByHourFromMidnightThroughTheCurrentHour() {
    // 14:30 — fifteen buckets, 00:00 through 14:00. The hours that have not
    // happened yet are absent, not zero: a zero-filled evening would draw a line
    // collapsing to the axis for the rest of the day.
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(b.buckets.count == 15)
    #expect(b.buckets.first!.start == at(2026, 7, 9, 0, 0))
    #expect(b.buckets.last!.start == at(2026, 7, 9, 14, 0))
}

@Test func onlyTheHourTheClockIsInsideIsStillAccruing() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(b.buckets.filter(\.isCurrent).count == 1)
    #expect(b.buckets.last!.isCurrent)
}

@Test func todayStartsAtMidnightAndExcludesYesterday() {
    let events = [
        event(at(2026, 7, 8, 23, 59), "claude-opus-4-8", input: 700),   // yesterday — out
        event(at(2026, 7, 9, 0, 1), "claude-opus-4-8", input: 300),     // first minute — in
        event(at(2026, 7, 9, 14, 5), "claude-opus-4-8", input: 200),    // current hour — in
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(b.totals.total == 500)
    #expect(b.buckets.first!.totals.total == 300)
    #expect(b.buckets.last!.totals.total == 200)
}

@Test func anIdleHourIsPresentAndEmptyRatherThanAbsent() {
    let events = [event(at(2026, 7, 9, 2, 15), "claude-opus-4-8")]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9, 4, 30), calendar: cal, range: .today)
    #expect(b.buckets.count == 5)
    #expect(b.buckets[2].totals.total == 1_000)
    #expect(b.buckets[3].byFamily.isEmpty)
    #expect(b.buckets[3].totals.total == 0)
}

@Test func hourlyCostsSumToTheTotalCost() {
    let events = [
        event(at(2026, 7, 9, 1, 0), "claude-opus-4-8", input: 1_000_000),    // $5.00
        event(at(2026, 7, 9, 9, 30), "claude-haiku-4-5", input: 2_000_000),  // $2.00
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    let summed = b.buckets.reduce(0.0) { $0 + $1.cost.amount }
    #expect(abs(summed - b.cost.amount) < 1e-9)
    #expect(abs(b.cost.amount - 7.0) < 1e-9)
}

@Test func todaysPreviousPeriodIsYesterdayUpToThisTimeOfDay() {
    // Half a day against a whole one would invent a fall in usage every morning.
    let events = [
        event(at(2026, 7, 9, 10, 0), "claude-opus-4-8", input: 500),    // today
        event(at(2026, 7, 8, 10, 0), "claude-opus-4-8", input: 300),    // yesterday, before 14:30
        event(at(2026, 7, 8, 20, 0), "claude-opus-4-8", input: 900),    // yesterday, after — out
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(b.totals.total == 500)
    #expect(b.previous?.totals.total == 300)
}

@Test func messagesPerDayCountsTodayAsOneDayNotAsItsHours() {
    let events = [
        event(at(2026, 7, 9, 1, 0), "claude-opus-4-8"),
        event(at(2026, 7, 9, 2, 0), "claude-opus-4-8"),
        event(at(2026, 7, 9, 3, 0), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(b.totals.messages == 3)
    #expect(b.messagesPerDay == 3)
}

@Test func hourlyBucketingSurvivesSpringForward() {
    // 2026-03-08 skips 02:00 in America/New_York: midnight to 04:30 is four hours.
    let events = [
        event(at(2026, 3, 8, 1, 30), "claude-opus-4-8"),
        event(at(2026, 3, 8, 3, 30), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 3, 8, 4, 30), calendar: cal, range: .today)
    #expect(b.buckets.count == 4)
    #expect(b.buckets.map(\.totals.total) == [0, 1_000, 1_000, 0])
    #expect(b.totals.total == 2_000)
}

@Test func hourlyBucketingSurvivesFallBack() {
    // 2026-11-01 repeats 01:00 in America/New_York, so midnight to 03:30 is five
    // hours, not four. `at(...)` resolves the ambiguous hour to the first pass.
    let b = UsageBreakdown.make(from: [event(at(2026, 11, 1, 1, 30), "claude-opus-4-8")],
                                now: at(2026, 11, 1, 3, 30), calendar: cal, range: .today)
    #expect(b.buckets.count == 5)
    #expect(b.buckets.map(\.totals.total) == [0, 1_000, 0, 0, 0])
    #expect(b.buckets.last!.isCurrent)
}
