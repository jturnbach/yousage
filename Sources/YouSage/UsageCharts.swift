import Charts
import SwiftUI

// MARK: - Trend

/// What the trend plots. Both metrics are the same events sliced the same way,
/// so the chart, its table twin, and the tooltip all read from this one switch
/// rather than each deciding for itself.
enum TrendMetric: String, CaseIterable, Identifiable {
    case tokens, cost

    var id: String { rawValue }

    /// On the segmented control.
    var label: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost:   return "Cost"
        }
    }

    /// The card's heading, which has to name what is drawn — a chart of dollars
    /// under the words "Tokens per day" is a mislabelled axis, and so is a chart
    /// of hours under "per day".
    func cardTitle(_ unit: BucketUnit) -> String {
        let per = unit == .hour ? "hour" : "day"
        switch self {
        case .tokens: return "Tokens per \(per)"
        case .cost:   return "Cost per \(per)"
        }
    }

    /// Plotted height for one family on one bucket.
    func value(_ bucket: UsageBucket, _ family: ModelFamily) -> Double {
        switch self {
        case .tokens: return Double(bucket.total(of: family))
        case .cost:   return bucket.cost(of: family)
        }
    }

    func total(_ bucket: UsageBucket) -> Double {
        switch self {
        case .tokens: return Double(bucket.totals.total)
        case .cost:   return bucket.cost.amount
        }
    }

    /// The same measure over a whole calendar day, for the activity grid.
    func value(_ day: DayUsage) -> Double {
        switch self {
        case .tokens: return Double(day.totals.total)
        case .cost:   return day.cost.amount
        }
    }

    /// The figure with its unit attached, for a tooltip that has no axis beside
    /// it to say what "12.4M" counts.
    func describe(_ value: Double) -> String {
        switch self {
        case .tokens: return "\(format(value)) tokens"
        case .cost:   return format(value)
        }
    }

    /// Compact enough for an axis tick or a table cell.
    func format(_ value: Double) -> String {
        switch self {
        case .tokens: return NumberFormat.tokens(Int(value))
        case .cost:   return NumberFormat.money(value)
        }
    }
}

/// Daily tokens or dollars, one line per model family in that family's fixed
/// colour, with exact per-model numbers in the hover tooltip.
///
/// Lines, not a stack: a stack would ask the reader to compare segment heights
/// that do not share a baseline. Each series is continuous — a family plots 0 on
/// a bucket it sat idle, because "ran nothing" is a value on a tokens-per-day axis.
/// Each line sits on its own gradient fill, held translucent enough that where
/// two overlap the reader still sees both, and the lines themselves — which are
/// what the eye actually follows — stay opaque on top.
///
/// Every x value is the exact bucket-start date, never `unit: .day`: unit
/// binning centres marks inside a bucket-wide band while the axis labels its
/// leading edge, drifting every vertex half a step off its label.
struct TrendChart: View {
    /// Every bucket of the window, the not-yet-lived ones included: they are what
    /// holds the axis open to the whole day or week.
    let buckets: [UsageBucket]
    /// The previous period, aligned to `buckets` index for index. Empty when the
    /// onion skin is switched off, or when there is no previous period to draw.
    var previous: [UsageBucket] = []
    let families: [ModelFamily]
    let metric: TrendMetric
    /// Day or hour. The chart draws the buckets it is handed either way; the unit
    /// only decides how the axis, the ticks, and the tooltip name them.
    let unit: BucketUnit
    /// "Yesterday", "Last week" — what the overlay is, in the words the range
    /// picker uses. The chart is handed it rather than deriving it, because only
    /// the range knows whether seven days is a week or just seven days.
    var previousName = "Previous"
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDate: Date?
    /// Where the pointer is vertically, in the chart's own coordinates. The
    /// selection only carries an x, but the tooltip is pinned to the plot's
    /// ceiling, so it takes a y to know when it is standing in front of what the
    /// pointer came to look at.
    @State private var hoverY: CGFloat?
    /// Measured, because the tooltip's height is however many models ran in that
    /// bucket — a guessed band would either fade too eagerly or too late.
    @State private var tooltipHeight: CGFloat = 0

    /// What the lines are made of. An hour that has not happened is not an hour of
    /// zero usage, so it is not a vertex — the line stops at the present and the
    /// axis carries on without it.
    private var drawn: [UsageBucket] { buckets.filter { !$0.isFuture } }

    /// The onion skin: last period's bucket plotted at this period's x. Drawn
    /// across the *whole* window, the hours not yet lived included — at 2pm the
    /// point of the overlay is seeing where yesterday went on to finish.
    private var ghost: [(current: UsageBucket, previous: UsageBucket)] {
        guard previous.count == buckets.count else { return [] }
        return Array(zip(buckets, previous))
    }

    /// With two families on the chart there is no line for their sum, so the ghost
    /// would hang above every drawn line and read as a collapse. Drawing the
    /// current total gives it something to be compared against.
    private var showsTotal: Bool { !ghost.isEmpty && families.count > 1 }

    /// Every drawn bucket reads zero — a window nothing ran in, or one whose
    /// models carry no list price under the cost metric. It is a real reading, so
    /// it is drawn rather than replaced with a notice; the axis and the baseline
    /// below are what keep it from looking like a chart that failed to load.
    private var isIdle: Bool { drawn.allSatisfy { metric.total($0) == 0 } }

    /// Nearest drawn bucket to the hover, so the snap boundary is the midpoint
    /// between points rather than midnight — and so hovering the empty evening
    /// reports the last real hour instead of "No activity" at 9pm.
    private var selected: UsageBucket? {
        guard let selectedDate else { return nil }
        return drawn.min {
            abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate))
        }
    }

    /// The whole window, so the axis reads 12a–12a all day and Sunday–Saturday all
    /// week. Widened when the window has drawn down to a single point, because a
    /// zero-width domain has no scale to place it on.
    private var xDomain: ClosedRange<Date> {
        guard let first = buckets.first?.start, let last = buckets.last?.start else {
            return Date()...Date().addingTimeInterval(3600)
        }
        return last > first ? first...last : first...first.addingTimeInterval(3600)
    }

    /// Names the x axis for VoiceOver and for Charts' own bookkeeping, so an
    /// hourly chart is not read out as a chart of days.
    private var xLabel: String { unit == .hour ? "Hour" : "Day" }

    private func color(_ family: ModelFamily) -> Color {
        ChartPalette.color(for: family, scheme: scheme)
    }

    /// One fill can afford to be solid; overlapping ones cannot. Two fills at
    /// 0.32 compound to roughly 0.54 where they cross, which reads as a third
    /// colour — 0.18 keeps the overlap below the weakest single fill.
    private var fillOpacity: Double { families.count == 1 ? 0.32 : 0.18 }

    var body: some View {
        // Left to itself an all-zero chart is scaled 0…1 and every tick rounds
        // back to "0" — four identical labels down the axis. Pin the domain so
        // the empty window reads as zero once, at the baseline where it belongs.
        if isIdle {
            chart.chartYScale(domain: 0...1)
        } else {
            chart
        }
    }

    private var chart: some View {
        Chart {
            // `stacking: .unstacked` is load-bearing: area marks stack by default,
            // so two families would draw the second one's fill on top of the
            // first's — a pale ceiling above both lines at their sum, which reads
            // as a series nobody plotted. Every fill is also declared before every
            // line and pinned below the selection rule, so a later family's area
            // cannot wash over an earlier family's line.
            ForEach(families, id: \.self) { family in
                ForEach(drawn) { bucket in
                    AreaMark(
                        x: .value(xLabel, bucket.start),
                        y: .value(metric.label, metric.value(bucket, family)),
                        series: .value("Model", family.displayName),
                        stacking: .unstacked
                    )
                    .foregroundStyle(
                        LinearGradient(colors: [color(family).opacity(fillOpacity),
                                                color(family).opacity(0.02)],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .interpolationMethod(.linear)
                    .zIndex(-2)
                }
            }

            ForEach(families, id: \.self) { family in
                ForEach(drawn) { bucket in
                    LineMark(
                        x: .value(xLabel, bucket.start),
                        y: .value(metric.label, metric.value(bucket, family)),
                        series: .value("Model", family.displayName)
                    )
                    .foregroundStyle(color(family))
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                }
            }

            // Nothing ran, so there is no family to plot and the lines above draw
            // nothing at all. The zero is still a measurement: draw it as its own
            // neutral baseline, uncoloured because it belongs to no model.
            if families.isEmpty {
                ForEach(drawn) { bucket in
                    LineMark(
                        x: .value(xLabel, bucket.start),
                        y: .value(metric.label, 0),
                        series: .value("Model", "idle")
                    )
                    .foregroundStyle(.tertiary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
                if drawn.count == 1, let only = drawn.first {
                    PointMark(x: .value(xLabel, only.start),
                              y: .value(metric.label, 0))
                        .symbolSize(64)
                        .foregroundStyle(.tertiary)
                }
            }

            // The onion skin, under everything: it is the backdrop the current
            // period is read against, never a series in its own right. Dashed as
            // well as dimmed, so it survives being printed, screenshotted, or
            // looked at by someone who cannot tell the two greys apart.
            ForEach(ghost, id: \.current.start) { pair in
                LineMark(
                    x: .value(xLabel, pair.current.start),
                    y: .value(metric.label, metric.total(pair.previous)),
                    series: .value("Model", "· previous")
                )
                .foregroundStyle(ChartPalette.ghost(scheme))
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round,
                                       lineJoin: .round, dash: [4, 3]))
                .interpolationMethod(.linear)
                .zIndex(-3)
            }

            if showsTotal {
                ForEach(drawn) { bucket in
                    LineMark(
                        x: .value(xLabel, bucket.start),
                        y: .value(metric.label, metric.total(bucket)),
                        series: .value("Model", "· total")
                    )
                    .foregroundStyle(ChartPalette.totalLine(scheme))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.linear)
                    .zIndex(-3)
                }
            }

            // A line needs two vertices. In the first hour of the day the hourly
            // range holds exactly one bucket, and lines and areas alike would draw
            // nothing at all — an empty plot that reads as "no data" over data.
            // A single reading is a point, so draw it as one.
            if drawn.count == 1, let only = drawn.first {
                ForEach(families, id: \.self) { family in
                    PointMark(
                        x: .value(xLabel, only.start),
                        y: .value(metric.label, metric.value(only, family))
                    )
                    .symbolSize(64)
                    .foregroundStyle(color(family))
                }
            }

            if let selected {
                RuleMark(x: .value(xLabel, selected.start))
                    .foregroundStyle(.quaternary)
                    .zIndex(-1)

                // The dots are marks, not an overlay. Hand-placing them from
                // `proxy.position(forX:)` can drift off the line's vertex; drawn
                // here they are placed by the same scale that draws the lines.
                // The pale disc under each is the 2px ring — one mark cannot both
                // fill and stroke — and it keeps two families' dots legible when
                // their values nearly coincide.
                ForEach(families, id: \.self) { family in
                    PointMark(
                        x: .value(xLabel, selected.start),
                        y: .value(metric.label, metric.value(selected, family))
                    )
                    .symbolSize(169)
                    .foregroundStyle(.background)

                    PointMark(
                        x: .value(xLabel, selected.start),
                        y: .value(metric.label, metric.value(selected, family))
                    )
                    .symbolSize(81)
                    .foregroundStyle(color(family))
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartLegend(.hidden)   // The card header carries the legend.
        // With exact-date x values the first and last vertices land on the plot's
        // edges, and an edge tick's centred label would clip at the chart frame.
        // Inset the scale by half the widest label so every tick keeps its label.
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 18))
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                // anchor: custom label content is leading-anchored to its tick by
                // default, which shifts every label half its width off the point;
                // .top pins the label's top-centre to the tick instead.
                // collisionResolution: .automatic drops the edge tick's label as a
                // collision with the plot boundary; the ticks are hand-strided to
                // never collide, so resolution has nothing left to do but harm.
                AxisValueLabel(anchor: .top, collisionResolution: .disabled) {
                    if let date = value.as(Date.self) {
                        Text(date, format: axisFormat)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            }
        }
        .chartYAxis { yAxis }
        // Glass is translucent, and the accent was validated for contrast against a
        // settled surface. Give the plot its own quiet backing so the wallpaper
        // behind the window cannot erode that.
        .chartPlotStyle { plot in
            plot.background(RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.4)))
        }
        // The tooltip rides on top of the chart rather than hanging off the rule as
        // an annotation. An annotation on a full-height RuleMark anchors at the
        // plot's ceiling, so it either overflows the card or — once clamped — draws
        // underneath the plot, because the rule sits at zIndex(-1).
        .chartOverlay { proxy in
            GeometryReader { geo in
                if let selected, let anchor = proxy.plotFrame {
                    let plot = geo[anchor]
                    let centre = plot.minX + (proxy.position(forX: selected.start) ?? 0)

                    let top = plot.minY + 6
                    // Reading the tooltip and reading the line under it are the
                    // same gesture at the top of the plot, and the pane wins.
                    // Yield to the pointer: fade almost out while it is inside
                    // the band the pane covers, and come back on the way down.
                    let inTheWay = hoverY.map { $0 < top + tooltipHeight + 8 } ?? false

                    BucketTooltip(bucket: selected,
                                  previous: previousBucket(for: selected),
                                  previousName: previousName,
                                  showsTotal: showsTotal,
                                  metric: metric, unit: unit)
                        .frame(width: Self.tooltipWidth, alignment: .leading)
                        .background {
                            GeometryReader { tip in
                                Color.clear
                                    .task(id: tip.size.height) { tooltipHeight = tip.size.height }
                            }
                        }
                        .opacity(inTheWay ? 0.12 : 1)
                        .animation(.easeOut(duration: 0.12), value: inTheWay)
                        .offset(x: min(max(centre - Self.tooltipWidth / 2, plot.minX + 4),
                                       plot.maxX - Self.tooltipWidth - 4),
                                y: top)
                }
            }
            // Never swallow the hover that produced the selection.
            .allowsHitTesting(false)
        }
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let point): hoverY = point.y
            case .ended: hoverY = nil
            }
        }
        .frame(height: 206)
    }

    /// One tick on an idle window, four on a window with a range to divide.
    @AxisContentBuilder
    private var yAxis: some AxisContent {
        if isIdle {
            AxisMarks(position: .leading, values: [0.0]) { value in
                AxisGridLine()   // solid hairline; never dashed
                AxisValueLabel { yLabel(value) }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        } else {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                AxisValueLabel { yLabel(value) }
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    @ViewBuilder
    private func yLabel(_ value: AxisValue) -> some View {
        if let amount = value.as(Double.self) {
            Text(metric.format(amount))
        }
    }

    /// The bucket a period ago, found by position rather than by date: the two
    /// windows are aligned by index precisely so that "the same hour yesterday"
    /// survives a month of unequal length and a DST boundary between them.
    private func previousBucket(for bucket: UsageBucket) -> UsageBucket? {
        guard previous.count == buckets.count,
              let index = buckets.firstIndex(where: { $0.start == bucket.start }) else { return nil }
        return previous[index]
    }

    /// Weekdays read fastest over a week and dates over a month, but a day wants
    /// clock times — the unit decides, never the bucket count, or an hourly chart
    /// before 8am would label its hours with weekday names.
    private var axisFormat: Date.FormatStyle {
        if unit == .hour { return .dateTime.hour() }
        return buckets.count <= 7
            ? .dateTime.weekday(.abbreviated)
            : .dateTime.month(.abbreviated).day()
    }

    /// Ticks sit on dates the data actually holds — never `.automatic`, whose
    /// chosen positions need not coincide with a plotted point. Every bucket gets a
    /// label at 7 buckets; past that, an even stride of ~6.
    private var xAxisValues: [Date] {
        guard buckets.count > 7 else { return buckets.map(\.start) }
        let stride = max(1, buckets.count / 6)
        return buckets.indices.filter { $0.isMultiple(of: stride) }.map { buckets[$0].start }
    }

    /// Fixed, so the horizontal clamp can be computed before layout.
    private static let tooltipWidth: CGFloat = 190
}

/// The trend chart is the one place values hide inside a single line, so it is the
/// one place that needs a tooltip. The lists below are direct-labelled.
private struct BucketTooltip: View {
    let bucket: UsageBucket
    /// The same bucket a period ago, when the onion skin is on. The line is where
    /// the comparison is seen; this is where it is read exactly.
    var previous: UsageBucket?
    var previousName = "Previous"
    /// Whether the chart is drawing the current total as a line of its own, so
    /// the tooltip can name the same two series the chart does.
    var showsTotal = false
    let metric: TrendMetric
    let unit: BucketUnit
    @Environment(\.colorScheme) private var scheme

    /// An hour is named by its clock reading; a day by its weekday and date.
    private var title: Date.FormatStyle {
        unit == .hour
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(bucket.start, format: title)
                Spacer(minLength: 8)
                Text(bucket.isCurrent ? "so far" : metric.format(metric.total(bucket)))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))

            if bucket.byFamily.isEmpty {
                Text("No activity")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(bucket.byFamily) { segment in
                    HStack(spacing: 5) {
                        ModelSwatch(family: segment.family, size: 7)
                        Text(segment.family.displayName)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(metric.format(metric.value(bucket, segment.family)))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
                if bucket.isCurrent {
                    Text(unit == .hour ? "This hour, still accruing" : "Today, still accruing")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
            }

            if let previous {
                Divider().padding(.vertical, 1)
                if showsTotal {
                    row(swatch: LineSwatch(color: ChartPalette.totalLine(scheme)),
                        name: "Total",
                        value: metric.format(metric.total(bucket)))
                }
                row(swatch: LineSwatch(color: ChartPalette.ghost(scheme), dashed: true),
                    name: previousName,
                    value: metric.format(metric.total(previous)))
            }
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .glassSurface(cornerRadius: 10)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }

    private func row(swatch: LineSwatch, name: String, value: String) -> some View {
        HStack(spacing: 5) {
            swatch
            Text(name)
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .fontWeight(.medium)
                .monospacedDigit()
        }
        .font(.system(size: 11))
    }
}

/// A stroke of the series' own line, for legends and tooltips: the dash is what
/// tells the onion skin from the current period, so the key has to carry it.
struct LineSwatch: View {
    let color: Color
    var dashed = false

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 1))
            path.addLine(to: CGPoint(x: 13, y: 1))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round,
                                          dash: dashed ? [3, 2.5] : []))
        .frame(width: 13, height: 2)
    }
}

/// The legend, hoisted into the card header so the chart keeps its full height.
/// Present for every series, always — identity is never carried by colour alone.
struct ModelLegend: View {
    let families: [ModelFamily]
    /// Named for the period it draws — "vs. yesterday" beside a day of hours,
    /// "vs. last week" beside a week of days. Empty when the overlay is off.
    var previousName: String?
    var showsTotal = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 12) {
            ForEach(families, id: \.self) { family in
                HStack(spacing: 5) {
                    ModelSwatch(family: family)
                    Text(family.displayName)
                }
            }
            if showsTotal {
                HStack(spacing: 5) {
                    LineSwatch(color: ChartPalette.totalLine(scheme))
                    Text("Total")
                }
            }
            if let previousName {
                HStack(spacing: 5) {
                    LineSwatch(color: ChartPalette.ghost(scheme), dashed: true)
                    Text(previousName)
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}

// MARK: - Composition

/// Where the money went. A row per model: the dollars, the share of spend, and the
/// tokens that bought it — the three numbers you would otherwise have to infer
/// from a bar's length.
struct CostByModelList: View {
    let models: [ModelCost]
    let totalCost: Double
    @Environment(\.colorScheme) private var scheme

    /// Longest bar is the biggest spender, so the shape of the list is the shape of
    /// the bill even when one model dwarfs the rest.
    private var largest: Double {
        max(models.map(\.cost.amount).max() ?? 0, 0.000_001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if models.isEmpty {
                // The card keeps its place in the row: a window where no model ran
                // has a cost breakdown, and its answer is nothing.
                Text("No model ran in this period")
                    .font(.system(size: 12))
                    .foregroundStyle(.tertiary)
            }
            ForEach(models) { model in
                let share = totalCost > 0 ? model.cost.amount / totalCost : 0
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(model.displayName)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 8)
                        Text(model.cost.exactDisplay)
                            .font(.system(size: 13, weight: .semibold))
                            .monospacedDigit()
                    }
                    Meter(fraction: model.cost.amount / largest,
                          fill: ChartPalette.color(for: model.family, scheme: scheme))
                    CardFootnote(text: "\(percent(share)) of spend · "
                                 + "\(NumberFormat.tokens(model.totals.total)) tokens")
                }
            }
        }
    }

    /// Sub-1% shares keep a decimal: "0%" of a bill you were charged for is wrong.
    private func percent(_ value: Double) -> String {
        let p = value * 100
        return p > 0 && p < 1 ? String(format: "%.1f%%", p) : "\(Int(p.rounded()))%"
    }
}

/// Why the bill is small. One series, therefore one hue: shading each bar a
/// different colour would invent four categories where there is one measure. The
/// fade down the rows is rank, not identity — the values are right there.
struct TokenKindList: View {
    let kinds: [KindTotal]
    @Environment(\.colorScheme) private var scheme

    private var largest: Int { max(kinds.map(\.count).max() ?? 0, 1) }
    private static let fades: [Double] = [1.0, 0.82, 0.64, 0.46]

    var body: some View {
        VStack(spacing: 11) {
            ForEach(Array(kinds.enumerated()), id: \.element.id) { index, kind in
                HStack(spacing: 12) {
                    Text(kind.kind.displayName)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(width: 74, alignment: .leading)
                    Meter(fraction: Double(kind.count) / Double(largest),
                          fill: ChartPalette.accent(scheme)
                            .opacity(Self.fades[min(index, Self.fades.count - 1)]),
                          height: 8)
                    Text(NumberFormat.tokens(kind.count))
                        .font(.system(size: 12, weight: .medium))
                        .monospacedDigit()
                        .frame(width: 56, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Table

/// The accessible twin the chart is supposed to have, and the place to read exact
/// numbers rather than approximate a line's height.
struct UsageTable: View {
    let buckets: [UsageBucket]
    /// The onion skin's numbers, aligned to `buckets` index for index. Empty when
    /// the overlay is off — the table is the chart's twin, so it gains and loses
    /// the column exactly when the chart gains and loses the line.
    var previous: [UsageBucket] = []
    var previousName = "Previous"
    let families: [ModelFamily]
    /// The table is the chart's twin, so it reads whichever metric the chart is
    /// drawing. Two views of one dataset disagreeing about their units would be
    /// worse than having no table at all.
    let metric: TrendMetric
    let unit: BucketUnit

    /// The same naming the chart's axis uses, for the same reason.
    private var rowFormat: Date.FormatStyle {
        unit == .hour
            ? .dateTime.hour().minute()
            : .dateTime.weekday(.abbreviated).month(.abbreviated).day()
    }

    /// Rows are drawn from `buckets`, which stops at the last lived bucket, so a
    /// longer previous window simply goes unread rather than adding rows for
    /// hours that have not happened.
    private func previousCell(_ index: Int) -> Text? {
        guard index < previous.count else { return nil }
        return Text(metric.format(metric.total(previous[index])))
    }

    var body: some View {
        VStack(spacing: 0) {
            row(bucket: Text(unit == .hour ? "Hour" : "Day"),
                cells: families.map { Text($0.displayName) }
                    + (previous.isEmpty ? [] : [Text(previousName)]),
                total: Text("Total"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.44)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            Divider()

            ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                row(bucket: Text(bucket.start, format: rowFormat)
                        .fontWeight(.medium),
                    cells: families.map { family in
                        Text(cell(family, in: bucket)).foregroundStyle(.secondary)
                    } + (previousCell(index).map { [$0.foregroundStyle(.tertiary)] } ?? []),
                    total: Text(metric.format(metric.total(bucket))).fontWeight(.semibold))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .padding(.vertical, 7)
                Divider()
            }
        }
    }

    /// An unused model reads "—", not "0": the model was not run, it did not run
    /// to zero. The chart cannot make that distinction — a line has to be
    /// somewhere — which is exactly why the table is worth keeping.
    private func cell(_ family: ModelFamily, in bucket: UsageBucket) -> String {
        guard bucket.byFamily.contains(where: { $0.family == family }) else { return "—" }
        return metric.format(metric.value(bucket, family))
    }

    private func row(bucket: Text, cells: [Text], total: Text) -> some View {
        WeightedHStack(weights: [1.1] + Array(repeating: 1, count: cells.count + 1), spacing: 8) {
            bucket.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cell.frame(maxWidth: .infinity, alignment: .trailing)
            }
            total.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}
