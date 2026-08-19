import Foundation
import Testing
@testable import YouSage

/// Fixed zone, because the export writes local timestamps and a test must not
/// depend on where the machine sits.
private let newYork = TimeZone(identifier: "America/New_York")!

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = newYork
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ date: Date, _ model: String = "claude-opus-4-8", input: Int = 1_000) -> UsageEvent {
    UsageEvent(date: date, model: model, totals: TokenTotals(input: input, messages: 1))
}

private func rows(_ csv: String) -> [[String]] {
    csv.split(separator: "\n").map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
}

@Test func aDailyExportNamesItsFirstColumnDay() {
    let b = UsageBreakdown.make(from: [event(at(2026, 7, 9))], now: at(2026, 7, 9), calendar: cal)
    #expect(rows(UsageExport.csv(b, timeZone: newYork))[0].first == "Day")
}

@Test func anHourlyExportNamesItsFirstColumnHour() {
    let b = UsageBreakdown.make(from: [event(at(2026, 7, 9, 14, 5))],
                                now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(rows(UsageExport.csv(b, timeZone: newYork))[0].first == "Hour")
}

@Test func hourlyRowsCarryTheLocalHourNotUTC() {
    let b = UsageBreakdown.make(from: [event(at(2026, 7, 9, 14, 5))],
                                now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    let exported = rows(UsageExport.csv(b, timeZone: newYork))
    #expect(exported[1].first == "2026-07-09 00:00:00")   // first bucket: local midnight
    #expect(exported.last?.first == "2026-07-09 14:00:00")
}

@Test func dailyRowsCarryTheLocalCalendarDay() {
    // The buckets are local midnights; formatted in UTC, a zone east of Greenwich
    // would export every one of them as the day before.
    let berlin = TimeZone(identifier: "Europe/Berlin")!
    var berlinCal = Calendar(identifier: .gregorian)
    berlinCal.timeZone = berlin
    let b = UsageBreakdown.make(from: [], now: berlinCal.date(from: DateComponents(year: 2026, month: 7, day: 9, hour: 12))!,
                                calendar: berlinCal)
    let exported = rows(UsageExport.csv(b, timeZone: berlin))
    #expect(exported.last?.first == "2026-07-09")
}

@Test func theFilenameCarriesTheRangeLabel() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(UsageExport.filename(b).hasPrefix("YouSage Today "))
}

@Test func theFilenameCarriesTheDrawnWindowNotTheDayItWasExported() {
    // A file named for today holding last week's rows is a file you cannot find
    // again once a few of them are sitting in ~/Downloads.
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal,
                                range: .week, offset: 1)
    #expect(UsageExport.filename(b, timeZone: newYork) == "YouSage Week 2026-07-04.csv")
}

@Test func theFilenameOfThePresentWindowIsDatedToTheLastDayItHolds() {
    // The week runs to Saturday, but a file named for a Saturday that has not
    // happened is a file dated in the future.
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal, range: .week)
    #expect(UsageExport.filename(b, timeZone: newYork) == "YouSage Week 2026-07-09.csv")
}

@Test func anExportStopsAtTheLastRowThatHasBeenLived() {
    // Rows of zeros for hours that have not happened are not data.
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9, 14, 30), calendar: cal, range: .today)
    #expect(rows(UsageExport.csv(b, timeZone: newYork)).count == 16)   // header + 15 hours
}
