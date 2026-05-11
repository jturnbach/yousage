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

    private let client = ClaudeClient()
    private var pollTask: Task<Void, Never>?
    private var inflight: Task<Void, Never>?
    private var isPopoverOpen = false

    private static let orgUUIDKey = "YouSage.orgUUID"
    private static let orgNameKey = "YouSage.orgName"
    private static let metricKey  = "YouSage.menuBarMetric"

    private init() {
        sessionKey = Keychain.read(account: "sessionKey")
        orgUUID = UserDefaults.standard.string(forKey: Self.orgUUIDKey)
        orgName = UserDefaults.standard.string(forKey: Self.orgNameKey)
        if let raw = UserDefaults.standard.string(forKey: Self.metricKey),
           let m = MenuBarMetric(rawValue: raw) {
            menuBarMetric = m
        }

        registerWorkspaceObservers()

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

    var highestPercent: Double? {
        snapshot?.sections.map(\.percent).max()
    }

    /// Percentage to show in the menu bar, based on the user-selected metric.
    /// Returns nil while there's no snapshot yet (or when the chosen section
    /// is absent from the response).
    var displayPercent: Double? {
        guard let sections = snapshot?.sections, !sections.isEmpty else { return nil }
        switch menuBarMetric {
        case .highest:
            return sections.map(\.percent).max()
        case .session:
            return sections.first(where: { $0.id == "five_hour" })?.percent
        case .weekly:
            return sections.first(where: { $0.id == "seven_day" })?.percent
        }
    }

    func setMenuBarMetric(_ m: MenuBarMetric) {
        guard m != menuBarMetric else { return }
        menuBarMetric = m
        UserDefaults.standard.set(m.rawValue, forKey: Self.metricKey)
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
        guard isConfigured else { return }
        inflight?.cancel()
        inflight = Task { [weak self] in
            await self?.performRefresh()
        }
    }

    private func performRefresh() async {
        guard let key = sessionKey, !key.isEmpty else {
            lastError = "Not configured"
            return
        }
        isLoading = true
        defer { isLoading = false }

        do {
            let uuid: String
            if let cached = orgUUID {
                uuid = cached
            } else {
                let orgs = try await client.fetchOrganizations(sessionKey: key)
                guard let first = orgs.first else { throw ClaudeError.noOrg }
                uuid = first.uuid
                orgUUID = first.uuid
                orgName = first.name
                UserDefaults.standard.set(first.uuid, forKey: Self.orgUUIDKey)
                if let n = first.name { UserDefaults.standard.set(n, forKey: Self.orgNameKey) }
            }
            let snap = try await client.fetchUsage(orgUUID: uuid, sessionKey: key)
            self.snapshot = snap
            self.lastError = nil
            self.lastFetched = Date()
            self.consecutiveFailures = 0
        } catch is CancellationError {
            // Ignored
        } catch let err as ClaudeError {
            self.lastError = err.userMessage
            self.consecutiveFailures += 1
            // If the org UUID seems stale (404 / 403 on /usage), drop it so the
            // next attempt re-fetches /organizations.
            if case .http(let code, _) = err, code == 404 || code == 403 {
                self.orgUUID = nil
                UserDefaults.standard.removeObject(forKey: Self.orgUUIDKey)
            }
        } catch {
            self.lastError = error.localizedDescription
            self.consecutiveFailures += 1
        }
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
