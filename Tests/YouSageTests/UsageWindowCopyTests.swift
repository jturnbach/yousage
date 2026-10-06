import Foundation
import Testing
@testable import YouSage

/// The window's own words. Locale decides how a date is spelled, so these assert
/// the parts the copy chooses — the name of the period and what it is compared
/// against — never the formatting of the date itself.
private let newYork = TimeZone(identifier: "America/New_York")!

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = newYork
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ date: Date, input: Int = 1_000) -> UsageEvent {
    UsageEvent(date: date, model: "claude-opus-4-8", totals: TokenTotals(input: input, messages: 1))
}

private func breakdown(_ range: UsageRange, offset: Int, events: [UsageEvent] = []) -> UsageBreakdown {
    UsageBreakdown.make(from: events, now: at(2026, 7, 9, 14, 30), calendar: cal,
                        range: range, offset: offset)
}

@Test func thePresentDayIsSubtitledTodayAndTheOneBeforeItYesterday() {
    #expect(UsageWindow.dateRange(breakdown(.today, offset: 0)).hasPrefix("Today · "))
    #expect(UsageWindow.dateRange(breakdown(.today, offset: 1)).hasPrefix("Yesterday · "))
}

@Test func aDayFurtherBackIsSubtitledByItsOwnDate() {
    let subtitle = UsageWindow.dateRange(breakdown(.today, offset: 2))
    #expect(!subtitle.hasPrefix("Today"))
    #expect(!subtitle.hasPrefix("Yesterday"))
    #expect(!subtitle.isEmpty)
}

@Test func aPagedBackWeekIsSubtitledWithBothEndsOfItsSpan() {
    #expect(UsageWindow.dateRange(breakdown(.week, offset: 1)).contains("–"))
}

@Test func todayIsComparedToThisTimeYesterdayAndAPastDayToThePrecedingWholeOne() {
    // The comparison the model actually makes; the footnote is what tells the
    // reader which of the two it is looking at.
    let present = breakdown(.today, offset: 0, events: [event(at(2026, 7, 8, 10, 0))])
    #expect(UsageWindow.previousTokens(present).hasSuffix("yesterday to this time"))

    let past = breakdown(.today, offset: 1, events: [event(at(2026, 7, 7, 20, 0))])
    #expect(UsageWindow.previousTokens(past).hasSuffix("the day before"))
}

@Test func aWeekIsComparedToTheSamePointLastWeekWhileItRunsAndWholeOnceItEnds() {
    let running = breakdown(.week, offset: 0, events: [event(at(2026, 6, 30))])
    #expect(UsageWindow.previousTokens(running).hasSuffix("last week to this point"))

    let finished = breakdown(.week, offset: 1, events: [event(at(2026, 6, 25))])
    #expect(UsageWindow.previousTokens(finished).hasSuffix("the week before"))
}

@Test func aPreviousPeriodWithNothingYetToCompareStillReadsAsNoActivity() {
    // Yesterday afternoon keeps the previous period alive for the overlay, but
    // the chip's denominator is still zero and the footnote must say so rather
    // than print "vs. 0".
    let quiet = breakdown(.today, offset: 0, events: [event(at(2026, 7, 9, 10, 0)),
                                                       event(at(2026, 7, 8, 20, 0))])
    #expect(UsageWindow.previousTokens(quiet) == "no activity yesterday to this time")
}

@Test func aFinishedDayReportsItsWholeCountRatherThanWhatHasElapsed() {
    #expect(UsageWindow.messageRate(breakdown(.today, offset: 0)) == "so far today")
    #expect(UsageWindow.messageRate(breakdown(.today, offset: 1)) == "across the day")
    #expect(UsageWindow.messageRate(breakdown(.week, offset: 1)).hasSuffix("/ day avg"))
}
