import Foundation

/// One assistant turn, as `TokenTracker` saw it. Flat and Sendable so the
/// bucketing below can be a pure function tested without an actor or a disk.
struct UsageEvent: Sendable, Equatable {
    let date: Date
    let model: String
    let totals: TokenTotals
    /// nil for this Mac's own transcripts, else the remote source's id.
    var source: String? = nil
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
    /// The bucket has not begun. A day is always drawn midnight to midnight and a
    /// week always first weekday to last, so the window carries hours and days
    /// that have not happened — and an hour that cannot yet hold anything is not
    /// an hour of zero usage. The chart keeps them on the axis and off the line.
    let isFuture: Bool
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

/// One machine's share of a window: this Mac, or a remote source.
struct SourceCost: Sendable, Equatable, Identifiable {
    /// "local" for this Mac, else the remote source's id — as `SourceTokens`.
    let id: String
    let name: String
    let isLocal: Bool
    let totals: TokenTotals
    let cost: CostEstimate
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

    /// "Today" and "Week" name calendar periods, because that is what they draw:
    /// midnight to midnight, and first weekday to last, in the machine's own zone
    /// and week. "7D" would promise a rolling window, which is what the longer
    /// two ranges actually are.
    var label: String {
        switch self {
        case .today: return "Today"
        case .week:  return "Week"
        default:     return "\(rawValue)D"
        }
    }

    /// Whether the window snaps to a calendar period rather than ending on today.
    /// The two short ranges do; a "30D" that quietly became a calendar month
    /// would be a different thing under the same label.
    var isCalendarAligned: Bool { self == .today || self == .week }

    var unit: BucketUnit { self == .today ? .hour : .day }

    /// What one step of the paging buttons moves by, named for a tooltip: "the
    /// previous week" rather than "the previous 7D", which is a label, not a noun.
    var stepName: String {
        switch self {
        case .today: return "day"
        case .week:  return "week"
        default:     return "\(days) days"
        }
    }

    /// What the period before this one is called, for the onion skin's key and
    /// its tooltip row. "Previous 7 days" would be wrong for the two calendar
    /// ranges — last week is a week with a name, not a rolling seven days.
    var previousName: String {
        switch self {
        case .today: return "Yesterday"
        case .week:  return "Last week"
        default:     return "Previous \(days) days"
        }
    }

    /// Whole periods of history behind the current window that the transcripts
    /// can still answer for. `TokenTracker` retains a day more than this, so the
    /// oldest bucket of the oldest window is always whole.
    static let historyDays = 180

    /// How many periods the window may be paged back. A range longer than the
    /// history keeps this at zero rather than offering a step into nothing.
    var maxOffset: Int { max(0, Self.historyDays / days - 1) }

    var id: Int { rawValue }
}

/// The equal-length window immediately before the current one: the figures the
/// trend chips compare against, and the shape the chart draws behind the current
/// period as an onion skin.
struct PeriodTotals: Sendable, Equatable {
    /// Deliberately only as far as the current window has lived — half a week
    /// against a whole one would invent a collapse in usage every Sunday. The
    /// chips read this.
    let totals: TokenTotals
    let cost: CostEstimate
    /// nil when the window sent nothing to a model, matching `cacheHitRate`.
    let cacheHitRate: Double?
    /// The *whole* previous window, bucketed exactly as the drawn one is and
    /// aligned to it index for index — bucket i here is the same hour of
    /// yesterday, or the same weekday of last week, as bucket i there.
    ///
    /// Unlike `totals` this is not truncated to what has been lived: at 2pm the
    /// onion skin should carry on past the current line to where yesterday
    /// actually finished, because that is the comparison a reader is making when
    /// they look at a half-drawn day.
    let buckets: [UsageBucket]
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
    /// How many whole periods back the drawn window sits; 0 is the one the clock
    /// is inside. Held here so the window can label what it drew without
    /// recomputing the span.
    let offset: Int
    /// nil when the preceding window was idle. A change from zero is not a
    /// percentage, so the chips must be able to say nothing at all.
    let previous: PeriodTotals?
    let month: MonthProjection
    let generatedAt: Date
    /// This Mac, then each remote source by name, over the same span. Empty
    /// when no remote source is attached, so a lone Mac shows no split.
    var sources: [SourceCost] = []

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

    /// The buckets that have begun, oldest first — everything drawn as a line, a
    /// row, or a total. `buckets` additionally carries what the axis spans.
    var lived: [UsageBucket] { buckets.filter { !$0.isFuture } }

    /// Days of the window that have begun. A week still running has lived fewer
    /// than seven, and averaging over the days it has not yet reached would report
    /// a fall in usage every Sunday.
    var daysElapsed: Int {
        switch range.unit {
        // An hourly window is one day however much of it has elapsed — dividing by
        // its hours would report messages per hour under a "per day" label.
        case .hour: return 1
        case .day:  return max(1, lived.count)
        }
    }

    /// Messages per day, averaged across the days the window has lived, idle ones
    /// included — an idle Tuesday is a day you used nothing, and it belongs in the
    /// average; a Friday that has not arrived does not.
    var messagesPerDay: Int {
        Int((Double(totals.messages) / Double(max(daysElapsed, 1))).rounded())
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
                     range: UsageRange = .week,
                     offset: Int = 0,
                     sourceNames: [String: String] = [:]) -> UsageBreakdown {
        let offset = max(0, offset)
        let bucketStarts = bucketStarts(for: range, now: now, calendar: calendar, offset: offset)
        let spanStart = bucketStarts[0]
        // The end of the last bucket, not the end of the day: for `.today` the
        // hours still to come are not part of the window, because they hold
        // nothing and drawing them as zero would read as a collapse in usage.
        let spanEnd = calendar.date(byAdding: range.unit == .hour ? .hour : .day,
                                    value: 1, to: bucketStarts.last ?? spanStart) ?? now

        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= spanStart && e.date < spanEnd {
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }

        // The bucket the clock is inside, named once so every bucket can be asked
        // whether it is that one. Outside the present window it matches nothing.
        let currentStart = offset == 0 ? bucketStart(of: now, unit: range.unit, calendar: calendar) : nil

        let buckets = buckets(over: bucketStarts, from: events, unit: range.unit,
                              calendar: calendar, now: now, currentStart: currentStart)

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
                              offset: offset,
                              previous: previousPeriod(in: events, over: bucketStarts,
                                                       now: now, range: range, offset: offset,
                                                       calendar: calendar),
                              month: projectMonth(from: events, now: now, calendar: calendar),
                              generatedAt: now,
                              sources: sources(in: events, from: spanStart, to: spanEnd,
                                               names: sourceNames))
    }

    /// This Mac first, then each remote source in `names` (id → name) by name —
    /// the popover's order. Every attached source gets a row, idle or not.
    private static func sources(in events: [UsageEvent],
                                from start: Date,
                                to end: Date,
                                names: [String: String]) -> [SourceCost] {
        guard !names.isEmpty else { return [] }
        var perSource: [String?: [String: TokenTotals]] = [:]
        for e in events where e.date >= start && e.date < end {
            var models = perSource[e.source] ?? [:]
            models[e.model] = (models[e.model] ?? TokenTotals()) + e.totals
            perSource[e.source] = models
        }
        func row(_ source: String?, name: String) -> SourceCost {
            let models = perSource[source] ?? [:]
            return SourceCost(id: source ?? "local",
                              name: name,
                              isLocal: source == nil,
                              totals: models.values.reduce(TokenTotals()) { $0 + $1 },
                              cost: estimate(over: models))
        }
        let remotes = names.sorted {
            $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
        }
        return [row(nil, name: "This Mac")] + remotes.map { row($0.key, name: $0.value) }
    }

    /// Every bucket of a window, oldest first, zero-filled — the one place events
    /// become buckets. The drawn window and the onion skin behind it both come
    /// through here, so the two can never be bucketed by different rules.
    private static func buckets(over starts: [Date],
                                from events: [UsageEvent],
                                unit: BucketUnit,
                                calendar: Calendar,
                                now: Date,
                                currentStart: Date?) -> [UsageBucket] {
        guard let spanStart = starts.first, let spanLast = starts.last else { return [] }
        // The end of the last bucket, not the end of the day: for `.today` the
        // hours still to come are not part of the window, because they hold
        // nothing and drawing them as zero would read as a collapse in usage.
        let spanEnd = calendar.date(byAdding: unit == .hour ? .hour : .day,
                                    value: 1, to: spanLast) ?? spanLast

        var perBucketModel = [[String: TokenTotals]](repeating: [:], count: starts.count)
        for e in events where e.date >= spanStart && e.date < spanEnd {
            let bucket = bucketIndex(of: e.date, in: starts)
            perBucketModel[bucket][e.model] = (perBucketModel[bucket][e.model] ?? TokenTotals()) + e.totals
        }

        return starts.enumerated().map { index, start in
            let models = perBucketModel[index]

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

            // Not the last bucket: a day is drawn to midnight and a week to
            // Saturday, so the bucket the clock is inside is usually somewhere in
            // the middle. Nothing in a finished window is still accruing, and
            // nothing in the previous window is either — it is handed no current
            // bucket at all.
            return UsageBucket(start: start,
                               isCurrent: start == currentStart,
                               isFuture: start > now,
                               byFamily: byFamily,
                               totals: byFamily.reduce(TokenTotals()) { $0 + $1.totals },
                               cost: estimate(over: models))
        }
    }

    /// The comparable window before the drawn one. Returns nil when the whole of
    /// it is empty, so the onion skin is absent rather than flat at zero, which
    /// would read as "you used nothing last week" when the truth is "there is no
    /// last week on this disk".
    ///
    /// For the daily ranges that is the equal-length window ending where the drawn
    /// one begins. For `.today` it is yesterday up to this time of day, not all of
    /// yesterday: a morning's usage measured against a whole finished day would
    /// show a fall in usage every single morning. Its *buckets* are the whole of
    /// yesterday all the same — see `PeriodTotals.buckets`. The two can disagree:
    /// at 9am with nothing run before 9am yesterday, `totals` is zero while the
    /// buckets hold yesterday's afternoon. The chips read zero as "nothing to
    /// compare against" — a change from zero is not a percentage — but the
    /// overlay still has a shape to draw, and drawing it is its whole point.
    private static func previousPeriod(in events: [UsageEvent],
                                       over currentStarts: [Date],
                                       now: Date,
                                       range: UsageRange,
                                       offset: Int,
                                       calendar: Calendar) -> PeriodTotals? {
        let days = range.unit == .hour ? 1 : range.days
        guard let spanStart = currentStarts.first,
              let start = calendar.date(byAdding: .day, value: -days, to: spanStart) else {
            return nil
        }
        // A finished window is compared against the whole window before it. One
        // still running is compared only as far into that window as the clock has
        // gone — half a week against a whole one would invent a collapse in usage
        // every Sunday. Measured in elapsed seconds rather than a wall-clock
        // reading, so a DST week compares two windows of the same length.
        let end = offset == 0
            ? start.addingTimeInterval(now.timeIntervalSince(spanStart))
            : spanStart

        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= start && e.date < end {
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }

        // Shifted a whole period, bucket by bucket, so index i of the onion skin
        // is the same hour of yesterday — or the same weekday of last week — as
        // index i of the drawn window. Walked through the calendar rather than by
        // seconds, so the comparison survives a DST boundary between the two.
        let shifted = currentStarts.compactMap {
            calendar.date(byAdding: .day, value: -days, to: $0)
        }
        // A shift the calendar could not answer for would misalign every later
        // bucket, which is worse than drawing nothing.
        let aligned = shifted.count == currentStarts.count
            ? buckets(over: shifted, from: events, unit: range.unit,
                      calendar: calendar, now: now, currentStart: nil)
            : []

        // Judged on the whole period, not the slice the chips read: a quiet
        // morning must not erase the afternoon that followed it.
        guard !perModel.isEmpty || aligned.contains(where: { $0.totals.total > 0 }) else {
            return nil
        }

        let totals = perModel.values.reduce(TokenTotals()) { $0 + $1 }
        return PeriodTotals(totals: totals,
                            cost: estimate(over: perModel),
                            cacheHitRate: cacheHitRate(of: totals),
                            buckets: aligned)
    }

    /// Every bucket the window draws, oldest first. Never empty: a range is at
    /// least one day, and a day is at least its first hour.
    private static func bucketStarts(for range: UsageRange,
                                     now: Date,
                                     calendar: Calendar,
                                     offset: Int) -> [Date] {
        let today = calendar.startOfDay(for: now)
        switch range {
        case .today:
            // Midnight to midnight, always — the axis reads the same at breakfast
            // as at bedtime, and the hours not yet lived are marked rather than
            // dropped. Walked with the calendar rather than strided by 3600
            // seconds, so the day that skips an hour has one bucket fewer and the
            // day that repeats one has an extra, exactly as those days were lived.
            let start = calendar.date(byAdding: .day, value: -offset, to: today) ?? today
            let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start
            var starts: [Date] = []
            var cursor = start
            while cursor < end {
                starts.append(cursor)
                guard let next = calendar.date(byAdding: .hour, value: 1, to: cursor),
                      next > cursor else { break }
                cursor = next
            }
            return starts.isEmpty ? [start] : starts

        case .week:
            // The calendar's own week — Sunday here, Monday where the machine says
            // so — rather than the seven days ending today, so the same weekday
            // always sits in the same column.
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? today
            let start = calendar.date(byAdding: .weekOfYear, value: -offset, to: thisWeek) ?? thisWeek
            let starts = (0..<range.days).compactMap {
                calendar.date(byAdding: .day, value: $0, to: start)
            }
            return starts.isEmpty ? [start] : starts

        default:
            // A rolling window: the last `range.days` days, ending today. Stepped a
            // period at a time through the calendar, so paging back over a DST
            // boundary lands on a midnight rather than on 23:00 the evening before.
            let anchor = calendar.date(byAdding: .day, value: -offset * range.days, to: today) ?? today
            let starts = (0..<range.days).reversed().compactMap {
                calendar.date(byAdding: .day, value: -$0, to: anchor)
            }
            return starts.isEmpty ? [anchor] : starts
        }
    }

    /// The bucket an event belongs to: the last of `starts` at or before `date`,
    /// which must not be before the first. The one place a date becomes a bucket,
    /// so the buckets drawn and the events counted can never disagree.
    ///
    /// The starts were already walked through the calendar, so they *are* the
    /// boundaries; a search over them gives the bucket `startOfDay` would, without
    /// asking the calendar once per event — with a remote source's months of
    /// events, those calendar calls were most of the cost of a range switch.
    static func bucketIndex(of date: Date, in starts: [Date]) -> Int {
        var low = 0, high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= date { low = mid } else { high = mid - 1 }
        }
        return low
    }

    /// The bucket the clock is inside.
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
    ///
    /// Internal rather than private because `UsageHistory` prices its days with
    /// it: two pricing paths would be two answers to the same question, and the
    /// grid's dollars have to agree with the chart's.
    static func estimate(over models: [String: TokenTotals]) -> CostEstimate {
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
