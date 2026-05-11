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
    }

    func fetchOrganizations(sessionKey: String) async throws -> [Organization] {
        let url = URL(string: "https://claude.ai/api/organizations")!
        let data = try await get(url, sessionKey: sessionKey)
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw ClaudeError.decoding("organizations: expected array")
        }
        return arr.compactMap { dict -> Organization? in
            guard let uuid = dict["uuid"] as? String else { return nil }
            let name = dict["name"] as? String
            let plan = (dict["settings"] as? [String: Any])?["claude_pro_subscription"] as? String
                ?? dict["organization_type"] as? String
                ?? (dict["capabilities"] as? [String]).flatMap { caps in
                    caps.first(where: { $0.hasPrefix("claude_pro") || $0.hasPrefix("claude_max") || $0.hasPrefix("raven") })
                }
            return Organization(uuid: uuid, name: name, planType: plan)
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

    // Maps the claude.ai /usage payload to UsageSection list. Tolerant to the
    // `utilization` vs `utilization_pct` and `resets_at` vs `reset_at` variants
    // documented across community reverse-engineering efforts.
    static func parseSections(data: Data) throws -> [UsageSection] {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClaudeError.decoding("expected top-level object")
        }

        struct Mapping {
            let key: String
            let title: String
            let kind: UsageSection.Kind
            let infoNote: String?
        }
        let mappings: [Mapping] = [
            .init(key: "five_hour",          title: "Current session",       kind: .session, infoNote: nil),
            .init(key: "seven_day",          title: "All models",            kind: .weekly,  infoNote: nil),
            .init(key: "seven_day_sonnet",   title: "Sonnet only",           kind: .weekly,  infoNote: nil),
            .init(key: "seven_day_opus",     title: "Claude Design",         kind: .weekly,  infoNote: "Opus / Claude Design weekly limit"),
            .init(key: "seven_day_oauth_apps", title: "OAuth apps",          kind: .weekly,  infoNote: "Claude Code & other OAuth-connected apps"),
        ]

        var out: [UsageSection] = []
        for m in mappings {
            guard let dict = obj[m.key] as? [String: Any] else { continue }
            let pct = extractPercent(dict)
            let resetDate = extractResetDate(dict)
            out.append(UsageSection(
                id: m.key,
                title: m.title,
                percent: pct,
                resetsAt: resetDate,
                kind: m.kind,
                infoNote: m.infoNote
            ))
        }

        // Surface any unknown top-level usage-shaped entries so we don't silently
        // drop new categories Anthropic adds later.
        let knownKeys = Set(mappings.map(\.key))
        for (key, value) in obj {
            guard !knownKeys.contains(key),
                  let dict = value as? [String: Any],
                  dict["utilization"] != nil || dict["utilization_pct"] != nil else { continue }
            let pct = extractPercent(dict)
            let resetDate = extractResetDate(dict)
            let prettyTitle = key.replacingOccurrences(of: "_", with: " ").capitalized
            out.append(UsageSection(
                id: key,
                title: prettyTitle,
                percent: pct,
                resetsAt: resetDate,
                kind: key.hasPrefix("five") ? .session : .weekly,
                infoNote: "Unknown category — reported as-is"
            ))
        }

        return out
    }

    private static func extractPercent(_ dict: [String: Any]) -> Double {
        if let d = dict["utilization"] as? Double { return d }
        if let i = dict["utilization"] as? Int { return Double(i) }
        if let d = dict["utilization_pct"] as? Double { return d }
        if let i = dict["utilization_pct"] as? Int { return Double(i) }
        if let n = dict["utilization"] as? NSNumber { return n.doubleValue }
        if let n = dict["utilization_pct"] as? NSNumber { return n.doubleValue }
        return 0
    }

    private static func extractResetDate(_ dict: [String: Any]) -> Date? {
        let candidates = ["resets_at", "reset_at", "resetAt", "resetsAt"]
        for key in candidates {
            if let s = dict[key] as? String, let d = parseISO8601(s) { return d }
        }
        return nil
    }

    private static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
