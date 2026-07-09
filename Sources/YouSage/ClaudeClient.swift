import Foundation

/// Talks to the unofficial claude.ai web API. Uses the `sessionKey` cookie
/// for auth and mimics the browser-side headers the web app sends (needed
/// to get past Cloudflare gating on the API host).
final class ClaudeClient: @unchecked Sendable {
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpAdditionalHeaders = [:]
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: config)
    }

    struct Organization: Sendable {
        let uuid: String
        let name: String?
        let planType: String?
        let capabilities: [String]

        /// claude.ai tags enterprise orgs with a `raven` capability (its
        /// internal codename) — a useful tiebreaker when the usage payload
        /// itself is ambiguous.
        var looksEnterprise: Bool {
            capabilities.contains { cap in
                let c = cap.lowercased()
                return c == "raven" || c.contains("enterprise") || c.contains("team")
            } || (planType?.lowercased().contains("enterprise") ?? false)
        }
    }

    func fetchOrganizations(sessionKey: String) async throws -> [Organization] {
        let url = URL(string: "https://claude.ai/api/organizations")!
        let data = try await get(url, sessionKey: sessionKey)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClaudeError.decoding("organizations: expected array")
        }
        return arr.compactMap { dict -> Organization? in
            guard let uuid = dict["uuid"] as? String else { return nil }
            let caps = (dict["capabilities"] as? [String]) ?? []
            let plan = (dict["settings"] as? [String: Any])?["claude_pro_subscription"] as? String
                ?? dict["organization_type"] as? String
                ?? caps.first(where: { $0.hasPrefix("claude_pro") || $0.hasPrefix("claude_max") || $0.hasPrefix("raven") })
            return Organization(uuid: uuid,
                                name: dict["name"] as? String,
                                planType: plan,
                                capabilities: caps)
        }
    }

    func fetchPrimaryOrgUUID(sessionKey: String) async throws -> String {
        let orgs = try await fetchOrganizations(sessionKey: sessionKey)
        guard let first = orgs.first else { throw ClaudeError.noOrg }
        return first.uuid
    }

    func fetchUsage(orgUUID: String, sessionKey: String) async throws -> UsageSnapshot {
        let url = URL(string: "https://claude.ai/api/organizations/\(orgUUID)/usage")!
        let data = try await get(url, sessionKey: sessionKey)
        let raw = (try? prettyPrint(data)) ?? (String(data: data, encoding: .utf8) ?? "")
        let sections = try Self.parseSections(data: data)
        return UsageSnapshot(fetchedAt: Date(), sections: sections, rawJSON: raw)
    }

    private func prettyPrint(_ data: Data) throws -> String {
        let obj = try JSONSerialization.jsonObject(with: data)
        let pretty = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        return String(data: pretty, encoding: .utf8) ?? ""
    }

    private func get(_ url: URL, sessionKey: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("sessionKey=\(sessionKey)", forHTTPHeaderField: "Cookie")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("web_claude_ai", forHTTPHeaderField: "anthropic-client-platform")
        req.setValue("1.0.0", forHTTPHeaderField: "anthropic-client-version")
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
                     forHTTPHeaderField: "User-Agent")
        req.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        req.setValue("https://claude.ai/settings/usage", forHTTPHeaderField: "Referer")
        req.setValue("empty", forHTTPHeaderField: "Sec-Fetch-Dest")
        req.setValue("cors", forHTTPHeaderField: "Sec-Fetch-Mode")
        req.setValue("same-origin", forHTTPHeaderField: "Sec-Fetch-Site")

        let (data, resp): (Data, URLResponse)
        do {
            (data, resp) = try await session.data(for: req)
        } catch {
            throw ClaudeError.network(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else {
            throw ClaudeError.http(status: 0, body: "No HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw ClaudeError.http(status: http.statusCode, body: body)
        }
        return data
    }

    // MARK: - Parsing

    /// Titles and explanatory notes for limits we recognize. This table exists
    /// only to give known limits a good name — discovery does not depend on it,
    /// so a limit Anthropic ships tomorrow still shows up (auto-titled from its
    /// key) without an app update.
    private static let knownLimits: [String: (title: String, note: String?)] = [
        "five_hour": ("Current session",
                      "Rolling 5-hour window, shared across claude.ai, the Claude apps, and Claude Code."),
        "seven_day": ("All models",
                      "Your weekly limit across every model."),
        "seven_day_sonnet": ("Sonnet", "Weekly limit that applies only to Sonnet."),
        "seven_day_opus": ("Opus", "Weekly limit that applies only to Opus."),
        "seven_day_haiku": ("Haiku", "Weekly limit that applies only to Haiku."),
        "seven_day_fable": ("Fable", "Weekly limit that applies only to Fable."),
        "seven_day_oauth_apps": ("OAuth apps",
                                 "Third-party apps you've authorized via Sign-In-With-Claude. Claude Code counts toward All models, not this bucket."),
        "seven_day_code": ("Claude Code", "Weekly limit that applies only to Claude Code."),
    ]

    private static let discoveredNote =
        "Reported by claude.ai but not a limit YouSage knows by name — shown as-is."

    /// Keys handled by a dedicated parser, or that describe the account rather
    /// than its usage. The generic sweep must skip them or it double-counts.
    private static let reservedKeys: Set<String> = [
        "limits", "extra_usage", "spend",
        "allotments", "usage_allotments", "allotment", "quotas", "organization_usage",
        "settings", "capabilities", "user", "account", "organization", "billing",
        "member_dashboard_available",
    ]

    /// Maps the claude.ai `/usage` payload to a list of sections.
    ///
    /// Three sources, merged, in descending order of trust:
    ///
    ///  1. `limits` — a self-describing array claude.ai now returns. Each entry
    ///     names its own `kind` (`session`, `weekly_all`, `weekly_scoped`) and
    ///     carries a `scope` naming the model it applies to. This is where a
    ///     newly-introduced per-model cap shows up, already labelled, which is
    ///     why it's preferred: a limit for a model that doesn't exist yet still
    ///     renders with the right name.
    ///  2. `extra_usage` / `spend` — pay-per-token usage past the plan limits,
    ///     and prepaid usage credits. Both report an absolute amount, and both
    ///     are omitted unless the account has them switched on.
    ///  3. Legacy top-level keys (`five_hour`, `seven_day`, `seven_day_opus`, …)
    ///     plus any other usage-shaped object, for accounts and server versions
    ///     that don't return `limits`.
    ///
    /// Sources 1 and 3 overlap — `five_hour` restates `limits[kind=session]` —
    /// so identically-named entries collapse, preferring whichever carries real
    /// amounts over a bare percentage.
    static func parseSections(data: Data) throws -> [UsageSection] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("expected top-level object")
        }

        var out: [UsageSection] = []

        if let limits = obj["limits"] as? [[String: Any]] {
            for (idx, entry) in limits.enumerated() {
                if let section = makeLimitSection(entry, index: idx) { out.append(section) }
            }
        }

        out.append(contentsOf: parsePaidUsage(obj))

        for (key, value) in obj where !reservedKeys.contains(key.lowercased()) {
            if let dict = value as? [String: Any] {
                if let section = makeSection(id: key, key: key, dict: dict) {
                    out.append(section)
                    continue
                }
                // Not usage-shaped itself: it may be a container of limits.
                for (subKey, subValue) in dict {
                    guard let subDict = subValue as? [String: Any],
                          let section = makeSection(id: "\(key).\(subKey)", key: subKey, dict: subDict)
                    else { continue }
                    out.append(section)
                }
            } else if let arr = value as? [[String: Any]] {
                for (idx, sub) in arr.enumerated() {
                    let name = (sub["name"] as? String) ?? (sub["type"] as? String)
                        ?? (sub["category"] as? String) ?? "\(key) \(idx + 1)"
                    guard let section = makeSection(id: "\(key)[\(idx)]", key: name, dict: sub) else { continue }
                    out.append(section)
                }
            }
        }

        // Recognized limits before discovered ones within a group, then by name,
        // so a surprise entry never displaces the numbers people look for first.
        return dedupe(out).sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            if $0.isRecognized != $1.isRecognized { return $0.isRecognized }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
    }

    /// Collapses sections describing the same limit, keeping the richer one.
    private static func dedupe(_ sections: [UsageSection]) -> [UsageSection] {
        var byIdentity: [String: UsageSection] = [:]
        var order: [String] = []
        for section in sections {
            let identity = "\(section.kind.rawValue)|\(section.title.lowercased())"
            guard let existing = byIdentity[identity] else {
                byIdentity[identity] = section
                order.append(identity)
                continue
            }
            // A dollar/credit amount beats a bare percentage for the same limit.
            if section.hasAllotment && !existing.hasAllotment {
                byIdentity[identity] = section
            }
        }
        return order.compactMap { byIdentity[$0] }
    }

    /// Builds a section from one entry of the `limits` array.
    private static func makeLimitSection(_ entry: [String: Any], index: Int) -> UsageSection? {
        guard let percent = number(entry["percent"]) ?? number(entry["utilization"]) else { return nil }

        let kindString = (entry["kind"] as? String)?.lowercased() ?? ""
        let group = (entry["group"] as? String)?.lowercased() ?? ""
        let scope = entry["scope"] as? [String: Any]
        let scopedName = (scope?["model"] as? [String: Any])?["display_name"] as? String
            ?? (scope?["surface"] as? [String: Any])?["display_name"] as? String

        let kind: UsageSection.Kind
        if group == "session" || kindString.contains("session") { kind = .session }
        else if group == "weekly" || kindString.contains("weekly") { kind = .weekly }
        else { kind = .other }

        // A scoped limit names its own model, so even a model YouSage has never
        // heard of arrives correctly labelled.
        let title: String
        let recognized: Bool
        if let scopedName {
            title = scopedName
            recognized = true
        } else {
            switch kindString {
            case "session":     title = "Current session"; recognized = true
            case "weekly_all":  title = "All models";      recognized = true
            case "weekly_scoped": title = "Scoped weekly limit"; recognized = false
            default:
                title = humanize(kindString.isEmpty ? (group.isEmpty ? "limit \(index + 1)" : group) : kindString)
                recognized = false
            }
        }

        let rank: Int
        switch kind {
        case .session: rank = 0
        case .weekly:  rank = kindString == "weekly_all" ? 1 : 2
        case .other:   rank = 3
        case .allotment: rank = 4
        }

        let note: String? = {
            if scopedName != nil { return "Weekly limit that applies only to \(scopedName!)." }
            switch kindString {
            case "session":    return knownLimits["five_hour"]?.note
            case "weekly_all": return knownLimits["seven_day"]?.note
            default:           return recognized ? nil : discoveredNote
            }
        }()

        let id = scopedName.map { "limits.\(kindString).\($0.lowercased())" }
            ?? (kindString.isEmpty ? "limits[\(index)]" : "limits.\(kindString)")

        let allotment = parseAllotment(entry)
        return UsageSection(
            id: id,
            title: title,
            percent: min(100, max(0, percent)),
            used: allotment?.used,
            limit: allotment?.limit,
            unit: allotment?.unit,
            resetsAt: extractResetDate(entry),
            kind: kind,
            infoNote: note,
            isRecognized: recognized,
            rank: rank
        )
    }

    /// Pay-per-token usage beyond the plan (`extra_usage`) and prepaid credits
    /// (`spend`). Both sit in the payload permanently and are only meaningful
    /// once the account turns them on.
    private static func parsePaidUsage(_ obj: [String: Any]) -> [UsageSection] {
        var out: [UsageSection] = []

        if let extra = obj["extra_usage"] as? [String: Any], bool(extra["is_enabled"]) {
            let used = firstNumber(extra, ["used_credits", "used", "amount_used"])
            let limit = firstNumber(extra, ["monthly_limit", "limit", "cap"])
            let unit = extra["currency"] as? String
            let percent = number(extra["utilization"])
            if let limit, limit > 0 {
                out.append(UsageSection(
                    id: "extra_usage", title: "Extra usage",
                    percent: min(100, max(0, (used ?? 0) / limit * 100)),
                    used: used ?? 0, limit: limit, unit: unit,
                    resetsAt: extractResetDate(extra), kind: .allotment,
                    infoNote: "Pay-per-token usage once your plan limits are reached.",
                    isRecognized: true, rank: 4))
            } else if let percent {
                out.append(UsageSection(
                    id: "extra_usage", title: "Extra usage",
                    percent: min(100, max(0, percent)),
                    used: used, limit: nil, unit: unit,
                    resetsAt: extractResetDate(extra), kind: .other,
                    infoNote: "Pay-per-token usage once your plan limits are reached.",
                    isRecognized: true, rank: 3))
            }
        }

        if let spend = obj["spend"] as? [String: Any], bool(spend["enabled"]) {
            let used = money(spend["used"])
            let limit = money(spend["limit"]) ?? money(spend["cap"])
            let percent = number(spend["percent"])
            let unit = used?.currency ?? limit?.currency ?? "USD"
            if let limit, limit.amount > 0 {
                out.append(UsageSection(
                    id: "spend", title: "Usage credits",
                    percent: min(100, max(0, (used?.amount ?? 0) / limit.amount * 100)),
                    used: used?.amount ?? 0, limit: limit.amount, unit: unit,
                    resetsAt: extractResetDate(spend), kind: .allotment,
                    infoNote: "Prepaid credits that cover you past your plan limits.",
                    isRecognized: true, rank: 4))
            } else if let used, used.amount > 0 || (percent ?? 0) > 0 {
                out.append(UsageSection(
                    id: "spend", title: "Usage credits",
                    percent: min(100, max(0, percent ?? 0)),
                    used: used.amount, limit: nil, unit: unit,
                    resetsAt: extractResetDate(spend), kind: .other,
                    infoNote: "Prepaid credits that cover you past your plan limits.",
                    isRecognized: true, rank: 3))
            }
        }

        // Enterprise seat plans hand back a container of allotments instead.
        for key in ["allotments", "usage_allotments", "allotment", "quotas", "organization_usage"] {
            guard let container = obj[key] as? [String: Any] else { continue }
            if let section = makeSection(id: key, key: key, dict: container) {
                out.append(section)
                continue
            }
            for (subKey, subValue) in container {
                guard let subDict = subValue as? [String: Any],
                      let section = makeSection(id: "\(key).\(subKey)", key: subKey, dict: subDict)
                else { continue }
                out.append(section)
            }
        }

        return out
    }

    /// `{"amount_minor": 4250, "currency": "USD", "exponent": 2}` → 42.50 USD.
    private static func money(_ any: Any?) -> (amount: Double, currency: String?)? {
        if let dict = any as? [String: Any], let minor = number(dict["amount_minor"]) {
            let exponent = number(dict["exponent"]) ?? 2
            return (minor / pow(10, exponent), dict["currency"] as? String)
        }
        if let n = number(any) { return (n, nil) }
        return nil
    }

    private static func bool(_ any: Any?) -> Bool {
        if let b = any as? Bool { return b }
        if let n = any as? NSNumber { return n.boolValue }
        return false
    }

    /// Builds a section from a usage-shaped dict, attaching allotment
    /// (used/total) amounts when present. Returns nil when the dict carries
    /// neither a percentage nor an amount.
    private static func makeSection(id: String, key: String, dict: [String: Any]) -> UsageSection? {
        let allotment = parseAllotment(dict)
        let percent = parsePercent(dict)
        guard allotment != nil || percent != nil else { return nil }

        let known = knownLimits[key.lowercased()]
        // The window a limit belongs to is a property of its key, not of whether
        // it happens to report dollars — a 5-hour limit denominated in dollars is
        // still the 5-hour limit.
        let kind = classify(key: key, isAllotment: allotment != nil && percent == nil)
        let resolvedPercent: Double
        if let a = allotment, a.limit > 0, percent == nil {
            resolvedPercent = min(100, max(0, a.used / a.limit * 100))
        } else {
            resolvedPercent = min(100, max(0, percent ?? 0))
        }

        return UsageSection(
            id: id,
            title: known?.title ?? humanize(key),
            percent: resolvedPercent,
            used: allotment?.used,
            limit: allotment?.limit,
            unit: allotment?.unit,
            resetsAt: extractResetDate(dict),
            kind: kind,
            infoNote: known?.note ?? (allotment == nil ? discoveredNote : nil),
            isRecognized: known != nil,
            rank: rank(kind: kind, key: key)
        )
    }

    private static func classify(key: String, isAllotment: Bool) -> UsageSection.Kind {
        if isAllotment { return .allotment }
        let k = key.lowercased()
        if k.contains("five_hour") || k.contains("5_hour") || k.hasPrefix("five") || k.contains("session") {
            return .session
        }
        if k.contains("seven_day") || k.contains("7_day") || k.contains("week") {
            return .weekly
        }
        return .other
    }

    private static func rank(kind: UsageSection.Kind, key: String) -> Int {
        switch kind {
        case .session:   return 0
        case .weekly:    return key.lowercased() == "seven_day" ? 1 : 2
        case .other:     return 3
        case .allotment: return 4
        }
    }

    /// `seven_day_fable` → `Fable`; `monthly_spend` → `Spend`. Window prefixes
    /// are dropped because the section already sits under a window heading.
    static func humanize(_ key: String) -> String {
        let specials = ["opus": "Opus", "sonnet": "Sonnet", "haiku": "Haiku", "fable": "Fable",
                        "oauth": "OAuth", "api": "API", "ai": "AI", "usd": "USD"]
        var k = key.lowercased()
        for prefix in ["seven_day_", "7_day_", "five_hour_", "5_hour_", "weekly_", "monthly_", "daily_"]
        where k.hasPrefix(prefix) {
            k = String(k.dropFirst(prefix.count))
            break
        }
        if k.isEmpty { k = key.lowercased() }
        let words = k.split(whereSeparator: { $0 == "_" || $0 == "-" || $0 == " " }).map { word -> String in
            let s = String(word)
            if let special = specials[s] { return special }
            return s.prefix(1).uppercased() + s.dropFirst()
        }
        return words.isEmpty ? key : words.joined(separator: " ")
    }

    /// Rate-limit percentage, or nil when the dict reports none.
    private static func parsePercent(_ dict: [String: Any]) -> Double? {
        for k in ["utilization", "utilization_pct", "percent", "percent_used", "pct"] {
            if let v = number(dict[k]) { return v }
        }
        return nil
    }

    /// Pulls absolute allotment amounts out of a dict using a broad set of
    /// candidate field names. Returns nil when the dict isn't allotment-shaped.
    /// Derives whichever of used/limit is missing from `remaining` when possible.
    static func parseAllotment(_ dict: [String: Any]) -> (used: Double, limit: Double, unit: String?)? {
        let usedKeys      = ["used_dollars", "used", "used_credits", "usage", "consumed",
                             "spent", "amount_used", "current", "current_usage", "value"]
        let limitKeys     = ["limit_dollars", "limit", "allotment", "quota", "granted",
                             "total", "cap", "max", "monthly_limit", "allocation",
                             "allowance", "total_credits", "included"]
        let remainingKeys = ["remaining_dollars", "remaining", "left", "available", "balance"]

        let used      = firstNumber(dict, usedKeys)
        var limit     = firstNumber(dict, limitKeys)
        let remaining = firstNumber(dict, remainingKeys)

        // A bare ceiling with nothing consumed against it isn't an allotment —
        // it's some unrelated config dict (`{"max": 5}`) that happens to sit in
        // the payload. Require evidence of consumption before claiming one.
        guard used != nil || remaining != nil else { return nil }

        // Reconstruct missing pieces from the relationship used + remaining = limit.
        var resolvedUsed = used
        if limit == nil, let u = used, let r = remaining { limit = u + r }
        if resolvedUsed == nil, let l = limit, let r = remaining { resolvedUsed = max(0, l - r) }

        guard let finalLimit = limit, finalLimit > 0 else { return nil }
        let isDollars = ["used_dollars", "limit_dollars", "remaining_dollars"]
            .contains { number(dict[$0]) != nil }
        let unit = (dict["unit"] as? String) ?? (dict["units"] as? String)
            ?? (dict["currency"] as? String) ?? (isDollars ? "USD" : nil)
        return (used: resolvedUsed ?? 0, limit: finalLimit, unit: unit)
    }

    private static func firstNumber(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for k in keys {
            if let v = number(dict[k]) { return v }
        }
        return nil
    }

    private static func number(_ any: Any?) -> Double? {
        switch any {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func extractResetDate(_ dict: [String: Any]) -> Date? {
        let candidates = ["resets_at", "reset_at", "resetAt", "resetsAt",
                          "renews_at", "period_end", "end_date"]
        for key in candidates {
            if let s = dict[key] as? String, let d = parseISO8601(s) { return d }
            if let n = number(dict[key]), n > 1_000_000_000 {
                // Epoch seconds (or milliseconds for very large values).
                return Date(timeIntervalSince1970: n > 100_000_000_000 ? n / 1000 : n)
            }
        }
        return nil
    }

    static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
