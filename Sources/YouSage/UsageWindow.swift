import AppKit
import SwiftUI

struct UsageWindow: View {
    @ObservedObject private var state = AppState.shared
    @State private var showTable = false
    /// Tokens is the default because it is the measure that exists — the dollars
    /// are a what-if at API list prices, and this is a subscription tool.
    @State private var metric: TrendMetric = .tokens
    @State private var exportError: String?

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
                    message(breakdown.range == .today
                            ? "No activity today yet"
                            : "No activity in the last \(breakdown.range.days) days",
                            "Nothing in ~/.claude/projects falls inside this window.") { EmptyView() }
                } else {
                    dashboard(breakdown)
                }
            } else {
                message("No Claude Code transcripts found",
                        "YouSage looks in ~/.claude/projects. Chats in the Claude app or on "
                        + "claude.ai draw down the same limits but leave nothing here.") { EmptyView() }
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .navigationTitle("Usage")
        .navigationSubtitle(state.usageBreakdown.map(Self.dateRange) ?? "")
        .toolbar { toolbar }
        .alert("Couldn't export", isPresented: .constant(exportError != nil)) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
        .task { state.refresh() }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Picker("Range", selection: Binding(get: { state.usageRange },
                                               set: { state.setUsageRange($0) })) {
                ForEach(UsageRange.allCases) { range in
                    Text(range.label).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("How far back to look")
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                export()
            } label: {
                Label("Export", systemImage: "square.and.arrow.down")
            }
            .disabled(state.usageBreakdown == nil)
            .help("Save this range as a CSV")
        }
    }

    /// "Jul 7 – Jul 13" — the span actually drawn, so the subtitle can never
    /// disagree with the chart. Today's span is a single date, and a date printed
    /// twice with a dash between it is not a range.
    private static func dateRange(_ breakdown: UsageBreakdown) -> String {
        guard let first = breakdown.buckets.first?.start, let last = breakdown.buckets.last?.start else {
            return ""
        }
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        guard breakdown.range != .today else { return "Today · \(first.formatted(f))" }
        return "\(first.formatted(f)) – \(last.formatted(f))"
    }

    // MARK: - Page

    private func dashboard(_ breakdown: UsageBreakdown) -> some View {
        ScrollView {
            GlassGroup(spacing: 12) {
                VStack(spacing: 12) {
                    hero(breakdown)
                    trendCard(breakdown)
                    WeightedHStack(weights: [1.5, 1], spacing: 12) {
                        DashCard(title: "Cost by model",
                                 padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
                            CostByModelList(models: breakdown.models,
                                            totalCost: breakdown.cost.amount)
                        }
                        VStack(spacing: 12) {
                            projectionCard(breakdown.month)
                            cacheCard(breakdown)
                            if let budget = state.monthlyBudget {
                                budgetCard(spent: breakdown.month.spendToDate, budget: budget)
                            }
                        }
                    }
                    DashCard(title: "Token kind",
                             padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
                        TokenKindList(kinds: breakdown.kinds)
                    }

                    if !breakdown.cost.isComplete {
                        Text("Costs exclude \(breakdown.cost.unpricedModels.joined(separator: ", ")) — "
                             + "no list price is known for "
                             + "\(breakdown.cost.unpricedModels.count == 1 ? "it" : "them"). "
                             + "Totals are lower bounds.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(EdgeInsets(top: 18, leading: 20, bottom: 20, trailing: 20))
        }
    }

    // MARK: - Hero

    private func hero(_ breakdown: UsageBreakdown) -> some View {
        WeightedHStack(weights: [1.45, 1, 1], spacing: 12) {
            DashCard {
                CardLabel(text: "Total tokens") {
                    if let change = breakdown.tokenChange { TrendChip.volume(change) }
                }
                MetricValue(text: NumberFormat.tokens(breakdown.totals.total), size: 31)
                    .padding(.top, 5)
                CardFootnote(text: previousTokens(breakdown))
                    .padding(.top, 6)
            }
            DashCard {
                CardLabel("API list cost")
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    MetricValue(text: breakdown.cost.exactDisplay, size: 24)
                    if let change = breakdown.costChange { TrendChip.cost(change, small: true) }
                }
                .padding(.top, 5)
                CardFootnote(text: costPerMessage(breakdown))
                    .padding(.top, 8)
            }
            DashCard {
                CardLabel("Messages")
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    MetricValue(text: breakdown.totals.messages.formatted(.number), size: 24)
                    if let change = breakdown.messageChange {
                        TrendChip.volume(change, small: true)
                    }
                }
                .padding(.top, 5)
                CardFootnote(text: messageRate(breakdown))
                    .padding(.top, 8)
            }
        }
        // The tallest card sets the strip's height; without this the two narrow
        // cards would each shrink to their own content and break the top line.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Says what the chip is a percentage *of*. Without the previous figure, "▲18%"
    /// is a number with no denominator.
    private func previousTokens(_ breakdown: UsageBreakdown) -> String {
        // Today is compared against yesterday up to this same time, so the
        // footnote has to say so — "vs. yesterday" would imply a whole day.
        let period = breakdown.range == .today
            ? "yesterday to this time"
            : "previous \(breakdown.range.days) days"
        guard let previous = breakdown.previous else { return "no activity \(period)" }
        return "vs. \(NumberFormat.tokens(previous.totals.total)) \(period)"
    }

    /// A partial day has no daily average to report — one day in, the "average" is
    /// just the count, and it is still climbing.
    private func messageRate(_ breakdown: UsageBreakdown) -> String {
        breakdown.range == .today
            ? "so far today"
            : "\(breakdown.messagesPerDay.formatted(.number)) / day avg"
    }

    private func costPerMessage(_ breakdown: UsageBreakdown) -> String {
        guard let each = breakdown.costPerMessage else { return "no messages" }
        return String(format: "$%.3f / message", each)
    }

    // MARK: - Trend

    private func trendCard(_ breakdown: UsageBreakdown) -> some View {
        DashCard(padding: EdgeInsets(top: 15, leading: 18, bottom: 12, trailing: 18)) {
            HStack(spacing: 12) {
                Text(metric.cardTitle(breakdown.range.unit))
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.14)
                    .fixedSize()
                Spacer(minLength: 8)
                ModelLegend(families: families(in: breakdown))
                Picker("Metric", selection: $metric) {
                    ForEach(TrendMetric.allCases) { metric in
                        Text(metric.label).tag(metric)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Plot tokens or API list cost")
                Picker("View", selection: $showTable) {
                    Image(systemName: "chart.xyaxis.line").tag(false)
                    Image(systemName: "tablecells").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help(showTable ? "Show the chart" : "Show the numbers")
            }

            if showTable {
                UsageTable(buckets: breakdown.buckets,
                           families: families(in: breakdown),
                           metric: metric,
                           unit: breakdown.range.unit)
            } else {
                TrendChart(buckets: breakdown.buckets,
                           families: families(in: breakdown),
                           metric: metric,
                           unit: breakdown.range.unit)
            }
        }
    }

    /// Only families that actually appear, in declaration order, so neither the
    /// legend nor the table advertises a model you never ran.
    private func families(in breakdown: UsageBreakdown) -> [ModelFamily] {
        ModelFamily.allCases.filter { family in
            breakdown.buckets.contains { $0.byFamily.contains { $0.family == family } }
        }
    }

    // MARK: - Right column

    private func projectionCard(_ month: MonthProjection) -> some View {
        DashCard(tinted: true) {
            CardLabel("Projected month-end")
            MetricValue(text: money(month.projected), size: 27)
                .padding(.top, 4)
            if let change = month.projectedChange {
                TrendChip.cost(change, suffix: "vs. \(month.previousName)", small: true)
                    .padding(.top, 9)
            } else {
                CardFootnote(text: "at \(money(month.spendToDate)) so far this month")
                    .padding(.top, 9)
            }
        }
    }

    private func cacheCard(_ breakdown: UsageBreakdown) -> some View {
        DashCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)) {
            CardLabel("Cache hit rate")
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                MetricValue(text: breakdown.cacheHitRate.map { String(format: "%.1f%%", $0 * 100) }
                            ?? "—", size: 21)
                if let change = breakdown.cacheHitRateChange {
                    TrendChip.volume(change, small: true)
                }
            }
            .padding(.top, 4)
        }
    }

    private func budgetCard(spent: Double, budget: Double) -> some View {
        DashCard(padding: EdgeInsets(top: 13, leading: 16, bottom: 13, trailing: 16)) {
            HStack(alignment: .firstTextBaseline) {
                Text("Monthly budget")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("\(money(spent)) / \(money(budget))")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
            }
            Meter(fraction: spent / budget,
                  fill: LinearGradient(colors: [Color(hex: 0xE0855F), Color(hex: 0xC9694A)],
                                       startPoint: .leading, endPoint: .trailing))
                .padding(.top, 8)
        }
    }

    /// Whole dollars, grouped: the projection and the budget are both estimates at
    /// a scale where cents are noise, and "$2,042" is the figure a person repeats.
    private func money(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(0)))
    }

    // MARK: - Export

    private func export() {
        guard let breakdown = state.usageBreakdown else { return }
        do {
            if let url = try UsageExport.save(breakdown) {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - States

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
}
