import Foundation
import Testing
@testable import YouSage

/// The activity grid's arithmetic. A cell on the wrong day looks exactly as
/// plausible as a cell on the right one, so the day bucketing, the week
/// columns, and the ink scale are all pinned here rather than eyeballed.
private let newYork = TimeZone(identifier: "America/New_York")!

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = newYork
    c.firstWeekday = 1   // Sunday, as US locales have it
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ date: Date, input: Int = 1_000, model: String = "claude-opus-4-8") -> UsageEvent {
    UsageEvent(date: date, model: model, totals: TokenTotals(input: input, messages: 1))
}

private let now = at(2026, 7, 9, 14, 30)   // a Thursday

private func history(_ events: [UsageEvent], span: Int = 30) -> UsageHistory {
    UsageHistory.make(from: events, now: now, calendar: cal, span: span)
}

// MARK: - Days

@Test func theGridRunsToTodayAndNoFurther() {
    let h = history([])
    #expect(h.days.count == 30)
    #expect(h.days.last?.start == cal.startOfDay(for: now))
    #expect(h.days.first?.start == at(2026, 6, 10, 0, 0))
    // Every day in between is present, in order, one apart.
    for (earlier, later) in zip(h.days, h.days.dropFirst()) {
        #expect(cal.date(byAdding: .day, value: 1, to: earlier.start) == later.start)
    }
}

@Test func aDayIsTheLocalDayNotTheUTCOne() {
    // 23:30 in New York is already tomorrow in UTC. The cell has to be the day
    // the person lived, or the grid disagrees with the calendar on their wall.
    let h = history([event(at(2026, 7, 8, 23, 30))])
    let late = h.days.first { $0.start == at(2026, 7, 8, 0, 0) }
    #expect(late?.totals.input == 1_000)
    #expect(h.days.first { $0.start == at(2026, 7, 9, 0, 0) }?.totals.total == 0)
}

@Test func usageOlderThanTheGridIsLeftOutRatherThanFoldedIntoTheOldestDay() {
    let h = history([event(at(2026, 5, 1, 12, 0)), event(at(2026, 7, 9, 9, 0))])
    #expect(h.totals.input == 1_000)
    #expect(h.activeDays == 1)
}

@Test func anEmptyHistoryStillDrawsEveryDay() {
    let h = history([])
    #expect(h.days.count == 30)
    #expect(h.isEmpty)
    #expect(h.activeDays == 0)
    #expect(h.totals.total == 0)
    #expect(h.cost.amount == 0)
}

@Test func aDayCostsWhatTheChartSaysTheSameDayCost() {
    // One pricing path, so the grid's dollars and the trend chart's dollars
    // cannot drift apart.
    let events = [event(at(2026, 7, 8, 9, 0), input: 40_000),
                  event(at(2026, 7, 8, 10, 0), input: 10_000, model: "claude-sonnet-4-8")]
    let day = history(events).days.first { $0.start == at(2026, 7, 8, 0, 0) }
    let bucket = UsageBreakdown.make(from: events, now: now, calendar: cal, range: .week)
        .buckets.first { $0.start == at(2026, 7, 8, 0, 0) }
    #expect(day?.cost.amount == bucket?.cost.amount)
    #expect((day?.cost.amount ?? 0) > 0)
}

@Test func anUnpricedModelMakesTheWholeHistoryALowerBound() {
    let h = history([event(at(2026, 7, 8, 9, 0), model: "claude-unknown-9")])
    #expect(!h.cost.isComplete)
    #expect(h.cost.unpricedModels == ["claude-unknown-9"])
}

// MARK: - Columns

@Test func theFirstColumnIsPaddedSoEveryCellSitsOnItsOwnWeekday() {
    // Jun 10 2026 is a Wednesday: row 3 of a Sunday-first week, so the first
    // column opens with three blanks rather than starting at the top.
    let columns = ActivityGrid.weeks(of: history([]).days, calendar: cal)
    #expect(columns.first?.prefix(3).allSatisfy { $0 == nil } == true)
    #expect(columns.first?[3]?.start == at(2026, 6, 10, 0, 0))
    #expect(columns.allSatisfy { $0.count == 7 })
    #expect(columns.flatMap { $0 }.compactMap { $0 }.count == 30)
}

@Test func theLastColumnStopsOnTodayInsteadOfDrawingTheRestOfTheWeek() {
    let columns = ActivityGrid.weeks(of: history([]).days, calendar: cal)
    let last = columns.last!
    // Thursday is row 4 with a Sunday-first week; Friday and Saturday are blank.
    #expect(last[4]?.start == cal.startOfDay(for: now))
    #expect(last[5] == nil)
    #expect(last[6] == nil)
}

@Test func everyCellLandsOnTheWeekdayItsDateActuallyFell() {
    let columns = ActivityGrid.weeks(of: history([], span: 90).days, calendar: cal)
    for (index, column) in columns.enumerated() {
        for (row, day) in column.enumerated() {
            guard let day else { continue }
            #expect(ActivityGrid.row(of: day.start, calendar: cal) == row)
            _ = index
        }
    }
}

@Test func aWeekStartingMondayShiftsEveryRowRatherThanRelabellingThem() {
    var monday = cal
    monday.firstWeekday = 2
    // Jun 10 is a Wednesday: row 3 of a Sunday week, row 2 of a Monday week.
    #expect(ActivityGrid.row(of: at(2026, 6, 10), calendar: cal) == 3)
    #expect(ActivityGrid.row(of: at(2026, 6, 10), calendar: monday) == 2)
}

// MARK: - Ink

@Test func aDayWithNothingOnItGetsNoInkAndTheBusiestDayGetsAllOfIt() {
    #expect(HeatScale.level(0, peak: 1_000) == 0)
    #expect(HeatScale.level(1_000, peak: 1_000) == HeatScale.steps)
    // A history with a single active day: that day is the peak, so it is darkest
    // rather than palest — a quartile ranking would call it the bottom quartile.
    #expect(HeatScale.level(5, peak: 5) == HeatScale.steps)
}

@Test func nothingAtAllIsNeverDividedBy() {
    #expect(HeatScale.level(0, peak: 0) == 0)
    #expect(HeatScale.level(10, peak: 0) == 0)
}

@Test func theRampNeverGoesBackwardsAndStaysInsideItsSteps() {
    var last = 0
    for value in stride(from: 0.0, through: 1_000.0, by: 5) {
        let level = HeatScale.level(value, peak: 1_000)
        #expect(level >= last)
        #expect(level <= HeatScale.steps)
        last = level
    }
}

@Test func ordinaryDaysAreToldApartUnderneathAnOutlier() {
    // The failure this guards: one 10× day flattening every ordinary day onto the
    // palest step, which is the same picture as "nothing happened all month".
    let peak = 100_000.0
    #expect(HeatScale.level(5_000, peak: peak) > 0)
    #expect(HeatScale.level(20_000, peak: peak) > HeatScale.level(5_000, peak: peak))
    #expect(HeatScale.level(60_000, peak: peak) > HeatScale.level(20_000, peak: peak))
}
