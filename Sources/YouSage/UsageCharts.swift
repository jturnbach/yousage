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
    let buckets: [UsageBucket]
    let families: [ModelFamily]
    let metric: TrendMetric
    /// Day or hour. The chart draws the buckets it is handed either way; the unit
    /// only decides how the axis, the ticks, and the tooltip name them.
    let unit: BucketUnit
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDate: Date?

    /// Nearest bucket to the hover, so the snap boundary is the midpoint between
    /// points rather than midnight.
    private var selected: UsageBucket? {
        guard let selectedDate else { return nil }
        return buckets.min {
            abs($0.start.timeIntervalSince(selectedDate)) < abs($1.start.timeIntervalSince(selectedDate))
        }
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
        Chart {
            // `stacking: .unstacked` is load-bearing: area marks stack by default,
            // so two families would draw the second one's fill on top of the
            // first's — a pale ceiling above both lines at their sum, which reads
            // as a series nobody plotted. Every fill is also declared before every
            // line and pinned below the selection rule, so a later family's area
            // cannot wash over an earlier family's line.
            ForEach(families, id: \.self) { family in
                ForEach(buckets) { bucket in
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
                ForEach(buckets) { bucket in
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

            // A line needs two vertices. In the first hour of the day the hourly
            // range holds exactly one bucket, and lines and areas alike would draw
            // nothing at all — an empty plot that reads as "no data" over data.
            // A single reading is a point, so draw it as one.
            if buckets.count == 1, let only = buckets.first {
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
        .chartXScale(range: .plotDimension(padding: 18))
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
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()   // solid hairline; never dashed
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(metric.format(amount))
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            }
        }
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

                    BucketTooltip(bucket: selected, metric: metric, unit: unit)
                        .frame(width: Self.tooltipWidth, alignment: .leading)
                        .offset(x: min(max(centre - Self.tooltipWidth / 2, plot.minX + 4),
                                       plot.maxX - Self.tooltipWidth - 4),
                                y: plot.minY + 6)
                }
            }
            // Never swallow the hover that produced the selection.
            .allowsHitTesting(false)
        }
        .frame(height: 206)
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
    let metric: TrendMetric
    let unit: BucketUnit

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
        }
        .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
        .glassSurface(cornerRadius: 10)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}

/// The legend, hoisted into the card header so the chart keeps its full height.
/// Present for every series, always — identity is never carried by colour alone.
struct ModelLegend: View {
    let families: [ModelFamily]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(families, id: \.self) { family in
                HStack(spacing: 5) {
                    ModelSwatch(family: family)
                    Text(family.displayName)
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

    var body: some View {
        VStack(spacing: 0) {
            row(bucket: Text(unit == .hour ? "Hour" : "Day"),
                cells: families.map { Text($0.displayName) },
                total: Text("Total"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.44)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            Divider()

            ForEach(buckets) { bucket in
                row(bucket: Text(bucket.start, format: rowFormat)
                        .fontWeight(.medium),
                    cells: families.map { family in
                        Text(cell(family, in: bucket)).foregroundStyle(.secondary)
                    },
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
