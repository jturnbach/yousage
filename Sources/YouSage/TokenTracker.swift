import Foundation

/// Sums token usage from Claude Code's local transcripts.
///
/// claude.ai's `/usage` endpoint reports how *full* each limit is, never how
/// many tokens produced that number. Claude Code writes every assistant turn —
/// including its exact `usage` block — to `~/.claude/projects/**/*.jsonl`, so
/// that's where the token counts come from.
///
/// Scope worth being honest about: this sees Claude Code on *this Mac*, plus
/// any remote source (another machine running `Server/yousage_server.py`) that
/// `RemoteSources` feeds in through `mergeRemote`. Conversations in the Claude
/// desktop app or on claude.ai consume the same limits but leave no transcript
/// anywhere we can read. Treat these numbers as "tokens Claude Code spent", not
/// "tokens behind the percentages above".
///
/// Rescans are incremental: each file is read from where the last scan stopped,
/// and files untouched within the retention window are never opened.
actor TokenTracker {
    static let shared = TokenTracker()

    /// Deep enough for every window the details window can be paged back to —
    /// `UsageRange.historyDays` — *and* the equal-length window behind the oldest
    /// of them that its trend chips compare against, plus a day of slack so the
    /// oldest bucket is always whole. Claude Code prunes its own transcripts long
    /// before this, so in practice the disk runs out of history before we run out
    /// of retention — which is why an empty prior period is reported as "no
    /// comparison" rather than as a fall to zero.
    private static let retention: TimeInterval = TimeInterval(UsageRange.historyDays + 1) * 24 * 3600
    private static let sessionLength: TimeInterval = 5 * 3600
    /// Ceiling on bytes ingested per scan, so a pathological backlog can't stall
    /// a refresh. Whatever is missed is picked up on the next pass.
    private static let byteBudgetPerScan = 96 * 1024 * 1024

    private struct Cursor {
        var offset: UInt64
        /// Guards against a transcript being replaced at the same path: a new
        /// creation date means the old byte offset is meaningless.
        var created: Date
    }

    private struct Event {
        let id: String
        let date: Date
        let model: String
        let totals: TokenTotals
        /// nil for this Mac's own transcripts, else the remote source's id.
        var source: String? = nil
    }

    /// Events pulled from one remote source, keyed by event id so a fetch
    /// overlapping an earlier one replaces rather than adds.
    private struct RemoteStore {
        var name: String
        var events: [String: Event]
    }

    private let root: URL
    private var cursors: [String: Cursor] = [:]
    private var events: [Event] = []
    private var seen: Set<String> = []
    private var filesScanned = 0
    private var remote: [String: RemoteStore] = [:]

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
    }

    var isAvailable: Bool {
        FileManager.default.fileExists(atPath: root.path)
    }

    /// Scans for new transcript lines and summarizes the two windows.
    ///
    /// `sessionResetsAt` and `weekResetsAt` come from claude.ai's own limits. When
    /// present the windows are pinned to them, so the token counts line up exactly
    /// with the percentages shown above them. Without them the session window is
    /// inferred from local activity the way Claude Code blocks it: the first
    /// message of a block, floored to the hour, plus five hours.
    func report(sessionResetsAt: Date?,
                weekResetsAt: Date?,
                now: Date = Date(),
                calendar: Calendar = .current) -> TokenReport? {
        guard let events = currentEvents() else { return nil }

        var sessionStart: Date?
        var authoritative = false
        if let resets = sessionResetsAt, resets > now {
            sessionStart = resets.addingTimeInterval(-Self.sessionLength)
            authoritative = true
        } else {
            sessionStart = inferredBlockStart(events, now: now)
        }

        let weekStart: Date? = {
            if let resets = weekResetsAt, resets > now {
                return resets.addingTimeInterval(-7 * 24 * 3600)
            }
            return now.addingTimeInterval(-7 * 24 * 3600)
        }()

        let sessionEvents = sessionStart.map { start in
            events.filter { $0.date >= start && $0.date <= now }
        } ?? []

        let weekEvents = weekStart.map { start in
            events.filter { $0.date >= start && $0.date <= now }
        } ?? []

        // Local midnight, through the machine's own calendar — the same boundary
        // the details window draws its days on, so the popover's "Today" and the
        // grid's last cell are the same number.
        let dayStart = calendar.startOfDay(for: now)
        let dayEvents = events.filter { $0.date >= dayStart && $0.date <= now }

        return TokenReport(
            session: sessionEvents.reduce(TokenTotals()) { $0 + $1.totals },
            sessionStart: sessionEvents.isEmpty ? nil : sessionStart,
            sessionIsAuthoritative: authoritative,
            sessionCost: costEstimate(sessionEvents),
            today: dayEvents.reduce(TokenTotals()) { $0 + $1.totals },
            todayCost: costEstimate(dayEvents),
            week: weekEvents.reduce(TokenTotals()) { $0 + $1.totals },
            weekStart: weekStart,
            weekCost: costEstimate(weekEvents),
            models: modelSplit(sessionEvents),
            sources: sourceSplit(session: sessionEvents, week: weekEvents),
            filesScanned: filesScanned,
            generatedAt: now
        )
    }

    /// Calendar days of usage for the details window. Deliberately a different
    /// window from `report`'s rolling week: a bar labelled "Fri" must be Friday,
    /// so the two totals will not agree, and each is labelled with the window it
    /// describes.
    func breakdown(range: UsageRange = .week,
                   offset: Int = 0,
                   now: Date = Date(),
                   calendar: Calendar = .current) -> UsageBreakdown? {
        guard let events = currentEvents() else { return nil }
        let usage = events.map { UsageEvent(date: $0.date, model: $0.model, totals: $0.totals) }
        return UsageBreakdown.make(from: usage, now: now, calendar: calendar,
                                   range: range, offset: offset)
    }

    /// Every retained day, for the activity grid. Separate from `breakdown`
    /// because it answers a different question: the breakdown is the window the
    /// user paged to, this is all of the history there is, whatever they paged to.
    /// Both read the same events, remote ones included, so the two can never disagree.
    func history(now: Date = Date(), calendar: Calendar = .current) -> UsageHistory? {
        guard let events = currentEvents() else { return nil }
        let usage = events.map { UsageEvent(date: $0.date, model: $0.model, totals: $0.totals) }
        return UsageHistory.make(from: usage, now: now, calendar: calendar)
    }

    // MARK: - Remote sources

    /// Stores events served by a remote source. `replace` discards what was
    /// held for the source first (a full fetch); otherwise events are upserted
    /// by id (an incremental `since` fetch). Returns how many events are now
    /// held for the source.
    @discardableResult
    func mergeRemote(source: String, name: String, events incoming: [RemoteUsageEvent], replace: Bool) -> Int {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        var store = (replace ? nil : remote[source]) ?? RemoteStore(name: name, events: [:])
        store.name = name
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        for r in incoming {
            // The server already applies parse()'s filters; repeat the cheap
            // ones so a malformed payload can't inject junk.
            guard !r.id.isEmpty, !r.model.hasPrefix("<"),
                  let date = formatter.date(from: r.ts) ?? ClaudeClient.parseISO8601(r.ts),
                  date >= cutoff
            else { continue }
            let totals = TokenTotals(
                input: max(0, r.input),
                output: max(0, r.output),
                cacheCreation: max(0, r.cacheWrite),
                cacheRead: max(0, r.cacheRead),
                messages: 1
            )
            guard totals.total > 0 else { continue }
            store.events[r.id] = Event(id: r.id, date: date, model: r.model, totals: totals, source: source)
        }
        remote[source] = store
        return store.events.count
    }

    func removeRemote(source: String) {
        remote[source] = nil
    }

    func removeAllRemote() {
        remote.removeAll()
    }

    /// Scans this Mac's transcripts, when there are any, and returns every event
    /// the windows should count. nil when there is neither a transcript folder
    /// nor a remote source, which is the "nothing to read" the views show.
    private func currentEvents() -> [Event]? {
        let local = isAvailable
        guard local || !remote.isEmpty else { return nil }
        if local { scan() } else { prune() }
        return allEvents()
    }

    /// Local events plus every remote source's, each API call counted once: an
    /// id this Mac already holds wins over a remote copy, and among remotes the
    /// first source in id order wins.
    private func allEvents() -> [Event] {
        guard !remote.isEmpty else { return events }
        var out = events
        var ids = seen
        for key in remote.keys.sorted() {
            guard let store = remote[key] else { continue }
            for event in store.events.values where !ids.contains(event.id) {
                out.append(event)
                ids.insert(event.id)
            }
        }
        return out
    }

    /// This Mac first, then each remote source by name. Empty when no remote
    /// source is attached, so a lone Mac shows no split.
    private func sourceSplit(session: [Event], week: [Event]) -> [SourceTokens] {
        guard !remote.isEmpty else { return [] }
        func sum(_ events: [Event], _ source: String?) -> TokenTotals {
            events.reduce(TokenTotals()) { acc, e in e.source == source ? acc + e.totals : acc }
        }
        var out = [SourceTokens(id: "local", name: "This Mac", isLocal: true,
                                session: sum(session, nil), week: sum(week, nil))]
        let remotes = remote.sorted {
            $0.value.name.localizedCaseInsensitiveCompare($1.value.name) == .orderedAscending
        }
        for (key, store) in remotes {
            out.append(SourceTokens(id: key, name: store.name, isLocal: false,
                                    session: sum(session, key), week: sum(week, key)))
        }
        return out
    }

    private func modelSplit(_ events: [Event]) -> [ModelTokens] {
        var byModel: [String: TokenTotals] = [:]
        for e in events {
            byModel[e.model, default: TokenTotals()] = byModel[e.model, default: TokenTotals()] + e.totals
        }
        return byModel
            .map { ModelTokens(model: $0.key, totals: $0.value) }
            .sorted { $0.totals.total > $1.totals.total }
    }

    /// Prices a window event-by-event, because the rate depends on which model
    /// produced each turn. Models missing from the table are collected rather
    /// than counted as zero.
    private func costEstimate(_ events: [Event]) -> CostEstimate {
        var estimate = CostEstimate()
        var unpriced: Set<String> = []
        for event in events {
            if let dollars = Pricing.cost(event.totals, model: event.model) {
                estimate.amount += dollars
            } else {
                unpriced.insert(event.model)
            }
        }
        estimate.unpricedModels = unpriced.sorted()
        return estimate
    }

    /// Claude Code groups activity into 5-hour blocks that begin at the top of the
    /// hour containing the block's first message. Replay the events to find the
    /// block currently in progress; nil when the last block has already expired.
    private func inferredBlockStart(_ events: [Event], now: Date) -> Date? {
        let sorted = events.map(\.date).sorted()
        guard let first = sorted.first else { return nil }

        var start = floorToHour(first)
        for date in sorted where date.timeIntervalSince(start) >= Self.sessionLength {
            start = floorToHour(date)
        }
        guard now.timeIntervalSince(start) < Self.sessionLength else { return nil }
        return start
    }

    private func floorToHour(_ date: Date) -> Date {
        Calendar.current.date(
            from: Calendar.current.dateComponents([.year, .month, .day, .hour], from: date)
        ) ?? date
    }

    // MARK: - Scanning

    private func scan() {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .creationDateKey]
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                         options: [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return }

        let cutoff = Date().addingTimeInterval(-Self.retention)
        var budget = Self.byteBudgetPerScan
        var count = 0

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl" else { continue }
            count += 1

            let values = try? url.resourceValues(forKeys: Set(keys))
            let modified = values?.contentModificationDate ?? .distantPast
            let created = values?.creationDate ?? .distantPast
            let size = UInt64(values?.fileSize ?? 0)
            let path = url.path

            var cursor: Cursor
            if let existing = cursors[path], existing.created == created, size >= existing.offset {
                cursor = existing
            } else if cursors[path] == nil && modified < cutoff {
                // Never read, and untouched for longer than we retain. Nothing in
                // it can land in a window. Mark it consumed so later appends are
                // still picked up without ever reading its history.
                cursors[path] = Cursor(offset: size, created: created)
                continue
            } else {
                // New file, or one replaced/truncated under us: read from the top.
                cursor = Cursor(offset: 0, created: created)
            }

            guard size > cursor.offset, budget > 0 else {
                cursors[path] = cursor
                continue
            }
            budget -= ingest(url: url, cursor: &cursor, budget: budget)
            cursors[path] = cursor
        }

        filesScanned = count
        prune()
    }

    /// Reads the bytes appended since `cursor.offset`, stopping at the last
    /// complete line so a half-written record is re-read next scan rather than
    /// dropped. Returns bytes consumed.
    private func ingest(url: URL, cursor: inout Cursor, budget: Int) -> Int {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        do { try handle.seek(toOffset: cursor.offset) } catch { return 0 }
        guard let data = try? handle.read(upToCount: budget), !data.isEmpty else { return 0 }

        // Trim to the final newline; the remainder is an incomplete line.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return 0 }
        let complete = data[data.startIndex...lastNewline]

        for line in complete.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let event = parse(line: Data(line)) {
                events.append(event)
                seen.insert(event.id)
            }
        }

        cursor.offset += UInt64(complete.count)
        return complete.count
    }

    private static let usageMarker = Data("\"usage\"".utf8)

    private func parse(line: Data) -> Event? {
        // Most lines are user turns, tool results, or metadata. Skip the JSON
        // decode entirely unless a usage block is present.
        guard line.range(of: Self.usageMarker) != nil else { return nil }

        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "assistant",
              let message = obj["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any]
        else { return nil }

        // Claude Code writes placeholder turns (model `<synthetic>`) that never
        // hit the API and carry no real usage.
        let model = (message["model"] as? String) ?? "unknown"
        guard !model.hasPrefix("<") else { return nil }

        // The same turn is written to every transcript that replays it (resumed
        // sessions, sidechains). requestId is per API call and unique; message id
        // is the fallback.
        guard let id = (obj["requestId"] as? String) ?? (message["id"] as? String),
              !seen.contains(id)
        else { return nil }

        guard let stamp = obj["timestamp"] as? String,
              let date = ClaudeClient.parseISO8601(stamp)
        else { return nil }

        let totals = TokenTotals(
            input: int(usage["input_tokens"]),
            output: int(usage["output_tokens"]),
            cacheCreation: int(usage["cache_creation_input_tokens"]),
            cacheRead: int(usage["cache_read_input_tokens"]),
            messages: 1
        )
        guard totals.total > 0 else { return nil }

        return Event(id: id, date: date, model: model, totals: totals)
    }

    private func int(_ any: Any?) -> Int {
        switch any {
        case let i as Int: return i
        case let n as NSNumber: return n.intValue
        case let d as Double: return Int(d)
        default: return 0
        }
    }

    /// Drop events (and their dedupe keys) that have aged out of every window.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-Self.retention)
        remote = remote.mapValues { store in
            var kept = store
            kept.events = store.events.filter { $0.value.date >= cutoff }
            return kept
        }
        guard events.contains(where: { $0.date < cutoff }) else { return }
        var kept: [Event] = []
        kept.reserveCapacity(events.count)
        var keptIDs = Set<String>()
        for event in events where event.date >= cutoff {
            kept.append(event)
            keptIDs.insert(event.id)
        }
        events = kept
        seen = keptIDs
    }
}
