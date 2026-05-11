import SwiftUI
import AppKit

struct PopoverView: View {
    @ObservedObject private var state = AppState.shared
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, 14)
            content
            Divider().padding(.horizontal, 14)
            footer
        }
        .padding(.vertical, 12)
        .onAppear { state.popoverDidOpen() }
        .onDisappear { state.popoverDidClose() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude usage")
                    .font(.headline)
                if let org = state.orgName {
                    Text(org)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button(action: { state.refresh() }) {
                if state.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.plain)
            .help("Refresh now")
            .disabled(!state.isConfigured)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !state.isConfigured {
            unconfiguredView
        } else if let snapshot = state.snapshot {
            sectionsView(snapshot: snapshot)
        } else if let err = state.lastError {
            errorView(message: err)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        }
    }

    private var unconfiguredView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect your Claude account to start tracking usage.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                openSettings()
            } label: {
                Label("Connect Claude…", systemImage: "key.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    private func errorView(message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Open Settings") { openSettings() }
                Button("Retry") { state.refresh() }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func sectionsView(snapshot: UsageSnapshot) -> some View {
        let sessionSections = snapshot.sections.filter { $0.kind == .session }
        let weeklySections  = snapshot.sections.filter { $0.kind == .weekly }

        return VStack(alignment: .leading, spacing: 16) {
            if !sessionSections.isEmpty {
                groupBlock(title: "Plan usage limits", sections: sessionSections)
            }
            if !weeklySections.isEmpty {
                groupBlock(title: "Weekly limits", sections: weeklySections)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func groupBlock(title: String, sections: [UsageSection]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(sections) { section in
                SectionRow(section: section)
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(state.statusSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Menu {
                Button("Settings…") { openSettings() }
                Button("Refresh") { state.refresh() }
                    .disabled(!state.isConfigured)
                Divider()
                Button("Open claude.ai/settings/usage") {
                    if let url = URL(string: "https://claude.ai/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                }
                Divider()
                Button("Quit YouSage") {
                    NSApp.terminate(nil)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
    }

    private func openSettings() {
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct SectionRow: View {
    let section: UsageSection
    @State private var now = Date()

    private let tick = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(section.title)
                        .font(.system(size: 13, weight: .regular))
                    if let note = section.infoNote {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.tertiary)
                            .help(note)
                    }
                }
                if let s = resetString {
                    Text(s)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                UsageBar(percent: section.percent)
                    .frame(width: 130, height: 6)
                Text("\(Int(section.percent.rounded()))% used")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
        .onReceive(tick) { now = $0 }
    }

    private var resetString: String? {
        guard let date = section.resetsAt else { return nil }
        switch section.kind {
        case .session:
            let interval = date.timeIntervalSince(now)
            if interval <= 0 { return "Resetting…" }
            let hours = Int(interval) / 3600
            let mins = (Int(interval) % 3600) / 60
            if hours > 0 { return "Resets in \(hours) hr \(mins) min" }
            return "Resets in \(mins) min"
        case .weekly:
            let f = DateFormatter()
            f.dateFormat = "EEE h:mm a"
            return "Resets \(f.string(from: date))"
        }
    }
}

struct UsageBar: View {
    let percent: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(Color.secondary.opacity(0.18))
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(barColor)
                    .frame(width: geo.size.width * fillFraction)
            }
        }
    }

    private var fillFraction: Double {
        max(0, min(1, percent / 100))
    }

    private var barColor: Color {
        switch percent {
        case ..<70: return .accentColor
        case 70..<90: return .orange
        default: return .red
        }
    }
}
