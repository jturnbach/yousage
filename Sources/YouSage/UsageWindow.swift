import AppKit
import SwiftUI

struct UsageWindow: View {
    @ObservedObject private var state = AppState.shared
    @State private var showTable = false
    /// Tokens is the default because it is the measure that exists — the dollars
    /// are a what-if at API list prices, and this is a subscription tool.
    @State private var metric: TrendMetric = .tokens
    /// The onion skin, on by default: the question "more or less than last week?"
    /// is the one a usage chart is opened to answer, and an overlay nobody
    /// discovers answers it for nobody.
    @State private var onionSkin = true
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
                // An idle window is still a window: it draws as the same dashboard
                // reading zero. Replacing the page with "no activity" would hide
                // the range picker's own answer behind a wall of nothing, and make
                // a quiet week look like a broken app.
                dashboard(breakdown)
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
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                state.stepUsage(by: -1)
            } label: {
                Label("Earlier", systemImage: "chevron.left")
            }
            // The end of the retained transcripts, not of the activity: a quiet
            // period is still a period, and it draws as an empty chart.
            .disabled(state.usageOffset >= state.usageRange.maxOffset)
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .help("Show the previous \(state.usageRange.stepName)")

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

            Button {
                state.stepUsage(by: 1)
            } label: {
                Label("Later", systemImage: "chevron.right")
            }
            .disabled(state.usageOffset == 0)
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .help("Show the next \(state.usageRange.stepName)")
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
    /// disagree with the chart. A single-day span is a single date, and a date
    /// printed twice with a dash between it is not a range; it is named where a
    /// name exists, because "Jul 18" a day after the 18th reads as a stale window.
    static func dateRange(_ breakdown: UsageBreakdown) -> String {
        guard let first = breakdown.buckets.first?.start, let last = breakdown.buckets.last?.start else {
            return ""
        }
        let f = Date.FormatStyle.dateTime.month(.abbreviated).day()
        guard breakdown.range == .today else {
            return "\(first.formatted(f)) – \(last.formatted(f))"
        }
        switch breakdown.offset {
        case 0:  return "Today · \(first.formatted(f))"
        case 1:  return "Yesterday · \(first.formatted(f))"
        default: return first.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        }
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
                    if let history = state.usageHistory {
                        historyCard(history)
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

    // MARK: - History

    /// The long view, and the one card the range picker does not move — so it
    /// sits last, under everything the picker does move, and says so in its own
    /// heading rather than leaving the reader to discover it by clicking.
    private func historyCard(_ history: UsageHistory) -> some View {
        DashCard(padding: EdgeInsets(top: 15, leading: 18, bottom: 15, trailing: 18)) {
            HStack(spacing: 12) {
                Text("Every day since \(Self.historyStart(history))")
                    .font(.system(size: 14, weight: .semibold))
                    .tracking(-0.14)
                    .fixedSize()
                Spacer(minLength: 8)
                HeatLegend()
            }
            ActivityGrid(days: history.days, metric: metric)
                .padding(.top, 2)
            CardFootnote(text: Self.historyFootnote(history, metric: metric))
                .padding(.top, 4)
        }
    }

    /// Names the oldest day drawn, because "the last 180 days" is a figure the
    /// reader has to do arithmetic on and a date is one they can just read.
    static func historyStart(_ history: UsageHistory) -> String {
        guard let first = history.days.first?.start else { return "today" }
        return first.formatted(.dateTime.month(.abbreviated).day())
    }

    /// What the grid adds up to, and where its darkest cell is — the two things
    /// a wall of colour cannot say on its own. Also the honest note about depth:
    /// the grid stops where the transcripts do, which is not where usage did.
    static func historyFootnote(_ history: UsageHistory, metric: TrendMetric) -> String {
        let kept = "\(history.days.count) days kept"
        guard !history.isEmpty,
              let busiest = history.days.max(by: { metric.value($0) < metric.value($1) }),
              metric.value(busiest) > 0 else {
            return "Nothing in the \(kept) of transcripts"
        }
        let total = metric == .tokens
            ? metric.describe(Double(history.totals.total))
            : history.cost.exactDisplay
        let day = busiest.start.formatted(.dateTime.month(.abbreviated).day())
        return "\(total) across \(history.activeDays) of \(kept) · "
            + "busiest \(day) at \(metric.describe(metric.value(busiest)))"
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
                CardFootnote(text: Self.previousTokens(breakdown))
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
                CardFootnote(text: Self.messageRate(breakdown))
                    .padding(.top, 8)
            }
        }
        // The tallest card sets the strip's height; without this the two narrow
        // cards would each shrink to their own content and break the top line.
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Says what the chip is a percentage *of*. Without the previous figure, "▲18%"
    /// is a number with no denominator.
    static func previousTokens(_ breakdown: UsageBreakdown) -> String {
        // Today is compared against yesterday up to this same time, so the
        // footnote has to say so — "vs. yesterday" would imply a whole day. A day
        // already finished *is* compared whole, against the whole day before it.
        let period: String
        switch (breakdown.range, breakdown.offset) {
        case (.today, 0): period = "yesterday to this time"
        case (.today, _): period = "the day before"
        case (.week, 0):  period = "last week to this point"
        case (.week, _):  period = "the week before"
        default:          period = "previous \(breakdown.range.days) days"
        }
        // The previous period can be present for the overlay's sake while the
        // slice the chips compare against is still empty — see `previousPeriod`.
        guard let previous = breakdown.previous, previous.totals.total > 0 else {
            return "no activity \(period)"
        }
        return "vs. \(NumberFormat.tokens(previous.totals.total)) \(period)"
    }

    /// A partial day has no daily average to report — one day in, the "average" is
    /// just the count, and it is still climbing. A finished day has the count, and
    /// calling it an average over one day would be arithmetic dressed as insight.
    static func messageRate(_ breakdown: UsageBreakdown) -> String {
        switch (breakdown.range, breakdown.offset) {
        case (.today, 0): return "so far today"
        case (.today, _): return "across the day"
        default:          return "\(breakdown.messagesPerDay.formatted(.number)) / day avg"
        }
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
                ModelLegend(families: families(in: breakdown),
                            previousName: onion(breakdown).isEmpty ? nil : breakdown.range.previousName,
                            showsTotal: !onion(breakdown).isEmpty && families(in: breakdown).count > 1)
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

                Toggle(isOn: $onionSkin) {
                    Image(systemName: "square.on.square.dashed")
                }
                .toggleStyle(.button)
                .disabled(breakdown.previous?.buckets.isEmpty ?? true)
                .help(breakdown.previous == nil
                      ? "No \(breakdown.range.previousName.lowercased()) on this Mac to compare with"
                      : "Overlay \(breakdown.range.previousName.lowercased())")
            }

            if showTable {
                // The table lists measurements, so it stops where they do; the
                // chart takes the whole window because its axis spans it.
                UsageTable(buckets: breakdown.lived,
                           previous: onion(breakdown),
                           previousName: breakdown.range.previousName,
                           families: families(in: breakdown),
                           metric: metric,
                           unit: breakdown.range.unit)
            } else {
                TrendChart(buckets: breakdown.buckets,
                           previous: onion(breakdown),
                           families: families(in: breakdown),
                           metric: metric,
                           unit: breakdown.range.unit,
                           previousName: breakdown.range.previousName)
            }
        }
    }

    /// The previous period's buckets when the overlay is on and there are any —
    /// empty otherwise, which is how the chart, the legend, and the table are all
    /// told the overlay is off. One switch, read in one place.
    private func onion(_ breakdown: UsageBreakdown) -> [UsageBucket] {
        guard onionSkin else { return [] }
        return breakdown.previous?.buckets ?? []
    }

    /// Only families that actually appear, in declaration order, so neither the
    /// legend nor the table advertises a model you never ran.
    private func families(in breakdown: UsageBreakdown) -> [ModelFamily] {
        ModelFamily.allCases.filter { family in
            breakdown.lived.contains { $0.byFamily.contains { $0.family == family } }
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
