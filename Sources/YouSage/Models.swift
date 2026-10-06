import AppKit
import Foundation

struct UsageSnapshot: Sendable, Equatable {
    var fetchedAt: Date
    var sections: [UsageSection]
    var rawJSON: String

    /// The rolling 5-hour limit. Looked up by role rather than key, because the
    /// same limit arrives as `five_hour` on older payloads and as a `limits`
    /// entry on newer ones.
    var sessionSection: UsageSection? {
        sections.first { $0.kind == .session }
    }

    /// The weekly all-models limit, as opposed to a per-model weekly cap.
    var weeklyAllSection: UsageSection? {
        sections.first { $0.kind == .weekly && $0.rank == 1 }
    }
}

struct UsageSection: Sendable, Identifiable, Equatable {
    let id: String
    let title: String
    /// Percent consumed, 0–100. Always present: taken directly from a
    /// utilization field for rate-limit metrics, or derived from
    /// `used / limit` for allotment metrics.
    let percent: Double
    /// Absolute amount consumed in this allotment (enterprise plans). nil for
    /// rate-limit metrics that only report a percentage.
    let used: Double?
    /// Total allotment granted for the period. nil for rate-limit metrics.
    let limit: Double?
    /// Unit the amounts are expressed in — e.g. "tokens", "messages",
    /// "credits", "USD". nil when unknown.
    let unit: String?
    /// When this metric's window resets (rate-limit) or the allotment renews
    /// (enterprise billing period).
    let resetsAt: Date?
    let kind: Kind
    let infoNote: String?
    /// False when claude.ai reported a limit YouSage has no built-in name for.
    /// Such limits are still shown — that's how a newly-introduced limit (a
    /// per-model weekly cap, say) appears without an app update.
    let isRecognized: Bool
    /// Display order within the popover. Lower sorts first.
    let rank: Int

    enum Kind: String, Sendable, Equatable {
        case session
        case weekly
        /// Enterprise / team allotted usage: a fixed allowance per billing
        /// period, reported as an absolute used-of-total amount.
        case allotment
        /// Rate-limit shaped, but on a window we can't name from its key.
        case other
    }

    /// True when this metric carries absolute used/limit amounts (enterprise
    /// allotment) rather than only a rate-limit percentage.
    var hasAllotment: Bool { limit != nil && (limit ?? 0) > 0 }

    /// Human "used / total unit" string for allotment metrics, else nil so the
    /// caller falls back to the plain percent label.
    var allotmentText: String? {
        guard hasAllotment, let limit else { return nil }
        let u = NumberFormat.amount(used ?? 0, unit: unit)
        let l = NumberFormat.amount(limit, unit: unit)
        return "\(u) / \(l)"
    }

    /// Remaining allowance string ("1.2M tokens left"), else nil.
    var remainingText: String? {
        guard hasAllotment, let limit else { return nil }
        let left = max(0, limit - (used ?? 0))
        return "\(NumberFormat.amount(left, unit: unit)) left"
    }
}

// MARK: - Number formatting

enum NumberFormat {
    /// Compact human formatting. Money units render as currency; large counts
    /// collapse to K/M/B; the unit (if any) is appended.
    static func amount(_ value: Double, unit: String?) -> String {
        let u = (unit ?? "").lowercased()
        let isMoney = u == "usd" || u == "$" || u == "dollars" || u.contains("dollar")
        if isMoney {
            // Cents below $1000, compacted above it. The threshold matches where
            // compact() starts collapsing, so both halves of a "used / limit"
            // pair always render the same way — never "$40.00 / $100".
            return "$" + compact(value, forceDecimals: Swift.abs(value) < 1_000)
        }
        let suffix = (unit?.isEmpty == false) ? " \(unit!)" : ""
        return compact(value) + suffix
    }

    static func tokens(_ value: Int) -> String { compact(Double(value)) }

    /// Dollars at a glance — for axis ticks, tooltips, and table cells, where a
    /// column of "$217.06" is four characters of noise per row. Cents survive
    /// only below $10, which is the scale at which they are the whole number.
    static func money(_ value: Double) -> String {
        let abs = Swift.abs(value)
        if abs >= 1_000 { return "$" + compact(value) }
        if abs >= 10 || abs == 0 { return "$\(Int(value.rounded()))" }
        return String(format: "$%.2f", value)
    }

    static func compact(_ value: Double, forceDecimals: Bool = false) -> String {
        let abs = Swift.abs(value)
        switch abs {
        case 1_000_000_000...:
            return trim(value / 1_000_000_000) + "B"
        case 1_000_000...:
            return trim(value / 1_000_000) + "M"
        case 1_000...:
            return trim(value / 1_000) + "K"
        default:
            if forceDecimals { return String(format: "%.2f", value) }
            return trim(value)
        }
    }

    private static func trim(_ value: Double) -> String {
        if value == value.rounded() && Swift.abs(value) < 1_000 {
            return String(Int(value.rounded()))
        }
        return String(format: "%.1f", value)
    }
}

// MARK: - Plan

/// How YouSage decides which usage shape to present. `auto` reads it off the
/// `/usage` payload, which is unambiguous: allotment amounts mean a
/// seat/credit plan, bare utilization percentages mean a subscription.
enum PlanMode: String, CaseIterable, Sendable, Identifiable {
    case auto
    case subscription
    case enterprise

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto:         return "Automatic"
        case .subscription: return "Subscription"
        case .enterprise:   return "Enterprise"
        }
    }
}

enum DetectedPlan: String, Sendable, Equatable {
    case subscription
    case enterprise
    case unknown

    var displayName: String {
        switch self {
        case .subscription: return "Subscription (Pro / Max)"
        case .enterprise:   return "Enterprise / Team"
        case .unknown:      return "Unknown"
        }
    }
}

/// Which appearance the app paints itself in.
///
/// The window already reads correctly in both — every custom colour forks on the
/// colour scheme and the rest is system material — so this only decides which one
/// macOS hands it.
enum Appearance: String, CaseIterable, Sendable, Identifiable {
    case system
    case light
    case dark

    static let `default`: Appearance = .system

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }

    /// What `NSApp.appearance` is set to. nil for `.system`, and deliberately not
    /// the system's current appearance resolved once: nil keeps the app following
    /// macOS as it changes, where a resolved value would freeze it at whatever the
    /// system happened to be when we looked.
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light:  return .aqua
        case .dark:   return .darkAqua
        }
    }

    /// An unreadable or absent stored value follows the system, which is what a
    /// first launch does — a setting we cannot understand is a setting nobody
    /// chose.
    init(stored: String?) {
        self = stored.flatMap(Appearance.init(rawValue:)) ?? .default
    }
}

enum MenuBarMetric: String, CaseIterable, Sendable, Identifiable {
    case highest
    case allotment
    case session
    case weekly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highest:   return "Highest of all limits"
        case .allotment: return "Allotted usage"
        case .session:   return "Current session (5 hr)"
        case .weekly:    return "Weekly · All models"
        }
    }
}

// MARK: - Token tracking

/// Token counts summed from local Claude Code transcripts.
struct TokenTotals: Sendable, Equatable {
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0
    var messages = 0

    var total: Int { input + output + cacheCreation + cacheRead }
    var cache: Int { cacheCreation + cacheRead }
    var isEmpty: Bool { messages == 0 }

    static func + (a: TokenTotals, b: TokenTotals) -> TokenTotals {
        TokenTotals(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheCreation: a.cacheCreation + b.cacheCreation,
                    cacheRead: a.cacheRead + b.cacheRead,
                    messages: a.messages + b.messages)
    }

    /// "in 12K · out 48K · cache 1.3M" — cache folded into one number because
    /// the creation/read split isn't actionable at a glance.
    var breakdown: String {
        "in \(NumberFormat.tokens(input)) · out \(NumberFormat.tokens(output)) · cache \(NumberFormat.tokens(cache))"
    }
}

/// `claude-opus-4-8` → `Opus 4.8`. Normalizes first, so provider prefixes,
/// bracketed variants, and date stamps all fall away before formatting.
func modelDisplayName(_ id: String) -> String {
    var s = Pricing.normalize(id)
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    let parts = s.split(separator: "-").map(String.init)
    guard let family = parts.first, !family.isEmpty else { return id }
    let version = parts.dropFirst().joined(separator: ".")
    let name = family.prefix(1).uppercased() + family.dropFirst()
    return version.isEmpty ? name : "\(name) \(version)"
}

struct ModelTokens: Sendable, Equatable, Identifiable {
    let model: String
    let totals: TokenTotals
    var id: String { model }

    var displayName: String { modelDisplayName(model) }
}

/// What a window's tokens would cost at Anthropic's API list prices. YouSage is
/// a subscription tool — nobody is billed for these. The number answers "what
/// would this have cost per-token?", which is curiosity, not accounting.
struct CostEstimate: Sendable, Equatable {
    /// Dollars across every event whose model could be priced.
    var amount: Double = 0
    /// Models seen in the window but absent from the rate table. A non-empty
    /// list means `amount` is an undercount, and `display` says so.
    var unpricedModels: [String] = []

    var isComplete: Bool { unpricedModels.isEmpty }

    /// "$4.12", or "≥ $27.60" when some of the window couldn't be priced.
    var display: String {
        let money = NumberFormat.amount(amount, unit: "USD")
        return isComplete ? money : "≥ \(money)"
    }

    /// Every cent, grouped: "$1,301.42". `display` compacts past $1,000 — which is
    /// right in the popover, where the figure is a glance, and wrong on the
    /// dashboard, where "$1.3K" hides the difference between a $1,300 month and a
    /// $1,349 one.
    var exactDisplay: String {
        let money = amount.formatted(.currency(code: "USD"))
        return isComplete ? money : "≥ \(money)"
    }
}

/// One machine's share of the token windows.
struct SourceTokens: Sendable, Equatable, Identifiable {
    /// "local" for this Mac, else the remote source's id (its tailnet DNS name).
    let id: String
    /// "This Mac", or the host name the remote source reports.
    let name: String
    let isLocal: Bool
    let session: TokenTotals
    let week: TokenTotals
}

struct TokenReport: Sendable, Equatable {
    /// Totals inside the active 5-hour window. Empty when no window is active.
    let session: TokenTotals
    /// Start of the active 5-hour window, nil when there's no recent activity.
    let sessionStart: Date?
    /// True when `sessionStart` was pinned to claude.ai's own `five_hour`
    /// reset time rather than inferred from local timestamps.
    let sessionIsAuthoritative: Bool
    let sessionCost: CostEstimate
    /// Totals since local midnight. Not a slice of either window either side of
    /// it: the session is a rolling five hours that can straddle midnight, and
    /// the week is a rolling seven days — "today" is the one figure of the three
    /// that lines up with the day the person thinks they have had.
    let today: TokenTotals
    let todayCost: CostEstimate
    let week: TokenTotals
    let weekStart: Date?
    let weekCost: CostEstimate
    /// Per-model split for the session window, largest first.
    let models: [ModelTokens]
    /// This Mac vs each remote source, for both windows. Empty when no remote
    /// source contributes, so a lone Mac shows no split.
    let sources: [SourceTokens]
    let filesScanned: Int
    let generatedAt: Date

    var hasAnyData: Bool { !week.isEmpty || !session.isEmpty || !today.isEmpty }
}

enum ClaudeError: Error, Sendable {
    case missingSessionKey
    case http(status: Int, body: String)
    case decoding(String)
    case noOrg
    case network(String)

    var userMessage: String {
        switch self {
        case .missingSessionKey:
            return "Add your sessionKey in Settings."
        case .http(let code, _):
            switch code {
            case 401, 403: return "Session expired — paste a fresh sessionKey."
            case 429: return "Rate limited. Backing off…"
            case 500..<600: return "Claude.ai server error (\(code)). Will retry."
            default: return "HTTP \(code) from claude.ai"
            }
        case .decoding(let s):
            return "Unexpected response shape: \(s)"
        case .noOrg:
            return "No organization found on this account."
        case .network(let s):
            return "Network error: \(s)"
        }
    }
}
