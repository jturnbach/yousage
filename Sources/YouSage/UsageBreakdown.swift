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
    var id: ModelFamily { family }
}

struct DayUsage: Sendable, Equatable, Identifiable {
    /// Local start of day.
    let day: Date
    /// Still accruing; the chart draws it at reduced opacity.
    let isToday: Bool
    /// Only families active that day, in `ModelFamily.allCases` order.
    let byFamily: [FamilyTokens]
    let totals: TokenTotals
    let cost: CostEstimate
    var id: Date { day }
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

/// Seven calendar days of usage, sliced three ways. A tuple would be lighter than
/// `KindTotal`, but tuples do not synthesize `Equatable` and SwiftUI needs that.
struct UsageBreakdown: Sendable, Equatable {
    /// Exactly `dayCount` entries, oldest first, zero-filled.
    let days: [DayUsage]
    /// Cost descending, then tokens descending, then name — so the order is total.
    let models: [ModelCost]
    /// Always four, in declaration order.
    let kinds: [KindTotal]
    let totals: TokenTotals
    let cost: CostEstimate
    let generatedAt: Date
}

extension UsageBreakdown {
    /// The last `dayCount` local calendar days ending on `now`'s day.
    ///
    /// Pure: everything the window draws is decided here, so it can be tested with
    /// synthetic events instead of transcript fixtures. Bucketing goes through
    /// `Calendar.startOfDay`, so a 23-hour spring-forward day and a 25-hour
    /// fall-back day both land where a human would put them.
    static func make(from events: [UsageEvent],
                     now: Date,
                     calendar: Calendar,
                     dayCount: Int = 7) -> UsageBreakdown {
        let emptyKinds = TokenKind.allCases.map { KindTotal(kind: $0, count: 0) }
        guard dayCount > 0 else {
            return UsageBreakdown(days: [], models: [], kinds: emptyKinds,
                                  totals: TokenTotals(), cost: CostEstimate(),
                                  generatedAt: now)
        }

        let today = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (0..<dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let spanStart = dayStarts[0]
        let spanEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? now

        // Bucket once; every slice below reads from these two maps.
        var perDayModel: [Date: [String: TokenTotals]] = [:]
        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= spanStart && e.date < spanEnd {
            let day = calendar.startOfDay(for: e.date)
            var models = perDayModel[day] ?? [:]
            models[e.model] = (models[e.model] ?? TokenTotals()) + e.totals
            perDayModel[day] = models
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }

        let days: [DayUsage] = dayStarts.map { day in
            let models = perDayModel[day] ?? [:]

            var byFamilyMap: [ModelFamily: TokenTotals] = [:]
            for (id, totals) in models {
                let family = ModelFamily(modelID: id)
                byFamilyMap[family] = (byFamilyMap[family] ?? TokenTotals()) + totals
            }
            let byFamily = ModelFamily.allCases.compactMap { family -> FamilyTokens? in
                guard let totals = byFamilyMap[family], !totals.isEmpty else { return nil }
                return FamilyTokens(family: family, totals: totals)
            }

            return DayUsage(day: day,
                            isToday: day == today,
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

        return UsageBreakdown(days: days,
                              models: models,
                              kinds: kinds,
                              totals: totals,
                              cost: estimate(over: perModel),
                              generatedAt: now)
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
