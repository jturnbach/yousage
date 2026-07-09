import Foundation

/// Anthropic's list price for one model, in US dollars per million tokens.
///
/// Cache traffic bills off the input rate rather than having rates of its own.
/// The spread matters: cache reads dominate Claude Code's token mix, so pricing
/// them as fresh input would overstate a week of usage several times over.
struct ModelRate: Equatable {
    let input: Double
    let output: Double

    /// 5-minute TTL. Transcripts don't record the TTL, and a 1-hour write
    /// actually costs 2x input, so heavy `ttl: "1h"` use underestimates.
    var cacheWrite: Double { input * 1.25 }
    var cacheRead: Double { input * 0.10 }
}

enum Pricing {
    private static let million = 1_000_000.0

    private static let table: [String: ModelRate] = [
        "claude-fable-5":    ModelRate(input: 10, output: 50),
        "claude-mythos-5":   ModelRate(input: 10, output: 50),
        "claude-opus-4-8":   ModelRate(input: 5,  output: 25),
        "claude-opus-4-7":   ModelRate(input: 5,  output: 25),
        "claude-opus-4-6":   ModelRate(input: 5,  output: 25),
        "claude-sonnet-5":   ModelRate(input: 3,  output: 15),
        "claude-sonnet-4-6": ModelRate(input: 3,  output: 15),
        "claude-haiku-4-5":  ModelRate(input: 1,  output: 5),
    ]

    /// Consulted when an id isn't in `table`, so a point release published after
    /// this code was written still prices at its family's rate instead of
    /// vanishing from the total.
    private static let families: [(name: String, rate: ModelRate)] = [
        ("fable",  ModelRate(input: 10, output: 50)),
        ("mythos", ModelRate(input: 10, output: 50)),
        ("opus",   ModelRate(input: 5,  output: 25)),
        ("sonnet", ModelRate(input: 3,  output: 15)),
        ("haiku",  ModelRate(input: 1,  output: 5)),
    ]

    /// Drops the parts of a model id that never affect price: a bracketed
    /// variant (`[1m]`) and a trailing 8-digit date stamp (`-20251001`).
    static func normalize(_ model: String) -> String {
        var id = model
        if let bracket = id.firstIndex(of: "[") {
            id = String(id[id.startIndex..<bracket])
        }
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    static func rate(for model: String) -> ModelRate? {
        if let exact = table[model] { return exact }
        let normalized = normalize(model)
        if let match = table[normalized] { return match }
        return families.first { normalized.contains($0.name) }?.rate
    }

    /// Dollars these counters would cost at `model`'s list price, or nil when
    /// the model can't be priced at all. The nil is deliberate — an unknown
    /// model must surface as a gap, never as a silent zero.
    static func cost(_ totals: TokenTotals, model: String) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let dollars =
            Double(totals.input) * rate.input
            + Double(totals.output) * rate.output
            + Double(totals.cacheCreation) * rate.cacheWrite
            + Double(totals.cacheRead) * rate.cacheRead
        return dollars / million
    }
}
