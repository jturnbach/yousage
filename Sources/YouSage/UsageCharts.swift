import Charts
import SwiftUI

// MARK: - Trend

/// Daily tokens as an area, with the model split held in the hover tooltip.
///
/// The area charts the *total*, because the total is the shape of the week — a
/// stack would ask the reader to compare segment heights that do not share a
/// baseline. The per-model numbers are exact in the tooltip and in the table,
/// which is where exactness belongs.
struct TrendChart: View {
    let days: [DayUsage]
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDay: Date?

    private var selected: DayUsage? {
        guard let selectedDay else { return nil }
        return days.first { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
    }

    private var accent: Color { ChartPalette.accent(scheme) }

    var body: some View {
        Chart {
            ForEach(days) { day in
                AreaMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Tokens", day.totals.total)
                )
                .foregroundStyle(
                    LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.02)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("Day", day.day, unit: .day),
                    y: .value("Tokens", day.totals.total)
                )
                .foregroundStyle(accent)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.linear)
            }

            if let selected {
                RuleMark(x: .value("Day", selected.day, unit: .day))
                    .foregroundStyle(.quaternary)
                    .zIndex(-1)

                // The dot is a mark, not an overlay. Hand-placing it from
                // `proxy.position(forX:)` puts it half a day off the line's vertex,
                // because the day-binned scale anchors marks differently than the
                // proxy reports. Drawn here, it is placed by the same scale that
                // draws the line, so it cannot drift. The pale disc under it is the
                // 2px ring — one mark cannot both fill and stroke.
                PointMark(
                    x: .value("Day", selected.day, unit: .day),
                    y: .value("Tokens", selected.totals.total)
                )
                .symbolSize(169)
                .foregroundStyle(.background)

                PointMark(
                    x: .value("Day", selected.day, unit: .day),
                    y: .value("Tokens", selected.totals.total)
                )
                .symbolSize(81)
                .foregroundStyle(accent)
            }
        }
        .chartXSelection(value: $selectedDay)
        .chartLegend(.hidden)   // The card header carries the legend.
        .chartXAxis {
            AxisMarks(values: xAxisValues) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(date, format: days.count <= 7
                             ? .dateTime.weekday(.abbreviated)
                             : .dateTime.month(.abbreviated).day())
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
                    if let count = value.as(Int.self) {
                        Text(NumberFormat.tokens(count))
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
                    let centre = plot.minX + (proxy.position(forX: selected.day) ?? 0)

                    DayTooltip(day: selected)
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

    /// Every day gets a label at 7 days; past that they would collide, so Charts
    /// picks a readable subset.
    private var xAxisValues: AxisMarkValues {
        days.count <= 7 ? .automatic(desiredCount: days.count) : .automatic(desiredCount: 6)
    }

    /// Fixed, so the horizontal clamp can be computed before layout.
    private static let tooltipWidth: CGFloat = 190
}

/// The trend chart is the one place values hide inside a single line, so it is the
/// one place that needs a tooltip. The lists below are direct-labelled.
private struct DayTooltip: View {
    let day: DayUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                Spacer(minLength: 8)
                Text(day.isToday ? "so far" : NumberFormat.tokens(day.totals.total))
                    .monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))

            if day.byFamily.isEmpty {
                Text("No activity")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(day.byFamily) { segment in
                    HStack(spacing: 5) {
                        ModelSwatch(family: segment.family, size: 7)
                        Text(segment.family.displayName)
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 12)
                        Text(NumberFormat.tokens(segment.totals.total))
                            .fontWeight(.medium)
                            .monospacedDigit()
                    }
                    .font(.system(size: 11))
                }
                if day.isToday {
                    Text("Today, still accruing")
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
struct DayTable: View {
    let days: [DayUsage]
    let families: [ModelFamily]

    var body: some View {
        VStack(spacing: 0) {
            row(day: Text("Day"),
                cells: families.map { Text($0.displayName) },
                total: Text("Total"))
                .font(.system(size: 11, weight: .semibold))
                .textCase(.uppercase)
                .tracking(0.44)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 8)
            Divider()

            ForEach(days) { day in
                row(day: Text(day.day, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                        .fontWeight(.medium),
                    cells: families.map { family in
                        Text(tokens(of: family, in: day)).foregroundStyle(.secondary)
                    },
                    total: Text(NumberFormat.tokens(day.totals.total)).fontWeight(.semibold))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .padding(.vertical, 7)
                Divider()
            }
        }
    }

    /// An unused model reads "—", not "0": the model was not run, it did not run
    /// to zero.
    private func tokens(of family: ModelFamily, in day: DayUsage) -> String {
        guard let segment = day.byFamily.first(where: { $0.family == family }) else { return "—" }
        return NumberFormat.tokens(segment.totals.total)
    }

    private func row(day: Text, cells: [Text], total: Text) -> some View {
        WeightedHStack(weights: [1.1] + Array(repeating: 1, count: cells.count + 1), spacing: 8) {
            day.frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                cell.frame(maxWidth: .infinity, alignment: .trailing)
            }
            total.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .lineLimit(1)
    }
}
