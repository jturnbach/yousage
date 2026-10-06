import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject private var state = AppState.shared
    @State private var input: String = ""
    @State private var showRaw: Bool = false
    @State private var testStatus: String? = nil
    @State private var testing: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("YouSage")
                    .font(.title2.bold())
                Text("Reads your Claude usage directly from claude.ai — subscription rate limits or enterprise allotted usage, whichever your plan reports. Your session key is stored in the macOS Keychain and only sent to claude.ai.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                connectionSection
                Divider()
                planSection
                Divider()
                tokenSection
                Divider()
                remoteSection
                Divider()
                instructions
                Divider()
                debugSection
            }
            .padding(20)
        }
    }

    // MARK: - Connection

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Session Key")
                .font(.headline)

            if state.isConfigured {
                HStack(spacing: 6) {
                    Image(systemName: state.lastError == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .foregroundStyle(state.lastError == nil ? .green : .orange)
                    Text(state.lastError == nil
                         ? "Connected\(state.orgName.map { " · \($0)" } ?? "")"
                         : "Issue: \(state.lastError ?? "")")
                        .font(.callout)
                }
            }

            SecureField("Paste sessionKey cookie value…", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { save() }

            if let s = testStatus {
                Text(s)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Save & Connect") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Test") { test() }
                    .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing)
                if state.isConfigured {
                    Button("Disconnect", role: .destructive) {
                        state.clearSessionKey()
                        input = ""
                        testStatus = nil
                    }
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
            }
        }
    }

    private func save() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        state.saveSessionKey(trimmed)
        input = ""
        testStatus = "Saved. Fetching usage…"
    }

    private func test() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        testing = true
        testStatus = "Testing…"
        Task { @MainActor in
            let client = ClaudeClient()
            do {
                let orgs = try await client.fetchOrganizations(sessionKey: trimmed)
                if let first = orgs.first {
                    testStatus = "OK · \(orgs.count) organization(s) · primary: \(first.name ?? first.uuid)"
                } else {
                    testStatus = "OK but no organizations returned."
                }
            } catch let err as ClaudeError {
                testStatus = "Failed: \(err.userMessage)"
            } catch {
                testStatus = "Failed: \(error.localizedDescription)"
            }
            testing = false
        }
    }

    // MARK: - Plan

    private var planSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Plan")
                .font(.headline)

            Picker("", selection: Binding(
                get: { state.planMode },
                set: { state.setPlanMode($0) }
            )) {
                ForEach(PlanMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Text(planExplanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.planMode == .auto, state.detectedPlan != .unknown {
                HStack(spacing: 6) {
                    Image(systemName: "wand.and.stars")
                        .foregroundStyle(.secondary)
                    Text("Detected: \(state.detectedPlan.displayName)")
                        .font(.callout)
                }
            }
        }
    }

    private var planExplanation: String {
        switch state.planMode {
        case .auto:
            return "Reads the shape of your usage data: absolute used-of-granted amounts mean an enterprise plan, rate-limit percentages mean a subscription. Leave this on unless it guesses wrong."
        case .subscription:
            return "Shows your 5-hour session, weekly limits, and any additional limits Anthropic reports — including new ones, which appear automatically. Hides enterprise allotments."
        case .enterprise:
            return "Leads with allotted usage (amount used of the amount granted). Any rate limits your account also reports stay visible below."
        }
    }

    // MARK: - Token tracking

    private var tokenSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Token tracker")
                .font(.headline)

            Toggle("Show tokens used at the bottom of the popover", isOn: Binding(
                get: { state.tokenTrackingEnabled },
                set: { state.setTokenTracking($0) }
            ))

            Text("Counts tokens from Claude Code transcripts stored on this Mac (~/.claude/projects), and from any remote sources below, split by the same 5-hour and weekly windows claude.ai reports. Conversations in the Claude app or on claude.ai consume the same limits but leave no transcript YouSage can read, so they aren't counted.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.tokenTrackingEnabled {
                if let report = state.tokenReport {
                    Text("Scanned \(report.filesScanned) transcript\(report.filesScanned == 1 ? "" : "s") · \(NumberFormat.tokens(report.week.total)) tokens over \(report.week.messages) messages in the last 7 days.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    Text("No Claude Code transcripts found on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: - Remote sources

    private var remoteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remote sources")
                .font(.headline)

            Toggle("Count Claude Code on servers in your tailnet", isOn: Binding(
                get: { state.remoteSourcesEnabled },
                set: { state.setRemoteSources($0) }
            ))
            .disabled(!state.tokenTrackingEnabled)

            Text("YouSage asks Tailscale for online devices tagged tag:server and checks each for a YouSage server. A server's tokens are added only when its Claude Code is signed in to the same organization as this Mac. Nothing to set up here; without Tailscale this does nothing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if state.tokenTrackingEnabled && state.remoteSourcesEnabled {
                if state.remoteSources.isEmpty {
                    Text("No servers found.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(state.remoteSources) { source in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: remoteIcon(source.state))
                                .foregroundStyle(remoteColor(source.state))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(source.name)
                                    .font(.callout)
                                Text("\(source.id) · \(source.stateText)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }
                Button("Look again") { state.rediscoverRemoteSources() }
                    .controlSize(.small)
            }
        }
    }

    private func remoteIcon(_ state: RemoteSourceStatus.State) -> String {
        switch state {
        case .ok:                return "checkmark.circle.fill"
        case .waitingForAccount: return "clock"
        case .accountMismatch:   return "person.crop.circle.badge.xmark"
        case .failed:            return "exclamationmark.triangle.fill"
        }
    }

    private func remoteColor(_ state: RemoteSourceStatus.State) -> Color {
        switch state {
        case .ok:                return .green
        case .waitingForAccount: return .secondary
        case .accountMismatch:   return .secondary
        case .failed:            return .orange
        }
    }

    // MARK: - Instructions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to get your sessionKey")
                .font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                step(1, "Open claude.ai in your browser and make sure you're signed in.")
                step(2, "Open developer tools — right click anywhere → Inspect.")
                step(3, "Go to Application (Chrome/Edge/Brave/Arc) or Storage (Safari/Firefox) → Cookies → https://claude.ai.")
                step(4, "Find the cookie named sessionKey. Double-click its Value and copy it.")
                step(5, "Paste it above and press Save & Connect.")
            }
            HStack {
                Button {
                    if let url = URL(string: "https://claude.ai") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open claude.ai", systemImage: "safari")
                }
                Text("The key looks like \"sk-ant-sid01-…\" and is hundreds of characters long.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(n).").bold().frame(width: 18, alignment: .trailing)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
    }

    // MARK: - Debug

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DisclosureGroup("Debug", isExpanded: $showRaw) {
                VStack(alignment: .leading, spacing: 6) {
                    if let uuid = state.orgUUID {
                        Text("Organization UUID: \(uuid)")
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    ForEach(state.remoteSources.filter { $0.state == .accountMismatch }) { source in
                        Text("Remote source \(source.name) (\(source.id)) is signed in to a different Claude organization; its tokens are ignored.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let detail = state.lastErrorDetail {
                        Text("Last failed request:")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                        ScrollView {
                            Text(detail)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 120)
                        .background(Color.orange.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if let snap = state.snapshot {
                        Text("Last fetched: \(snap.fetchedAt.formatted(date: .abbreviated, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Raw response:")
                            .font(.caption.weight(.semibold))
                        ScrollView {
                            Text(snap.rawJSON.isEmpty ? "(empty)" : snap.rawJSON)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(height: 180)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text("No data fetched yet.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.headline)
        }
    }
}
