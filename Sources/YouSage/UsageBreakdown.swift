import Foundation

/// One assistant turn, as `TokenTracker` saw it. Flat and Sendable so the
/// bucketing below can be a pure function tested without an actor or a disk.
struct UsageEvent: Sendable, Equatable {
    let date: Date
    let model: String
    let totals: TokenTotals
}

/// The colour-bearing identity of a model. Versions fold together: Opus 4.7 and
/// Opus 4.8 are one segment in the trend chart, because two segments of identical
/// terracotta would be a stripe you cannot read. They price identically, and the
/// cost list keeps both versions as separate rows.
enum ModelFamily: String, Sendable, Equatable, CaseIterable {
    case opus, sonnet, haiku, fable, other

    var displayName: String {
        switch self {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .fable:  return "Fable"
        case .other:  return "Other"
        }
    }

    /// Resolved through the same normalization and anchored family match that
    /// pricing uses, so a model is coloured exactly as it is priced.
    /// `claude-3-opus` is a past generation that priced differently — it is
    /// `.other`, not `.opus`. `claude-mythos-5` prices like Fable but is not
    /// Fable, so it is `.other` too.
    init(modelID: String) {
        let id = Pricing.normalize(modelID)
        if Pricing.isFamily("opus", of: id)        { self = .opus }
        else if Pricing.isFamily("sonnet", of: id) { self = .sonnet }
        else if Pricing.isFamily("haiku", of: id)  { self = .haiku }
        else if Pricing.isFamily("fable", of: id)  { self = .fable }
        else                                       { self = .other }
    }
}

/// Declaration order is display order: largest bucket first, as Claude Code's
/// token mix actually falls.
enum TokenKind: String, Sendable, CaseIterable {
    case cacheRead, cacheWrite, output, input

    var displayName: String {
        switch self {
        case .cacheRead:  return "cache read"
        case .cacheWrite: return "cache write"
        case .output:     return "output"
        case .input:      return "input"
        }
    }

    func count(in totals: TokenTotals) -> Int {
        switch self {
        case .cacheRead:  return totals.cacheRead
        case .cacheWrite: return totals.cacheCreation
        case .output:     return totals.output
        case .input:      return totals.input
        }
    }
}

struct FamilyTokens: Sendable, Equatable, Identifiable {
    let family: ModelFamily
    let totals: TokenTotals
    /// What this family's slice of the day would have cost at list prices. Held
    /// per family rather than derived from `totals`, because the rate depends on
    /// which models are inside the family — Opus 4.8 and a future Opus need not
    /// price alike.
    let cost: CostEstimate
    var id: ModelFamily { family }
}

/// One bucket of the drawn window: a calendar day for the multi-day ranges, an
/// hour for `.today`. The unit lives on the breakdown rather than in here, so a
/// bucket never has to be asked what it is to be summed or plotted.
struct UsageBucket: Sendable, Equatable, Identifiable {
    /// Local start of the bucket — midnight for a day, the top of the hour for
    /// an hour.
    let start: Date
    /// The bucket the clock is still inside, so it is still accruing; the chart
    /// draws it at reduced opacity.
    let isCurrent: Bool
    /// Only families active in the bucket, in `ModelFamily.allCases` order.
    let byFamily: [FamilyTokens]
    let totals: TokenTotals
    let cost: CostEstimate
    var id: Date { start }

    /// Tokens this family used in the bucket, zero when it sat idle. The chart
    /// plots this for every family × bucket so each series is a continuous line;
    /// the table keeps its own lookup because it distinguishes "—" from 0.
    func total(of family: ModelFamily) -> Int {
        byFamily.first { $0.family == family }?.totals.total ?? 0
    }

    /// The same slice in dollars, for the chart's cost metric. Zero in an idle
    /// bucket, exactly as `total(of:)` is.
    func cost(of family: ModelFamily) -> Double {
        byFamily.first { $0.family == family }?.cost.amount ?? 0
    }
}

struct ModelCost: Sendable, Equatable, Identifiable {
    /// Raw id, e.g. `claude-opus-4-8`.
    let model: String
    /// `Opus 4.8` — versions stay distinct here even though the chart folds them.
    let displayName: String
    let family: ModelFamily
    let totals: TokenTotals
    let cost: CostEstimate
    var id: String { model }
}

struct KindTotal: Sendable, Equatable, Identifiable {
    let kind: TokenKind
    let count: Int
    var id: TokenKind { kind }
}

/// The width of one bucket the window draws. Anything longer than a day is drawn
/// a day at a time; today is drawn an hour at a time, because a single day plotted
/// as a single point is not a trend.
enum BucketUnit: Sendable, Equatable {
    case day, hour
}

/// How far back the details window looks. Raw value is the day count, so the
/// label and the arithmetic never drift apart.
enum UsageRange: Int, Sendable, CaseIterable, Identifiable {
    case today = 1, week = 7, month = 30, quarter = 90

    var days: Int { rawValue }

    /// "Today", not "1D": a one-day label has to say whether it means the calendar
    /// day or a rolling 24 hours, and this one is the calendar day — midnight to
    /// midnight, in the machine's own zone.
    var label: String { self == .today ? "Today" : "\(rawValue)D" }

    var unit: BucketUnit { self == .today ? .hour : .day }

    var id: Int { rawValue }
}

/// The equal-length window immediately before the current one, for the trend
/// chips. Every field is a total: the previous period is never charted, only
/// compared against.
struct PeriodTotals: Sendable, Equatable {
    let totals: TokenTotals
    let cost: CostEstimate
    /// nil when the window sent nothing to a model, matching `cacheHitRate`.
    let cacheHitRate: Double?
}

/// Where this calendar month is heading at the rate it has been going.
///
/// Deliberately a calendar month rather than the selected range: a projection is
/// only meaningful against the period it projects onto, and a bill is monthly.
struct MonthProjection: Sendable, Equatable {
    /// Dollars spent since the first of the month.
    let spendToDate: Double
    /// `spendToDate` extrapolated over the whole month at the current rate.
    let projected: Double
    /// Last calendar month's total. nil when it held no activity — which,
    /// this far back, is indistinguishable from never having scanned it.
    let previousCost: Double?
    /// "June" — named, because "vs. previous month" reads like a chart axis.
    let previousName: String

    /// Fraction change of the projection against last month, or nil when there
    /// is nothing to compare with.
    var projectedChange: Double? {
        guard let previousCost, previousCost > 0 else { return nil }
        return (projected - previousCost) / previousCost
    }
}

/// A range of usage, sliced three ways, plus the comparisons the dashboard's
/// chips need. A tuple would be lighter than `KindTotal`, but tuples do not
/// synthesize `Equatable` and SwiftUI needs that.
struct UsageBreakdown: Sendable, Equatable {
    /// Oldest first, zero-filled. One per calendar day for the multi-day ranges;
    /// one per elapsed hour of today for `.today`.
    let buckets: [UsageBucket]
    /// Cost descending, then tokens descending, then name — so the order is total.
    let models: [ModelCost]
    /// Always four, in declaration order.
    let kinds: [KindTotal]
    let totals: TokenTotals
    let cost: CostEstimate
    let range: UsageRange
    /// nil when the preceding window was idle. A change from zero is not a
    /// percentage, so the chips must be able to say nothing at all.
    let previous: PeriodTotals?
    let month: MonthProjection
    let generatedAt: Date

    /// Cache reads as a share of everything sent *to* the model. Output tokens are
    /// generated, never read from a cache, so they are not in the denominator.
    /// nil when nothing was sent.
    var cacheHitRate: Double? { Self.cacheHitRate(of: totals) }

    var tokenChange: Double? {
        Self.change(Double(totals.total), from: previous.map { Double($0.totals.total) })
    }
    var costChange: Double? {
        Self.change(cost.amount, from: previous?.cost.amount)
    }
    var messageChange: Double? {
        Self.change(Double(totals.messages), from: previous.map { Double($0.totals.messages) })
    }
    var cacheHitRateChange: Double? {
        Self.change(cacheHitRate, from: previous?.cacheHitRate)
    }

    /// Dollars per message, or nil when the window has no messages to divide by.
    var costPerMessage: Double? {
        totals.messages > 0 ? cost.amount / Double(totals.messages) : nil
    }

    /// Messages per day, averaged across the whole range including idle days —
    /// the range is the window the user chose, so it is the window we average over.
    /// Divided by the range's *days*, never by its buckets: an hourly range would
    /// otherwise report messages per hour under a "per day" label.
    var messagesPerDay: Int {
        Int((Double(totals.messages) / Double(max(range.days, 1))).rounded())
    }

    static func cacheHitRate(of totals: TokenTotals) -> Double? {
        let sent = totals.input + totals.cacheCreation + totals.cacheRead
        guard sent > 0 else { return nil }
        return Double(totals.cacheRead) / Double(sent)
    }

    private static func change(_ current: Double?, from previous: Double?) -> Double? {
        guard let current, let previous, previous > 0 else { return nil }
        return (current - previous) / previous
    }
}

extension UsageBreakdown {
    /// The window `range` describes, bucketed by `range.unit`: the last
    /// `range.days` calendar days, or today's elapsed hours.
    ///
    /// Pure: everything the window draws is decided here, so it can be tested with
    /// synthetic events instead of transcript fixtures. Bucketing goes through
    /// `Calendar`, so a 23-hour spring-forward day and a 25-hour fall-back day
    /// both land where a human would put them — and the hourly range simply has
    /// one bucket fewer or more on those two days.
    static func make(from events: [UsageEvent],
                     now: Date,
                     calendar: Calendar,
                     range: UsageRange = .week) -> UsageBreakdown {
        let bucketStarts = bucketStarts(for: range, now: now, calendar: calendar)
        let spanStart = bucketStarts[0]
        // The end of the last bucket, not the end of the day: for `.today` the
        // hours still to come are not part of the window, because they hold
        // nothing and drawing them as zero would read as a collapse in usage.
        let spanEnd = calendar.date(byAdding: range.unit == .hour ? .hour : .day,
                                    value: 1, to: bucketStarts.last ?? spanStart) ?? now

        // Bucket once; every slice below reads from these two maps.
        var perBucketModel: [Date: [String: TokenTotals]] = [:]
        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= spanStart && e.date < spanEnd {
            let bucket = bucketStart(of: e.date, unit: range.unit, calendar: calendar)
            var models = perBucketModel[bucket] ?? [:]
            models[e.model] = (models[e.model] ?? TokenTotals()) + e.totals
            perBucketModel[bucket] = models
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }

        let buckets: [UsageBucket] = bucketStarts.map { day in
            let models = perBucketModel[day] ?? [:]

            // Grouped by family but kept per model, so each family's dollars go
            // through the same `estimate` the day and the window use — one
            // pricing path, so the family lines can never sum to something other
            // than the day's total.
            var byFamilyMap: [ModelFamily: [String: TokenTotals]] = [:]
            for (id, totals) in models {
                let family = ModelFamily(modelID: id)
                var inFamily = byFamilyMap[family] ?? [:]
                inFamily[id] = (inFamily[id] ?? TokenTotals()) + totals
                byFamilyMap[family] = inFamily
            }
            let byFamily = ModelFamily.allCases.compactMap { family -> FamilyTokens? in
                guard let inFamily = byFamilyMap[family] else { return nil }
                let totals = inFamily.values.reduce(TokenTotals()) { $0 + $1 }
                guard !totals.isEmpty else { return nil }
                return FamilyTokens(family: family,
                                    totals: totals,
                                    cost: estimate(over: inFamily))
            }

            // The last bucket is the one the clock is inside, in both units.
            return UsageBucket(start: day,
                               isCurrent: day == bucketStarts.last,
                               byFamily: byFamily,
                               totals: byFamily.reduce(TokenTotals()) { $0 + $1.totals },
                               cost: estimate(over: models))
        }

        let models: [ModelCost] = perModel.map { id, totals in
            ModelCost(model: id,
                      displayName: modelDisplayName(id),
                      family: ModelFamily(modelID: id),
                      totals: totals,
                      cost: estimate(over: [id: totals]))
        }
        .sorted {
            if $0.cost.amount != $1.cost.amount { return $0.cost.amount > $1.cost.amount }
            if $0.totals.total != $1.totals.total { return $0.totals.total > $1.totals.total }
            return $0.displayName < $1.displayName
        }

        let totals = models.reduce(TokenTotals()) { $0 + $1.totals }
        let kinds = TokenKind.allCases.map { KindTotal(kind: $0, count: $0.count(in: totals)) }

        return UsageBreakdown(buckets: buckets,
                              models: models,
                              kinds: kinds,
                              totals: totals,
                              cost: estimate(over: perModel),
                              range: range,
                              previous: previousPeriod(in: events, before: spanStart,
                                                       now: now, range: range, calendar: calendar),
                              month: projectMonth(from: events, now: now, calendar: calendar),
                              generatedAt: now)
    }

    /// The comparable window before the drawn one. Returns nil when it is empty,
    /// so a chip never divides by zero and never claims an infinite rise off a
    /// period we may simply never have scanned.
    ///
    /// For the daily ranges that is the equal-length window ending where the drawn
    /// one begins. For `.today` it is yesterday up to this time of day, not all of
    /// yesterday: a morning's usage measured against a whole finished day would
    /// show a fall in usage every single morning.
    private static func previousPeriod(in events: [UsageEvent],
                                       before spanStart: Date,
                                       now: Date,
                                       range: UsageRange,
                                       calendar: Calendar) -> PeriodTotals? {
        let start: Date?
        let end: Date
        switch range.unit {
        case .day:
            start = calendar.date(byAdding: .day, value: -range.days, to: spanStart)
            end = spanStart
        case .hour:
            start = calendar.date(byAdding: .day, value: -1, to: spanStart)
            // Elapsed seconds rather than a wall-clock time, so on a DST day the
            // two windows are the same length rather than the same clock reading.
            end = (start ?? spanStart).addingTimeInterval(now.timeIntervalSince(spanStart))
        }
        guard let start else { return nil }

        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= start && e.date < end {
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }
        guard !perModel.isEmpty else { return nil }

        let totals = perModel.values.reduce(TokenTotals()) { $0 + $1 }
        return PeriodTotals(totals: totals,
                            cost: estimate(over: perModel),
                            cacheHitRate: cacheHitRate(of: totals))
    }

    /// Every bucket the window draws, oldest first. Never empty: a range is at
    /// least one day, and a day is at least its first hour.
    private static func bucketStarts(for range: UsageRange,
                                     now: Date,
                                     calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch range.unit {
        case .day:
            let starts = (0..<range.days).reversed().compactMap {
                calendar.date(byAdding: .day, value: -$0, to: today)
            }
            return starts.isEmpty ? [today] : starts
        case .hour:
            // Walked with the calendar rather than strided by 3600 seconds, so the
            // day that skips an hour has one bucket fewer and the day that repeats
            // one has an extra, exactly as those days were lived.
            let current = bucketStart(of: now, unit: .hour, calendar: calendar)
            var starts: [Date] = []
            var cursor = today
            while cursor <= current {
                starts.append(cursor)
                guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor),
                      next > cursor else { break }
                cursor = next
            }
            return starts.isEmpty ? [today] : starts
        }
    }

    /// The bucket an event belongs to. The one place a date becomes a bucket key,
    /// so the buckets drawn and the events counted can never disagree.
    private static func bucketStart(of date: Date,
                                    unit: BucketUnit,
                                    calendar: Calendar) -> Date {
        switch unit {
        case .day:  return calendar.startOfDay(for: date)
        case .hour: return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        }
    }

    /// Spend so far this calendar month, extrapolated to its end at the same rate.
    ///
    /// The elapsed fraction is measured in seconds rather than days, so the figure
    /// climbs smoothly through the day instead of stepping at midnight — and so a
    /// 23- or 25-hour DST day scales by what it actually was.
    private static func projectMonth(from events: [UsageEvent],
                                     now: Date,
                                     calendar: Calendar) -> MonthProjection {
        let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now))
            ?? calendar.startOfDay(for: now)
        let monthEnd = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? now
        let previousStart = calendar.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart

        var thisMonth: [String: TokenTotals] = [:]
        var lastMonth: [String: TokenTotals] = [:]
        for e in events {
            if e.date >= monthStart && e.date < monthEnd {
                thisMonth[e.model] = (thisMonth[e.model] ?? TokenTotals()) + e.totals
            } else if e.date >= previousStart && e.date < monthStart {
                lastMonth[e.model] = (lastMonth[e.model] ?? TokenTotals()) + e.totals
            }
        }

        let spendToDate = estimate(over: thisMonth).amount
        let elapsed = now.timeIntervalSince(monthStart)
        let whole = monthEnd.timeIntervalSince(monthStart)
        // Guard the first instant of the month, where the rate is 0/0.
        let fraction = whole > 0 ? max(elapsed / whole, 1e-6) : 1

        let previousName = monthName(previousStart, calendar: calendar)
        return MonthProjection(spendToDate: spendToDate,
                               projected: spendToDate / fraction,
                               previousCost: lastMonth.isEmpty ? nil : estimate(over: lastMonth).amount,
                               previousName: previousName)
    }

    private static func monthName(_ date: Date, calendar: Calendar) -> String {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = .autoupdatingCurrent
        f.setLocalizedDateFormatFromTemplate("MMMM")
        return f.string(from: date)
    }

    /// Prices a model→totals map. A model the rate table cannot price contributes
    /// zero dollars and its id, so the figure renders as a lower bound rather than
    /// a confidently low number.
    private static func estimate(over models: [String: TokenTotals]) -> CostEstimate {
        var result = CostEstimate()
        var unpriced: Set<String> = []
        for (id, totals) in models {
            if let dollars = Pricing.cost(totals, model: id) {
                result.amount += dollars
            } else {
                unpriced.insert(id)
            }
        }
        result.unpricedModels = unpriced.sorted()
        return result
    }
}
