import Foundation
import SwiftUI
import AppKit

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    @Published private(set) var snapshot: UsageSnapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    @Published private(set) var lastFetched: Date?
    @Published private(set) var sessionKey: String?
    @Published private(set) var orgName: String?
    @Published private(set) var orgUUID: String?
    @Published private(set) var consecutiveFailures: Int = 0
    @Published private(set) var menuBarMetric: MenuBarMetric = .highest
    @Published private(set) var planMode: PlanMode = .auto
    @Published private(set) var tokenTrackingEnabled: Bool = true
    @Published private(set) var tokenReport: TokenReport?
    @Published private(set) var usageBreakdown: UsageBreakdown?
    /// Every retained day, for the activity grid. Held apart from the breakdown
    /// because it does not move with the range picker — paging the window back
    /// re-buckets the charts above the grid, never the grid itself.
    @Published private(set) var usageHistory: UsageHistory?
    /// Range the details window is showing. Not persisted: the design lands on 7D,
    /// and a window you opened yesterday on 90D should not silently cost you a
    /// 90-day rescan the next time you glance at it.
    @Published private(set) var usageRange: UsageRange = .week
    /// How many whole periods back the details window is paged; 0 is the window
    /// the clock is inside. Not persisted, for the same reason the range is not.
    @Published private(set) var usageOffset: Int = 0
    /// Light, dark, or whatever macOS is doing. Persisted, unlike the range and
    /// the offset: an appearance is a preference, not a place you navigated to.
    @Published private(set) var appearance: Appearance = .default
    /// Optional monthly ceiling for the API-list-cost projection, in dollars. nil
    /// hides the budget card entirely — an unset budget is not a budget of zero.
    @Published private(set) var monthlyBudget: Double?
    /// False until the first transcript scan of the current session finishes.
    /// Distinguishes "still reading" from "there is nothing to read" — a nil
    /// `usageBreakdown` alone cannot tell those apart.
    @Published private(set) var hasScannedTokens = false
    @Published private(set) var remoteSourcesEnabled: Bool = true
    /// Servers found on the tailnet and how each fared on its last fetch.
    @Published private(set) var remoteSources: [RemoteSourceStatus] = []
    /// Raw status + body of the most recent failed /usage attempt, surfaced in
    /// the Settings → Debug panel to diagnose plan-specific endpoint issues.
    @Published private(set) var lastErrorDetail: String?

    private var lastFailStatus: Int?
    /// Whether the signed-in org advertises enterprise capabilities. Only used
    /// to break ties when the usage payload alone is inconclusive.
    private var orgLooksEnterprise = false

    private let client = ClaudeClient()
    private var pollTask: Task<Void, Never>?
    private var inflight: Task<Void, Never>?
    private var tokenScan: Task<Void, Never>?
    private var lastTokenScan: Date?
    /// A forced token refresh requested while a scan was in flight; run once
    /// that scan finishes rather than dropped.
    private var tokenRefreshPending = false
    private var remoteRediscoverPending = false
    private var isPopoverOpen = false

    private static let orgUUIDKey = "YouSage.orgUUID"
    private static let orgNameKey = "YouSage.orgName"
    private static let metricKey  = "YouSage.menuBarMetric"
    private static let planKey    = "YouSage.planMode"
    private static let tokensKey  = "YouSage.tokenTracking"
    private static let budgetKey  = "YouSage.monthlyBudget"
    private static let appearanceKey = "YouSage.appearance"
    private static let remoteKey  = "YouSage.remoteSources"

    private init() {
        sessionKey = Keychain.read(account: "sessionKey")
        orgUUID = UserDefaults.standard.string(forKey: Self.orgUUIDKey)
        orgName = UserDefaults.standard.string(forKey: Self.orgNameKey)
        if let raw = UserDefaults.standard.string(forKey: Self.metricKey),
           let m = MenuBarMetric(rawValue: raw) {
            menuBarMetric = m
        }
        if let raw = UserDefaults.standard.string(forKey: Self.planKey),
           let p = PlanMode(rawValue: raw) {
            planMode = p
        }
        if UserDefaults.standard.object(forKey: Self.tokensKey) != nil {
            tokenTrackingEnabled = UserDefaults.standard.bool(forKey: Self.tokensKey)
        }
        if UserDefaults.standard.object(forKey: Self.budgetKey) != nil {
            let stored = UserDefaults.standard.double(forKey: Self.budgetKey)
            monthlyBudget = stored > 0 ? stored : nil
        }
        appearance = Appearance(stored: UserDefaults.standard.string(forKey: Self.appearanceKey))
        // `NSApp` is not up yet inside the singleton's initializer; the first
        // paint has to wait for the run loop either way.
        DispatchQueue.main.async { [appearance] in Self.apply(appearance) }
        if UserDefaults.standard.object(forKey: Self.remoteKey) != nil {
            remoteSourcesEnabled = UserDefaults.standard.bool(forKey: Self.remoteKey)
        }

        registerWorkspaceObservers()

        refreshTokens()
        if sessionKey?.isEmpty == false {
            refresh()
            restartPoll()
        }
    }

    var isConfigured: Bool { !(sessionKey ?? "").isEmpty }

    var statusSummary: String {
        if !isConfigured { return "Not connected" }
        if let err = lastError, snapshot == nil { return err }
        if let last = lastFetched {
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "Updated \(f.localizedString(for: last, relativeTo: Date()))"
        }
        return "Loading…"
    }

    // MARK: - Plan

    /// What the account actually looks like, read off the usage payload. An
    /// allotment (an absolute used-of-granted amount) only ever appears on
    /// seat/credit plans; bare utilization percentages only on subscriptions.
    var detectedPlan: DetectedPlan {
        guard let sections = snapshot?.sections, !sections.isEmpty else {
            return orgLooksEnterprise ? .enterprise : .unknown
        }
        if sections.contains(where: { $0.kind == .allotment }) { return .enterprise }
        if sections.contains(where: { $0.kind == .session || $0.kind == .weekly }) { return .subscription }
        return orgLooksEnterprise ? .enterprise : .unknown
    }

    /// The plan YouSage presents: the detected one unless the user overrode it.
    var effectivePlan: DetectedPlan {
        switch planMode {
        case .auto:         return detectedPlan
        case .subscription: return .subscription
        case .enterprise:   return .enterprise
        }
    }

    /// Sections to show, ordered for the active plan. Only the subscription view
    /// hides anything — allotments are meaningless there. Enterprise accounts
    /// still have 5-hour and weekly limits, so those stay visible, just below
    /// the allotments they care about most.
    var visibleSections: [UsageSection] {
        guard let sections = snapshot?.sections else { return [] }
        switch effectivePlan {
        case .subscription:
            return sections.filter { $0.kind != .allotment }
        case .enterprise:
            return sections.sorted { a, b in
                let ao = a.kind == .allotment ? 0 : 1
                let bo = b.kind == .allotment ? 0 : 1
                return ao != bo ? ao < bo : a.rank < b.rank
            }
        case .unknown:
            return sections
        }
    }

    func setPlanMode(_ mode: PlanMode) {
        guard mode != planMode else { return }
        planMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.planKey)
        applyDefaultMetric()
    }

    func setTokenTracking(_ enabled: Bool) {
        guard enabled != tokenTrackingEnabled else { return }
        tokenTrackingEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.tokensKey)
        if enabled {
            refreshTokens(force: true)
        } else {
            // Both are derived from the same transcripts. Clearing one and not
            // the other would leave a stale chart behind a switched-off feature.
            tokenReport = nil
            usageBreakdown = nil
            usageHistory = nil
            // Re-enabling must show "reading…", not "nothing found".
            hasScannedTokens = false
        }
    }

    func setAppearance(_ appearance: Appearance) {
        guard appearance != self.appearance else { return }
        self.appearance = appearance
        UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey)
        Self.apply(appearance)
    }

    /// Set on the application rather than through `preferredColorScheme` on each
    /// root view: this reaches the popover, both windows, and their title bars and
    /// toolbars at once, where the SwiftUI modifier leaves window chrome on the
    /// system setting.
    private static func apply(_ appearance: Appearance) {
        NSApp?.appearance = appearance.appearanceName.map { NSAppearance(named: $0) } ?? nil
    }

    func setUsageRange(_ range: UsageRange) {
        guard range != usageRange else { return }
        usageRange = range
        // Five weeks back is not five months back, so a period count means nothing
        // once the period changes length. Changing the range returns to the present.
        usageOffset = 0
        // The events are already in memory; only the bucketing changes. Force it,
        // or the 5-second coalescing window would swallow a range the user just
        // clicked and leave the old one on screen.
        refreshTokens(force: true)
    }

    /// Pages the details window by whole periods — negative is further back,
    /// positive is towards the present. Clamped, so the buttons that call it can
    /// simply be disabled at the ends rather than guarding the arithmetic.
    func stepUsage(by periods: Int) {
        setUsageOffset(usageOffset - periods)
    }

    func setUsageOffset(_ offset: Int) {
        let clamped = min(max(offset, 0), usageRange.maxOffset)
        guard clamped != usageOffset else { return }
        usageOffset = clamped
        refreshTokens(force: true)
    }

    /// A budget of zero or less is not a budget — it clears the setting instead of
    /// pinning the meter at 100%.
    func setMonthlyBudget(_ dollars: Double?) {
        let value = (dollars ?? 0) > 0 ? dollars : nil
        guard value != monthlyBudget else { return }
        monthlyBudget = value
        if let value {
            UserDefaults.standard.set(value, forKey: Self.budgetKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.budgetKey)
        }
    }

    func setRemoteSources(_ enabled: Bool) {
        guard enabled != remoteSourcesEnabled else { return }
        remoteSourcesEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.remoteKey)
        if enabled {
            refreshTokens(force: true)
        } else {
            remoteSources = []
            Task { [weak self] in
                await RemoteSources.shared.reset()
                self?.refreshTokens(force: true)
            }
        }
    }

    /// Settings → Remote sources → Look again.
    func rediscoverRemoteSources() {
        refreshTokens(force: true, rediscover: true)
    }

    var highestPercent: Double? {
        visibleSections.map(\.percent).max()
    }

    /// Percentage to show in the menu bar, based on the user-selected metric.
    /// Returns nil while there's no snapshot yet (or when the chosen section
    /// is absent from the response).
    var displayPercent: Double? {
        let sections = visibleSections
        guard !sections.isEmpty else { return nil }
        switch menuBarMetric {
        case .highest:
            return sections.map(\.percent).max()
        case .allotment:
            // Highest allotment metric; fall back to overall highest so the
            // menu bar is never blank if naming differs on this plan.
            let allot = sections.filter { $0.kind == .allotment }.map(\.percent).max()
            return allot ?? sections.map(\.percent).max()
        case .session:
            return snapshot?.sessionSection?.percent
        case .weekly:
            return snapshot?.weeklyAllSection?.percent
                ?? sections.first(where: { $0.kind == .weekly })?.percent
        }
    }

    /// True once we've seen at least one enterprise allotment metric, so the UI
    /// can default the menu bar to "Allotted usage".
    var hasAllotmentData: Bool {
        snapshot?.sections.contains { $0.kind == .allotment } ?? false
    }

    func setMenuBarMetric(_ m: MenuBarMetric) {
        guard m != menuBarMetric else { return }
        menuBarMetric = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.metricKey)
    }

    /// Until the user picks a metric explicitly, follow the plan: allotment
    /// plans lead with the allotment, subscriptions with whichever limit is
    /// closest to its cap.
    private func applyDefaultMetric() {
        guard UserDefaults.standard.string(forKey: Self.metricKey) == nil else { return }
        menuBarMetric = (effectivePlan == .enterprise && hasAllotmentData) ? .allotment : .highest
    }

    // MARK: - Auth

    func saveSessionKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        Keychain.write(account: "sessionKey", value: trimmed)
        sessionKey = trimmed
        // Force re-resolving the org since the key changed.
        orgUUID = nil
        orgName = nil
        orgLooksEnterprise = false
        UserDefaults.standard.removeObject(forKey: Self.orgUUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.orgNameKey)
        consecutiveFailures = 0
        lastError = nil
        snapshot = nil
        lastFetched = nil
        refresh()
        restartPoll()
    }

    func clearSessionKey() {
        Keychain.delete(account: "sessionKey")
        sessionKey = nil
        orgUUID = nil
        orgName = nil
        orgLooksEnterprise = false
        snapshot = nil
        lastError = nil
        lastFetched = nil
        consecutiveFailures = 0
        UserDefaults.standard.removeObject(forKey: Self.orgUUIDKey)
        UserDefaults.standard.removeObject(forKey: Self.orgNameKey)
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: - Refresh

    func refresh() {
        refreshTokens()
        guard isConfigured else { return }
        inflight?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    /// Token counts come from local transcripts, so they refresh independently
    /// of the network — they stay correct even while claude.ai is unreachable.
    ///
    /// `force` bypasses the coalescing window, which a fresh snapshot needs: its
    /// reset times redefine the windows even when no new tokens were written.
    ///
    /// Remote sources are fetched after the local report is published: their
    /// discovery runs the Tailscale CLI and probes peers, which can take
    /// seconds, and the local numbers shouldn't wait on it.
    private func refreshTokens(force: Bool = false, rediscover: Bool = false) {
        guard tokenTrackingEnabled else { return }
        guard tokenScan == nil else {
            if force { tokenRefreshPending = true }
            if rediscover { remoteRediscoverPending = true }
            return
        }
        if !force, let last = lastTokenScan, Date().timeIntervalSince(last) < 5 { return }

        let session = snapshot?.sessionSection?.resetsAt
        let week = snapshot?.weeklyAllSection?.resetsAt
        let range = usageRange
        let offset = usageOffset
        let remoteEnabled = remoteSourcesEnabled
        let org = orgUUID
        tokenScan = Task { [weak self] in
            let report = await TokenTracker.shared.report(sessionResetsAt: session, weekResetsAt: week)
            // Same in-memory events, a different window. The second call re-enters
            // `scan()`, which is incremental and finds nothing new to read.
            let breakdown = await TokenTracker.shared.breakdown(range: range, offset: offset)
            // A third pass over the same in-memory events, and the only one whose
            // answer does not depend on the range — but it has to be re-read on
            // every scan all the same, or today's cell would stop filling in.
            let history = await TokenTracker.shared.history()
            await MainActor.run {
                guard let self else { return }
                self.tokenReport = report
                self.usageBreakdown = breakdown
                self.usageHistory = history
                self.hasScannedTokens = true
                self.lastTokenScan = Date()
            }
            if remoteEnabled {
                let result = await RemoteSources.shared.refresh(orgUUID: org, forceDiscovery: rediscover)
                await self?.applyRemote(result.statuses, changed: result.changed)
            }
            await MainActor.run {
                guard let self else { return }
                self.tokenScan = nil
                if self.tokenRefreshPending || self.remoteRediscoverPending {
                    let again = self.remoteRediscoverPending
                    self.tokenRefreshPending = false
                    self.remoteRediscoverPending = false
                    self.refreshTokens(force: true, rediscover: again)
                }
            }
        }
    }

    private func applyRemote(_ statuses: [RemoteSourceStatus], changed: Bool) async {
        guard tokenTrackingEnabled else { return }
        guard remoteSourcesEnabled else {
            // Switched off while the fetch ran, which may have re-added events.
            await RemoteSources.shared.reset()
            await republishTokens()
            return
        }
        remoteSources = statuses
        guard changed else { return }
        await republishTokens()
    }

    /// Re-reads every token view from the tracker's in-memory events after a
    /// remote fetch changed them, so the charts and the grid count the remote
    /// usage as soon as the popover does.
    private func republishTokens() async {
        let range = usageRange
        let offset = usageOffset
        tokenReport = await TokenTracker.shared.report(
            sessionResetsAt: snapshot?.sessionSection?.resetsAt,
            weekResetsAt: snapshot?.weeklyAllSection?.resetsAt)
        usageBreakdown = await TokenTracker.shared.breakdown(range: range, offset: offset)
        usageHistory = await TokenTracker.shared.history()
    }

    private func performRefresh() async {
        guard let key = sessionKey, !key.isEmpty else {
            lastError = "Not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }
        lastFailStatus = nil

        do {
            // Fast path: an org that served usage before.
            if let cached = orgUUID,
               let snap = try await tryUsage(orgUUID: cached, name: orgName, key: key) {
                applySuccess(snap, uuid: cached, name: orgName)
                return
            }

            // Otherwise enumerate every org on the account and try each — an
            // enterprise account often belongs to multiple orgs and only one
            // (or a non-first one) serves the usage endpoint.
            let orgs = try await client.fetchOrganizations(sessionKey: key)
            guard !orgs.isEmpty else { throw ClaudeError.noOrg }
            for o in orgs {
                if let snap = try await tryUsage(orgUUID: o.uuid, name: o.name, key: key) {
                    orgLooksEnterprise = o.looksEnterprise
                    applySuccess(snap, uuid: o.uuid, name: o.name)
                    return
                }
            }

            // Every org rejected /usage. Report the last HTTP status, keeping
            // the captured body in lastErrorDetail for the Debug panel.
            self.lastError = ClaudeError.http(status: lastFailStatus ?? 0, body: "").userMessage
            self.consecutiveFailures += 1
        } catch is CancellationError {
            // Ignored
        } catch let err as ClaudeError {
            self.lastError = err.userMessage
            self.consecutiveFailures += 1
        } catch {
            self.lastError = error.localizedDescription
            self.consecutiveFailures += 1
        }
    }

    /// Attempts the usage endpoint for one org. Returns the snapshot on success,
    /// nil on an HTTP rejection (recording status + body for diagnostics so the
    /// caller can try the next org), and rethrows network/decoding failures.
    private func tryUsage(orgUUID: String, name: String?, key: String) async throws -> UsageSnapshot? {
        do {
            return try await client.fetchUsage(orgUUID: orgUUID, sessionKey: key)
        } catch let e as ClaudeError {
            if case .http(let code, let body) = e {
                lastFailStatus = code
                let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
                lastErrorDetail = """
                Org: \(name ?? "?")  [\(orgUUID)]
                GET /api/organizations/\(orgUUID)/usage → HTTP \(code)
                \(trimmed.isEmpty ? "(empty body)" : String(trimmed.prefix(1200)))
                """
                return nil
            }
            throw e
        }
    }

    private func applySuccess(_ snap: UsageSnapshot, uuid: String, name: String?) {
        orgUUID = uuid
        orgName = name
        UserDefaults.standard.set(uuid, forKey: Self.orgUUIDKey)
        if let name { UserDefaults.standard.set(name, forKey: Self.orgNameKey) }

        snapshot = snap
        lastError = nil
        lastErrorDetail = nil
        lastFetched = Date()
        consecutiveFailures = 0

        applyDefaultMetric()
        // Now that the real reset times are known, re-bucket the tokens against
        // the same windows claude.ai is measuring.
        refreshTokens(force: true)
    }

    // MARK: - Polling

    func popoverDidOpen() {
        isPopoverOpen = true
        refresh()
        restartPoll()
    }

    func popoverDidClose() {
        isPopoverOpen = false
        restartPoll()
    }

    private func restartPoll() {
        pollTask?.cancel()
        guard isConfigured else { return }
        // Base intervals: 15s while the popover is open (feels live), 60s idle.
        // After repeated failures, back off up to 5 minutes to avoid hammering.
        let base: UInt64 = isPopoverOpen ? 15 : 60
        let backoffSeconds = min(base * UInt64(max(1, consecutiveFailures)), 300)
        let interval = max(base, backoffSeconds)
        let nanos = interval * 1_000_000_000

        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: nanos)
                if Task.isCancelled { break }
                guard let self else { break }
                self.refresh()
            }
        }
    }

    // MARK: - Sleep / wake

    private func registerWorkspaceObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
                self?.restartPoll()
            }
        }
        nc.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.pollTask?.cancel()
                self?.pollTask = nil
            }
        }
    }
}
