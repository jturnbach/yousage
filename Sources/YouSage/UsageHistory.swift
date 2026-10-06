import Foundation

/// One calendar day of the long view — the same measurements the trend chart
/// plots, summed over a whole day and kept for every day the transcripts reach.
struct DayUsage: Sendable, Equatable, Identifiable {
    /// Local midnight.
    let start: Date
    let totals: TokenTotals
    let cost: CostEstimate
    var id: Date { start }
}

/// Every retained day, oldest first — the activity grid's data.
///
/// Deliberately separate from `UsageBreakdown`: the grid is the one thing on the
/// page the range picker does not move. A window paged back to April still wants
/// the whole history underneath it, because the grid is what tells you *where*
/// April sits among the other months.
struct UsageHistory: Sendable, Equatable {
    /// One per calendar day, zero-filled, ending today. Never runs into
    /// tomorrow: a day that has not happened is not a day of no usage, and the
    /// grid leaves the rest of this week blank rather than drawing it cold.
    let days: [DayUsage]
    let generatedAt: Date

    var totals: TokenTotals { days.reduce(TokenTotals()) { $0 + $1.totals } }

    /// Dollars over the whole history. A lower bound wherever a day held a model
    /// the rate table cannot price, exactly as every other cost figure is.
    var cost: CostEstimate {
        days.reduce(CostEstimate()) { sum, day in
            var sum = sum
            sum.amount += day.cost.amount
            sum.unpricedModels = Array(Set(sum.unpricedModels).union(day.cost.unpricedModels)).sorted()
            return sum
        }
    }

    /// Days that saw anything at all. The denominator is `days.count`, so the
    /// pair reads as "22 of 180" — a rate, not a bare count.
    var activeDays: Int { days.filter { $0.totals.total > 0 }.count }

    var isEmpty: Bool { activeDays == 0 }
}

extension UsageHistory {
    /// The last `span` days, bucketed by local calendar day.
    ///
    /// Pure, like `UsageBreakdown.make`, so the grid can be tested with synthetic
    /// events. Days are walked with the calendar rather than strided by 86,400
    /// seconds, so a DST boundary does not shift every earlier day into its
    /// neighbour's column.
    static func make(from events: [UsageEvent],
                     now: Date,
                     calendar: Calendar,
                     span: Int = UsageRange.historyDays) -> UsageHistory {
        let today = calendar.startOfDay(for: now)
        let starts: [Date] = (0..<max(span, 1)).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        guard let first = starts.first else { return UsageHistory(days: [], generatedAt: now) }
        let end = calendar.date(byAdding: .day, value: 1, to: today) ?? now

        // Bucketed against the walked midnights, like the breakdown's buckets,
        // rather than one calendar call per event.
        var perDayModel = [[String: TokenTotals]](repeating: [:], count: starts.count)
        for e in events where e.date >= first && e.date < end {
            let day = UsageBreakdown.bucketIndex(of: e.date, in: starts)
            perDayModel[day][e.model] = (perDayModel[day][e.model] ?? TokenTotals()) + e.totals
        }

        let days = starts.enumerated().map { index, day -> DayUsage in
            let models = perDayModel[index]
            return DayUsage(start: day,
                            totals: models.values.reduce(TokenTotals()) { $0 + $1 },
                            cost: UsageBreakdown.estimate(over: models))
        }
        return UsageHistory(days: days, generatedAt: now)
    }
}

/// How dark a day is drawn. Four steps of one hue, plus a step for nothing at
/// all — a scale a reader can hold in their head, which a continuous gradient of
/// orange is not.
enum HeatScale {
    /// Steps above "nothing". The legend draws this many swatches, so the two
    /// cannot drift apart.
    static let steps = 4

    /// 0 for a day with nothing on it, 1…4 by how the day compares with the
    /// busiest day in the grid.
    ///
    /// Scaled by the square root of the share rather than the share itself.
    /// Token counts are long-tailed — one all-day session can be ten times an
    /// ordinary day — and a linear ramp would paint every ordinary day the palest
    /// step, saying nothing about the differences between them. The square root
    /// pulls the crowded low end apart while keeping the order intact, and the
    /// busiest day always lands on the darkest step, which a quartile ranking
    /// cannot promise on a history where most days tie.
    static func level(_ value: Double, peak: Double) -> Int {
        guard value > 0, peak > 0 else { return 0 }
        let share = min(value / peak, 1)
        return min(steps, max(1, Int(ceil(share.squareRoot() * Double(steps)))))
    }
}
