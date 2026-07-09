import SwiftUI

struct UsageWindow: View {
    @ObservedObject private var state = AppState.shared
    @State private var showTable = false

    var body: some View {
        Group {
            if !state.tokenTrackingEnabled {
                message("Token tracking is off",
                        "YouSage reads Claude Code's local transcripts to count tokens.") {
                    Button("Turn on token tracking") { state.setTokenTracking(true) }
                }
            } else if !state.hasScannedTokens {
                // nil breakdown means "not read yet" until the first scan lands.
                // Claiming "no transcripts" here would contradict a user who just
                // switched tracking on.
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Reading Claude Code transcripts…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let breakdown = state.usageBreakdown {
                if breakdown.totals.messages == 0 {
                    message("No activity in the last 7 days",
                            "Nothing in ~/.claude/projects falls inside this window.") { EmptyView() }
                } else {
                    content(breakdown)
                }
            } else {
                message("No Claude Code transcripts found",
                        "YouSage looks in ~/.claude/projects. Chats in the Claude app or on "
                        + "claude.ai draw down the same limits but leave nothing here.") { EmptyView() }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { state.refresh() }
    }

    /// Generic over the action view rather than taking a defaulted opaque type —
    /// `@ViewBuilder action: () -> some View = { EmptyView() }` does not compile.
    private func message<Action: View>(_ title: String, _ detail: String,
                                       @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func content(_ breakdown: UsageBreakdown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(breakdown)

                if showTable {
                    UsageTable(breakdown: breakdown)
                } else {
                    GroupBox("Tokens per day") {
                        TrendChart(days: breakdown.days).padding(.top, 6)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("Cost by model") {
                            CostByModelChart(models: breakdown.models).padding(.top, 6)
                        }
                        GroupBox("Token kind") {
                            TokenKindChart(kinds: breakdown.kinds).padding(.top, 6)
                        }
                    }
                }

                if !breakdown.cost.isComplete {
                    Text("Costs exclude \(breakdown.cost.unpricedModels.joined(separator: ", ")) — "
                         + "no list price is known for \(breakdown.cost.unpricedModels.count == 1 ? "it" : "them"). "
                         + "Totals are lower bounds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private func header(_ breakdown: UsageBreakdown) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                kpi(NumberFormat.tokens(breakdown.totals.total), "tokens")
                kpi(breakdown.cost.display, "at API list prices")
                kpi("\(breakdown.totals.messages)", "messages")
                Spacer()
                Picker("", selection: $showTable) {
                    Image(systemName: "chart.bar.xaxis").tag(false)
                    Image(systemName: "tablecells").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            // The popover's "Last 7 days" is a rolling window pinned to claude.ai's
            // reset. This window is calendar days. The labels keep them apart.
            Text("last 7 calendar days")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private func kpi(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.trailing, 26)
    }
}

/// The accessible twin every chart is supposed to have, and the place to read
/// exact numbers rather than approximate a bar's length.
private struct UsageTable: View {
    let breakdown: UsageBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("By day") {
                Table(breakdown.days) {
                    TableColumn("Day") { day in
                        Text(day.day, format: .dateTime.weekday(.wide).month().day())
                            + Text(day.isToday ? " (so far)" : "")
                    }
                    TableColumn("Models") { day in
                        Text(day.byFamily.map(\.family.displayName).joined(separator: ", "))
                    }
                    TableColumn("Tokens") { day in
                        Text(NumberFormat.tokens(day.totals.total)).monospacedDigit()
                    }
                    TableColumn("Cost") { day in
                        Text(day.cost.display).monospacedDigit()
                    }
                }
                .frame(minHeight: 200)
            }
            GroupBox("By model") {
                Table(breakdown.models) {
                    TableColumn("Model", value: \.displayName)
                    TableColumn("Tokens") { m in
                        Text(NumberFormat.tokens(m.totals.total)).monospacedDigit()
                    }
                    TableColumn("Cost") { m in
                        Text(m.cost.display).monospacedDigit()
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }
}
