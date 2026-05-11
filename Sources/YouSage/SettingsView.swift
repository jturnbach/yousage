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
                Text("Reads your Claude subscription usage directly from claude.ai. Your session key is stored in the macOS Keychain and only sent to claude.ai.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                connectionSection
                Divider()
                displaySection
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

    // MARK: - Display

    private var displaySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Menu Bar Display")
                .font(.headline)
            Text("Which percentage to show next to the menu bar icon.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Picker("Show", selection: Binding(
                get: { state.menuBarMetric },
                set: { state.setMenuBarMetric($0) }
            )) {
                ForEach(MenuBarMetric.allCases) { metric in
                    Text(metric.displayName).tag(metric)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
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
