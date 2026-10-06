import SwiftUI

/// Every retained day as one cell, a week to a column — the shape of a habit
/// rather than the shape of a window. The trend chart answers "how much this
/// week"; this answers "which days do I actually work", which no 7- or 30-day
/// window can, because the answer is the pattern between the windows.
///
/// Ink carries the value, and ink alone would be a colour-only encoding — so
/// every cell also names its day and its figure in a tooltip, and the legend
/// spells out which end is which.
struct ActivityGrid: View {
    let days: [DayUsage]
    /// The same measure the trend chart is plotting. Two views of one history
    /// disagreeing about their units would be worse than having no grid at all.
    let metric: TrendMetric
    var calendar: Calendar = .current
    @Environment(\.colorScheme) private var scheme
    @State private var hovered: HoverTarget?

    /// The cell under the pointer, with the frame it occupies, so the readout can
    /// be placed against it. Carried together because either one alone would let
    /// the text and the cell it describes disagree for a frame.
    private struct HoverTarget: Equatable {
        let day: DayUsage
        let rect: CGRect
    }

    private static let space = "activity-grid"
    /// Fixed, so the horizontal clamp can be computed before the text is laid out
    /// — the same reason the chart's tooltip is a fixed width.
    private static let tooltipWidth: CGFloat = 168
    private static let tooltipHeight: CGFloat = 44

    /// Column-major weeks, oldest first, seven slots each. nil where the week
    /// runs past an end of the retained history: the first column usually starts
    /// mid-week, and the last stops on today. A blank slot is not a quiet day.
    ///
    /// Static and testable, because this is where an off-by-one would put every
    /// cell on the wrong weekday — a mistake a screenshot cannot catch, since the
    /// grid looks exactly as plausible shifted by a day.
    static func weeks(of days: [DayUsage], calendar: Calendar) -> [[DayUsage?]] {
        var columns: [[DayUsage?]] = []
        var column = [DayUsage?](repeating: nil, count: 7)
        var previous = -1
        for day in days {
            let row = row(of: day.start, calendar: calendar)
            // Days arrive consecutive, so the row only steps backwards when the
            // week turns over — no date arithmetic needed to find the boundary.
            if row < previous {
                columns.append(column)
                column = [DayUsage?](repeating: nil, count: 7)
            }
            column[row] = day
            previous = row
        }
        if previous >= 0 { columns.append(column) }
        return columns
    }

    /// Row 0 is the calendar's own first weekday — Sunday here, Monday where the
    /// machine says so — so a reader's weekend sits where they expect it.
    static func row(of date: Date, calendar: Calendar) -> Int {
        let weekday = calendar.component(.weekday, from: date)
        return (weekday - calendar.firstWeekday + 7) % 7
    }

    /// The busiest day sets the darkest step. Taken over the whole history rather
    /// than the drawn window, because the grid *is* the whole history.
    private var peak: Double { days.map { metric.value($0) }.max() ?? 0 }

    var body: some View {
        let columns = Self.weeks(of: days, calendar: calendar)

        let grid = CalendarGridLayout(columns: columns.count) {
            ForEach(Array(monthLabels(for: columns).enumerated()), id: \.offset) { _, name in
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(0..<7, id: \.self) { row in
                Text(weekdayLabel(row))
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ForEach(Array(columns.enumerated()), id: \.offset) { _, week in
                ForEach(Array(week.enumerated()), id: \.offset) { _, day in
                    cell(day)
                }
            }
        }

        grid
            .coordinateSpace(name: Self.space)
            .overlay { readout }
    }

    /// The hovered day, named and counted. A tooltip rather than a fixed readout
    /// in the header: with 180 cells the pointer is already at the thing being
    /// asked about, and an answer that appears somewhere else makes the reader
    /// look away from their own question.
    @ViewBuilder
    private var readout: some View {
        GeometryReader { geo in
            if let hovered {
                // Above the cell, except in the top rows where above is off the
                // card — there it drops below, which is what the pointer leaves
                // uncovered anyway.
                let below = hovered.rect.minY < Self.tooltipHeight + 8
                DayTooltip(date: dateName(hovered.day), value: valueName(hovered.day))
                    .frame(width: Self.tooltipWidth)
                    .offset(x: min(max(hovered.rect.midX - Self.tooltipWidth / 2, 0),
                                   max(geo.size.width - Self.tooltipWidth, 0)),
                            y: below ? hovered.rect.maxY + 6
                                     : hovered.rect.minY - Self.tooltipHeight - 6)
            }
        }
        // Never swallow the hover that produced the readout.
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func cell(_ day: DayUsage?) -> some View {
        if let day {
            // The reader is inside the geometry the layout already computed, so
            // the frame it reports is the cell itself — no second guess at where
            // the pointer is.
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(ChartPalette.heat(level: HeatScale.level(metric.value(day), peak: peak),
                                            scheme: scheme))
                    .onHover { inside in
                        if inside {
                            hovered = HoverTarget(day: day, rect: geo.frame(in: .named(Self.space)))
                        } else if hovered?.day.id == day.id {
                            // Only the cell that claimed the readout may clear it,
                            // or leaving one cell would erase its neighbour's.
                            hovered = nil
                        }
                    }
            }
            .accessibilityLabel(Text("\(dateName(day)) · \(valueName(day))"))
        } else {
            Color.clear
        }
    }

    /// "Mon, Jul 6" — the weekday is half the point of a grid arranged by weekday.
    private func dateName(_ day: DayUsage) -> String {
        var format = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        return day.start.formatted(format)
    }

    /// A cell with nothing in it still has an answer, and it is not "0" — the
    /// grid is read for its gaps as much as for its ink.
    private func valueName(_ day: DayUsage) -> String {
        let value = metric.value(day)
        return value > 0 ? metric.describe(value) : "No usage"
    }

    /// A month is named at the column its first retained day falls in, and never
    /// within two columns of the last name — at a narrow width the labels would
    /// otherwise collide into one grey smear. The last two columns go unlabelled
    /// so a name cannot run off the card's edge.
    private func monthLabels(for columns: [[DayUsage?]]) -> [String] {
        var names = [String](repeating: "", count: columns.count)
        var format = Date.FormatStyle.dateTime.month(.abbreviated)
        format.calendar = calendar
        format.timeZone = calendar.timeZone

        var lastMonth = -1
        var lastLabelled = -2
        for (index, week) in columns.enumerated() {
            guard let first = week.compactMap({ $0 }).first else { continue }
            let month = calendar.component(.month, from: first.start)
            defer { lastMonth = month }
            guard month != lastMonth,
                  index - lastLabelled >= 2,
                  index <= columns.count - 3 else { continue }
            names[index] = first.start.formatted(format)
            lastLabelled = index
        }
        return names
    }

    /// Alternate rows only, as GitHub's grid does: seven stacked three-letter
    /// words at cell height would be a wall of type beside a wall of colour.
    private func weekdayLabel(_ row: Int) -> String {
        guard row % 2 == 1 else { return "" }
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == 7 else { return "" }
        return symbols[(calendar.firstWeekday - 1 + row) % 7]
    }
}

/// Squares that fill the width they are given, in a fixed number of columns.
///
/// A `Layout` rather than a `GeometryReader`: the month labels, the weekday
/// gutter, and the cells all have to agree on one cell size, and a reader that
/// hands its width back through state would settle a frame late — a visible
/// jump every time the window is resized. Here the size is computed once, by the
/// same code that places all three.
///
/// Subviews arrive in a fixed order: one label per column, then seven weekday
/// labels, then `columns × 7` cells, column-major. The caller emits every slot,
/// empty ones included, so an index can never mean two different things.
private struct CalendarGridLayout: Layout {
    let columns: Int
    var rows = 7
    /// Room for "Wed" beside the grid.
    var gutter: CGFloat = 30
    var gap: CGFloat = 4
    var monthRow: CGFloat = 15
    /// Cells stop growing before they read as tiles rather than days; they stop
    /// shrinking while they are still a click target and still legible as colour.
    var maxCell: CGFloat = 22
    var minCell: CGFloat = 7

    private func cellSize(in width: CGFloat) -> CGFloat {
        guard columns > 0 else { return minCell }
        let free = width - gutter - CGFloat(columns - 1) * gap
        return min(maxCell, max(minCell, (free / CGFloat(columns)).rounded(.down)))
    }

    private func intrinsicWidth() -> CGFloat {
        gutter + CGFloat(max(columns, 1)) * (maxCell + gap) - gap
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = (proposal.width ?? 0) > 0 ? proposal.width! : intrinsicWidth()
        let cell = cellSize(in: width)
        return CGSize(width: width, height: monthRow + CGFloat(rows) * (cell + gap) - gap)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        let cell = cellSize(in: bounds.width)
        let pitch = cell + gap
        let top = bounds.minY + monthRow
        var index = 0

        func place(_ point: CGPoint, _ anchor: UnitPoint, _ size: ProposedViewSize) {
            guard index < subviews.count else { return }
            subviews[index].place(at: point, anchor: anchor, proposal: size)
            index += 1
        }

        for column in 0..<columns {
            place(CGPoint(x: bounds.minX + gutter + CGFloat(column) * pitch, y: bounds.minY),
                  .topLeading, .unspecified)
        }
        for row in 0..<rows {
            place(CGPoint(x: bounds.minX, y: top + CGFloat(row) * pitch + cell / 2),
                  .leading, ProposedViewSize(width: gutter - gap, height: cell))
        }
        for column in 0..<columns {
            for row in 0..<rows {
                place(CGPoint(x: bounds.minX + gutter + CGFloat(column) * pitch,
                              y: top + CGFloat(row) * pitch),
                      .topLeading, ProposedViewSize(width: cell, height: cell))
            }
        }
    }
}

/// What one cell is worth. Styled as the trend chart's tooltip is, because it
/// answers the same kind of question and a second visual language for it would
/// be one the reader has to learn twice.
private struct DayTooltip: View {
    let date: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(date)
                .font(.system(size: 11, weight: .semibold))
            Text(value)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 7, leading: 10, bottom: 7, trailing: 10))
        .glassSurface(cornerRadius: 9)
        .shadow(color: .black.opacity(0.28), radius: 12, y: 6)
    }
}

/// "Less ▫▪▪▪▪ More" — the key to the only encoding on the page that is colour
/// and nothing else.
struct HeatLegend: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 4) {
            Text("Less")
            ForEach(0...HeatScale.steps, id: \.self) { level in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(ChartPalette.heat(level: level, scheme: scheme))
                    .frame(width: 10, height: 10)
            }
            Text("More")
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
