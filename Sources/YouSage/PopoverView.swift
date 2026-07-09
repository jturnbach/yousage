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
            if state.tokenTrackingEnabled, let report = state.tokenReport, report.hasAnyData {
                Divider().padding(.horizontal, 14)
                TokenTrackerView(report: report)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            }
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
        } else if state.snapshot != nil {
            sectionsView(sections: state.visibleSections)
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

    @ViewBuilder
    private func sectionsView(sections: [UsageSection]) -> some View {
        if sections.isEmpty {
            emptyPlanView
        } else {
            // Groups render in the order the sections arrive, so an enterprise
            // account leads with allotments and a subscription with its session.
            let groups = Self.grouped(sections)
            VStack(alignment: .leading, spacing: 16) {
                ForEach(groups, id: \.title) { group in
                    groupBlock(title: group.title, sections: group.sections)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var emptyPlanView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(state.planMode == .enterprise
                 ? "No allotted usage reported for this account."
                 : "claude.ai reported no usage limits for this account.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if state.planMode != .auto {
                Text("Settings → Plan is set to \(state.planMode.displayName). Try Automatic.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private struct LimitGroup {
        let title: String
        let sections: [UsageSection]
    }

    /// Buckets sections under headings, preserving the incoming order so the
    /// heading order follows the plan's priority rather than a fixed list.
    private static func grouped(_ sections: [UsageSection]) -> [LimitGroup] {
        func heading(_ kind: UsageSection.Kind) -> String {
            switch kind {
            case .allotment: return "Allotted usage"
            case .session:   return "Plan usage limits"
            case .weekly:    return "Weekly limits"
            case .other:     return "Other limits"
            }
        }
        var order: [String] = []
        var buckets: [String: [UsageSection]] = [:]
        for section in sections {
            let title = heading(section.kind)
            if buckets[title] == nil { order.append(title) }
            buckets[title, default: []].append(section)
        }
        return order.map { LimitGroup(title: $0, sections: buckets[$0] ?? []) }
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
                Button("Refresh") { state.refresh() }
                    .disabled(!state.isConfigured)
                Menu("Displayed Usage") {
                    ForEach(MenuBarMetric.allCases) { metric in
                        Button {
                            state.setMenuBarMetric(metric)
                        } label: {
                            if state.menuBarMetric == metric {
                                Label(metric.displayName, systemImage: "checkmark")
                            } else {
                                Text(metric.displayName)
                            }
                        }
                    }
                }
                Divider()
                Button("Settings…") { openSettings() }
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

// MARK: - Token tracker

struct TokenTrackerView: View {
    let report: TokenReport

    private static let sourceNote = """
    Tokens counted from Claude Code transcripts stored on this Mac \
    (~/.claude/projects). Chats in the Claude app, on claude.ai, or on another \
    computer draw down the same limits but aren't counted here.
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Text("Tokens used")
                    .font(.system(size: 13, weight: .semibold))
                InfoTip(text: Self.sourceNote)
                Spacer()
            }

            row(title: "Current session",
                subtitle: sessionSubtitle,
                totals: report.session)

            row(title: "Last 7 days",
                subtitle: nil,
                totals: report.week)

            if report.models.count > 1 {
                Text(report.models.prefix(3)
                        .map { "\($0.displayName) \(NumberFormat.tokens($0.totals.total))" }
                        .joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var sessionSubtitle: String? {
        guard let start = report.sessionStart else { return "No activity in the current window" }
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        let since = "Since \(f.string(from: start))"
        return report.sessionIsAuthoritative ? since : "\(since) (estimated window)"
    }

    private func row(title: String, subtitle: String?, totals: TokenTotals) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(NumberFormat.tokens(totals.total))
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .monospacedDigit()
                Text(totals.breakdown)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
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
                    if !section.isRecognized {
                        Image(systemName: "sparkle")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .help("New limit reported by claude.ai")
                    }
                    if let note = section.infoNote {
                        InfoTip(text: note)
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
                if let amounts = section.allotmentText {
                    Text(amounts)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Text("\(Int(section.percent.rounded()))% used")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                } else {
                    Text("\(Int(section.percent.rounded()))% used")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
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
        case .allotment:
            let f = DateFormatter()
            f.dateFormat = "MMM d"
            return "Renews \(f.string(from: date))"
        case .other:
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .full
            return "Resets \(f.localizedString(for: date, relativeTo: now))"
        }
    }
}

struct InfoTip: View {
    let text: String
    @State private var showing = false

    var body: some View {
        Button {
            showing.toggle()
        } label: {
            Image(systemName: "info.circle")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help(text)
        .popover(isPresented: $showing, arrowEdge: .top) {
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
                .frame(maxWidth: 260)
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
