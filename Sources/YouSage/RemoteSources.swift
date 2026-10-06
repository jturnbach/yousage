import Foundation

/// One event as served by `Server/yousage_server.py` at `/yousage/v1/usage`.
struct RemoteUsageEvent: Decodable, Sendable {
    let id: String
    let ts: String
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
}

struct RemoteUsagePayload: Decodable, Sendable {
    struct Account: Decodable, Sendable {
        let accountUuid: String?
        let organizationUuid: String?
    }

    let version: Int
    let host: String
    let account: Account
    let events: [RemoteUsageEvent]
}

/// What Settings shows for one discovered server.
struct RemoteSourceStatus: Sendable, Equatable, Identifiable {
    enum State: Sendable, Equatable {
        /// Merged into the token tracker.
        case ok
        /// Reachable, but waiting for claude.ai to say which account this Mac uses.
        case waitingForAccount
        /// Reachable, but signed in to a different Claude organization. Ignored.
        case accountMismatch
        case failed(String)
    }

    /// The server's tailnet DNS name, e.g. `tserver.tail1234.ts.net`.
    let id: String
    /// The host name the server reports about itself, e.g. `TServer`.
    var name: String
    var state: State
    var eventCount: Int
    var lastSuccess: Date?

    var stateText: String {
        switch state {
        case .ok:                return "Counted · \(eventCount) requests held"
        case .waitingForAccount: return "Found · waiting for your claude.ai account"
        case .accountMismatch:   return "Signed in to a different Claude organization · not counted"
        case .failed(let why):   return "Unreachable · \(why)"
        }
    }
}

/// Finds machines on the tailnet that serve YouSage usage and feeds their
/// events into `TokenTracker`.
///
/// Discovery needs no configuration: `tailscale status --json` lists the
/// tailnet's devices, and every online peer tagged `tag:server` is probed at
/// `https://<peer>/yousage/v1/usage`. Whatever answers with a usage payload is
/// a source. The list is cached (and persisted, so a relaunch starts with it)
/// and rebuilt hourly, or sooner after a failure. Without Tailscale this does
/// nothing at all.
///
/// A source's events are merged only when its Claude account belongs to the
/// same organization this Mac reads from claude.ai; tokens billed to someone
/// else's limits would make the windows meaningless.
actor RemoteSources {
    static let shared = RemoteSources()

    private static let tag = "tag:server"
    private static let path = "/yousage/v1/usage"
    private static let hostsKey = "YouSage.remoteSourceHosts"
    private static let rediscoverEvery: TimeInterval = 3600
    /// Floor between discoveries, so a server that's down doesn't make every
    /// refresh spawn the Tailscale CLI.
    private static let rediscoverFloor: TimeInterval = 300
    private static let fetchEvery: TimeInterval = 30
    /// Incremental fetches ask for events since the newest one held, minus this
    /// overlap, to catch turns that were written late. Overlap is free: events
    /// are upserted by id.
    private static let sinceOverlap: TimeInterval = 15 * 60

    private let session: URLSession
    private var hosts: [String]
    private var lastDiscovery: Date?
    private var needsDiscovery = false
    private var statuses: [String: RemoteSourceStatus] = [:]
    private var lastFetch: [String: Date] = [:]
    /// The claude.ai organization each source was last checked against. A
    /// change (typically: unknown → known at launch) makes the source due.
    private var fetchedOrg: [String: String?] = [:]
    /// Newest event timestamp merged per source; nil means the next fetch is full.
    private var newest: [String: Date] = [:]

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.timeoutIntervalForRequest = 5
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
        hosts = UserDefaults.standard.stringArray(forKey: Self.hostsKey) ?? []
    }

    /// Discovers (when due) and fetches (when due). Returns the statuses and
    /// whether any events changed, so the caller knows to rebuild its report.
    func refresh(orgUUID: String?, forceDiscovery: Bool = false) async -> (statuses: [RemoteSourceStatus], changed: Bool) {
        var changed = false
        let org = orgUUID?.lowercased()

        if forceDiscovery || isDiscoveryDue() {
            changed = await discover(org: org) || changed
        }

        let now = Date()
        for host in hosts {
            let sameOrg = fetchedOrg[host] == .some(org)
            if sameOrg, let last = lastFetch[host], now.timeIntervalSince(last) < Self.fetchEvery { continue }
            changed = await fetch(host: host, org: org, since: sameOrg ? newest[host] : nil) || changed
        }
        return (sortedStatuses(), changed)
    }

    /// Forgets every source's events and status (remote sources switched off).
    /// The host list stays cached for when they're switched back on.
    func reset() async {
        await TokenTracker.shared.removeAllRemote()
        statuses.removeAll()
        lastFetch.removeAll()
        fetchedOrg.removeAll()
        newest.removeAll()
        lastDiscovery = nil
        needsDiscovery = false
    }

    private func sortedStatuses() -> [RemoteSourceStatus] {
        hosts.compactMap { statuses[$0] }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func isDiscoveryDue() -> Bool {
        guard let last = lastDiscovery else { return true }
        let age = Date().timeIntervalSince(last)
        if needsDiscovery { return age >= Self.rediscoverFloor }
        return age >= Self.rediscoverEvery
    }

    // MARK: - Discovery

    /// Rebuilds the host list from Tailscale. Returns true when events changed.
    private func discover(org: String?) async -> Bool {
        lastDiscovery = Date()
        needsDiscovery = false

        // No CLI, Tailscale stopped, or logged out: keep whatever was found
        // before and try again later. Never an error.
        guard let data = await Self.tailscaleStatus(),
              let candidates = Self.taggedPeers(statusJSON: data)
        else { return false }

        var found: [String] = []
        var changed = false
        for peer in candidates {
            let host = peer.host
            let known = hosts.contains(host)
            guard peer.online else {
                // A known server that's briefly offline keeps its events.
                if known {
                    found.append(host)
                    var status = statuses[host] ?? RemoteSourceStatus(
                        id: host, name: Self.shortName(host), state: .ok, eventCount: 0)
                    status.state = .failed("offline")
                    statuses[host] = status
                    needsDiscovery = true
                }
                continue
            }
            // A probe is a full fetch; it seeds the source's events directly.
            // A server already known stays a source through a failed probe
            // (it shows as unreachable and is retried); an unknown one that
            // doesn't answer simply isn't a source.
            if await fetch(host: host, org: org, since: nil, probing: !known) {
                changed = true
            }
            if known || statuses[host] != nil { found.append(host) }
        }

        // Gone from the tailnet or no longer tagged: drop it and its events.
        for gone in hosts where !found.contains(gone) {
            await TokenTracker.shared.removeRemote(source: gone)
            statuses[gone] = nil
            lastFetch[gone] = nil
            fetchedOrg[gone] = nil
            newest[gone] = nil
            changed = true
        }
        hosts = found
        UserDefaults.standard.set(found, forKey: Self.hostsKey)
        return changed
    }

    struct TaggedPeer: Equatable {
        /// DNS name without the trailing dot, lowercased.
        let host: String
        let online: Bool
    }

    /// Peers carrying `tag:server`, sorted by name, or nil when the output
    /// isn't a running Tailscale's status.
    static func taggedPeers(statusJSON data: Data) -> [TaggedPeer]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let state = obj["BackendState"] as? String, state != "Running" { return nil }
        guard let peers = obj["Peer"] as? [String: Any] else { return [] }
        var out: [TaggedPeer] = []
        for case let peer as [String: Any] in peers.values {
            guard let tags = peer["Tags"] as? [String], tags.contains(tag),
                  var dns = peer["DNSName"] as? String
            else { continue }
            if dns.hasSuffix(".") { dns.removeLast() }
            guard !dns.isEmpty else { continue }
            out.append(TaggedPeer(host: dns.lowercased(), online: peer["Online"] as? Bool == true))
        }
        return out.sorted { $0.host < $1.host }
    }

    private static let tailscaleCandidates = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
    ]

    /// The Tailscale CLI: the app bundle's binary first, then `tailscale` on
    /// PATH. A menu bar app's PATH is minimal, so Homebrew's usual locations
    /// are listed explicitly.
    private static func tailscaleExecutable() -> URL? {
        let fm = FileManager.default
        var paths = tailscaleCandidates
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for dir in envPath.split(separator: ":") {
            paths.append("\(dir)/tailscale")
        }
        return paths.first { fm.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    /// Output of `tailscale status --json`, or nil on any failure. Killed after
    /// five seconds so a wedged CLI can't hold up the token tracker.
    private static func tailscaleStatus() async -> Data? {
        guard let exe = tailscaleExecutable() else { return nil }
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = exe
                process.arguments = ["status", "--json"]
                let out = Pipe()
                process.standardOutput = out
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    cont.resume(returning: nil)
                    return
                }
                let watchdog = DispatchWorkItem {
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 5, execute: watchdog)
                // Drain before waiting: a full pipe would block the child forever.
                let data = out.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                cont.resume(returning: process.terminationStatus == 0 ? data : nil)
            }
        }
    }

    // MARK: - Fetching

    /// Fetches one source and merges or rejects its events. Returns true when
    /// the tracker's remote events changed. While probing, a host that doesn't
    /// answer with a usage payload is simply not a source: no status is kept.
    @discardableResult
    private func fetch(host: String, org: String?, since: Date?, probing: Bool = false) async -> Bool {
        var status = statuses[host]
            ?? RemoteSourceStatus(id: host, name: Self.shortName(host), state: .ok, eventCount: 0)
        let payload: RemoteUsagePayload
        do {
            payload = try await get(host: host, since: since)
        } catch {
            if !probing {
                status.state = .failed(Self.describe(error))
                statuses[host] = status
                needsDiscovery = true
            }
            return false
        }
        lastFetch[host] = Date()
        fetchedOrg[host] = .some(org)
        if !payload.host.isEmpty { status.name = payload.host }
        status.lastSuccess = Date()

        guard let org else {
            // claude.ai hasn't answered yet; check again once it has.
            status.state = .waitingForAccount
            statuses[host] = status
            newest[host] = nil
            return false
        }
        guard payload.account.organizationUuid?.lowercased() == org else {
            status.state = .accountMismatch
            status.eventCount = 0
            statuses[host] = status
            newest[host] = nil
            await TokenTracker.shared.removeRemote(source: host)
            return true
        }

        status.eventCount = await TokenTracker.shared.mergeRemote(
            source: host, name: status.name, events: payload.events, replace: since == nil)
        if let latest = Self.newestDate(payload.events), latest > (newest[host] ?? .distantPast) {
            newest[host] = latest
        } else if since == nil {
            newest[host] = nil
        }
        status.state = .ok
        statuses[host] = status
        return since == nil || !payload.events.isEmpty
    }

    /// `tserver.tail1234.ts.net` → `tserver`, until the server names itself.
    private static func shortName(_ host: String) -> String {
        host.split(separator: ".").first.map(String.init) ?? host
    }

    private func get(host: String, since: Date?) async throws -> RemoteUsagePayload {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = Self.path
        if let since {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            components.queryItems = [URLQueryItem(name: "since",
                                                  value: f.string(from: since.addingTimeInterval(-Self.sinceOverlap)))]
        }
        guard let url = components.url else { throw URLError(.badURL) }
        var req = URLRequest(url: url)
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else { throw RemoteError.http(http.statusCode) }
        let payload = try JSONDecoder().decode(RemoteUsagePayload.self, from: data)
        guard payload.version == 1 else { throw RemoteError.unsupportedVersion(payload.version) }
        return payload
    }

    private enum RemoteError: Error {
        case http(Int)
        case unsupportedVersion(Int)
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case RemoteError.http(403):                 return "access denied (HTTP 403)"
        case RemoteError.http(let code):            return "HTTP \(code)"
        case RemoteError.unsupportedVersion(let v): return "unsupported version \(v)"
        case is DecodingError:                      return "unexpected response"
        case let url as URLError where url.code == .timedOut: return "timed out"
        default:                                    return error.localizedDescription
        }
    }

    private static func parse(_ ts: String) -> Date? {
        ClaudeClient.parseISO8601(ts)
    }

    private static func newestDate(_ events: [RemoteUsageEvent]) -> Date? {
        // The server sends events oldest first; check the tail before scanning.
        if let last = events.last, let date = parse(last.ts) { return date }
        return events.compactMap { parse($0.ts) }.max()
    }
}
