import Charts
import SwiftUI

// MARK: - Trend

/// Daily tokens, stacked by model family.
///
/// Family, not model id: two versions of one family would stack as two segments
/// of the same hue. They price identically, and the cost list keeps the versions
/// apart, so nothing is lost.
struct TrendChart: View {
    let days: [DayUsage]
    @Environment(\.colorScheme) private var scheme
    @State private var selectedDay: Date?

    /// Only families that actually appear, in declaration order, so the legend
    /// never advertises a model you did not use.
    private var families: [ModelFamily] {
        ModelFamily.allCases.filter { family in
            days.contains { $0.byFamily.contains { $0.family == family } }
        }
    }

    private var selected: DayUsage? {
        guard let selectedDay else { return nil }
        return days.first { Calendar.current.isDate($0.day, inSameDayAs: selectedDay) }
    }

    var body: some View {
        Chart {
            ForEach(days) { day in
                ForEach(day.byFamily) { segment in
                    BarMark(
                        x: .value("Day", day.day, unit: .day),
                        y: .value("Tokens", segment.totals.total)
                    )
                    .foregroundStyle(by: .value("Model", segment.family.displayName))
                    .opacity(day.isToday ? 0.55 : 1)
                    .cornerRadius(2)
                }
            }

            if let selected {
                RuleMark(x: .value("Day", selected.day, unit: .day))
                    .foregroundStyle(.quaternary)
                    .zIndex(-1)
                    // The rule spans the whole plot, so `.top` anchors at the
                    // plot's ceiling and the annotation lands outside it. Clamp
                    // both axes to the chart or the tooltip is cropped by the
                    // card above — which is exactly what happened.
                    .annotation(position: .top, spacing: 4,
                                overflowResolution: .init(x: .fit(to: .chart),
                                                          y: .fit(to: .chart))) {
                        DayTooltip(day: selected)
                    }
            }
        }
        .chartForegroundStyleScale(
            domain: families.map(\.displayName),
            range: families.map { ChartPalette.color(for: $0, scheme: scheme) }
        )
        .chartXSelection(value: $selectedDay)
        .chartXAxis {
            AxisMarks(values: days.map(\.day)) { _ in
                AxisValueLabel(format: .dateTime.weekday(.abbreviated))
            }
        }
        .chartYAxis {
            // Leading, to agree with the two horizontal charts below, which name
            // their rows down the left edge.
            AxisMarks(position: .leading) { value in
                AxisGridLine()   // solid hairline; never dashed
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(NumberFormat.tokens(count))
                    }
                }
            }
        }
        // Glass is translucent, and the bar hues were validated for contrast
        // against a settled surface. Give the plot its own quiet backing so the
        // wallpaper behind the window cannot erode that.
        .chartPlotStyle { plot in
            plot.background(
                RoundedRectangle(cornerRadius: 8).fill(.background.opacity(0.4))
            )
        }
        .chartLegend(position: .bottom, alignment: .leading, spacing: 12)
        .frame(minHeight: 220)
    }
}

/// The trend chart is the one place values hide inside stacked segments, so it is
/// the one place that needs a tooltip. The composition charts are direct-labelled.
private struct DayTooltip: View {
    let day: DayUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(day.day, format: .dateTime.weekday(.wide).month().day())
                .font(.caption.bold())
            ForEach(day.byFamily) { segment in
                HStack(spacing: 6) {
                    Text(segment.family.displayName)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 10)
                    Text(NumberFormat.tokens(segment.totals.total)).monospacedDigit()
                }
            }
            Divider()
            HStack(spacing: 6) {
                Text(day.isToday ? "So far today" : "Total").foregroundStyle(.secondary)
                Spacer(minLength: 10)
                Text(NumberFormat.tokens(day.totals.total)).monospacedDigit()
                Text("·").foregroundStyle(.tertiary)
                Text(day.cost.display).monospacedDigit()
            }
        }
        .font(.caption)
        .padding(10)
        .glassSurface(cornerRadius: 10)
        .fixedSize()
    }
}

// MARK: - Composition

/// Where the money went. Bars carry their model's family colour, so Opus is the
/// same terracotta here as in the trend chart above.
struct CostByModelChart: View {
    let models: [ModelCost]
    @Environment(\.colorScheme) private var scheme

    private var upperBound: Double {
        max((models.map(\.cost.amount).max() ?? 0) * 1.3, 0.01)
    }

    var body: some View {
        Chart(models) { model in
            BarMark(
                x: .value("Cost", model.cost.amount),
                y: .value("Model", model.displayName)
            )
            .foregroundStyle(ChartPalette.color(for: model.family, scheme: scheme))
            .cornerRadius(2)
            .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                Text(model.cost.display)
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        // Every value is direct-labelled, so an x-axis scale would be chrome.
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...upperBound)
        .chartYAxis { AxisMarks(preset: .aligned, position: .leading) { AxisValueLabel() } }
        .frame(height: CGFloat(models.count) * 30 + 16)
    }
}

/// Why the bill is small. One series, therefore one colour: shading each bar
/// darker-where-bigger would encode bar length twice and say nothing new.
struct TokenKindChart: View {
    let kinds: [KindTotal]
    @Environment(\.colorScheme) private var scheme

    private var upperBound: Double {
        max(Double(kinds.map(\.count).max() ?? 0) * 1.3, 1)
    }

    var body: some View {
        Chart(kinds) { kind in
            BarMark(
                x: .value("Tokens", kind.count),
                y: .value("Kind", kind.kind.displayName)
            )
            .foregroundStyle(ChartPalette.sequential(scheme))
            .cornerRadius(2)
            .annotation(position: .trailing, alignment: .leading, spacing: 6) {
                Text(NumberFormat.tokens(kind.count))
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .chartXAxis(.hidden)
        .chartXScale(domain: 0...upperBound)
        .chartYAxis { AxisMarks(preset: .aligned, position: .leading) { AxisValueLabel() } }
        .frame(height: CGFloat(kinds.count) * 30 + 16)
    }
}
