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
    private var isPopoverOpen = false

    private static let orgUUIDKey = "YouSage.orgUUID"
    private static let orgNameKey = "YouSage.orgName"
    private static let metricKey  = "YouSage.menuBarMetric"
    private static let planKey    = "YouSage.planMode"
    private static let tokensKey  = "YouSage.tokenTracking"

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
        if enabled { refreshTokens(force: true) } else { tokenReport = nil }
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
    private func refreshTokens(force: Bool = false) {
        guard tokenTrackingEnabled, tokenScan == nil else { return }
        if !force, let last = lastTokenScan, Date().timeIntervalSince(last) < 5 { return }

        let session = snapshot?.sessionSection?.resetsAt
        let week = snapshot?.weeklyAllSection?.resetsAt
        tokenScan = Task { [weak self] in
            let report = await TokenTracker.shared.report(sessionResetsAt: session, weekResetsAt: week)
            await MainActor.run {
                guard let self else { return }
                self.tokenReport = report
                self.lastTokenScan = Date()
                self.tokenScan = nil
            }
        }
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
