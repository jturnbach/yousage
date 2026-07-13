import AppKit
import Foundation

/// Writes the drawn range out as CSV — the table view's rows, exactly as shown, so
/// what lands in the file is what the window claimed.
enum UsageExport {
    /// Presents a save panel and writes the file. Returns nil when the user
    /// cancels; throws only when the write itself fails.
    @MainActor
    static func save(_ breakdown: UsageBreakdown) throws -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = filename(breakdown)
        panel.title = "Export usage"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        try csv(breakdown).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    static func filename(_ breakdown: UsageBreakdown) -> String {
        let day = breakdown.generatedAt.formatted(.iso8601.year().month().day().dateSeparator(.dash))
        return "YouSage \(breakdown.range.label) \(day).csv"
    }

    static func csv(_ breakdown: UsageBreakdown) -> String {
        let families = ModelFamily.allCases.filter { family in
            breakdown.days.contains { $0.byFamily.contains { $0.family == family } }
        }

        var rows: [[String]] = [
            ["Day"] + families.map(\.displayName) + ["Total tokens", "Cost (USD)"]
        ]
        for day in breakdown.days {
            let counts = families.map { family -> String in
                let tokens = day.byFamily.first { $0.family == family }?.totals.total ?? 0
                return String(tokens)
            }
            rows.append(
                [day.day.formatted(.iso8601.year().month().day().dateSeparator(.dash))]
                + counts
                // Raw counts and unrounded dollars: a spreadsheet wants the number,
                // not the compacted "676.6M" the window shows a reader.
                + [String(day.totals.total), String(format: "%.4f", day.cost.amount)]
            )
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// RFC 4180: quote anything holding a comma, quote, or newline, and double the
    /// quotes inside it. Model display names are tame today, but a file format is
    /// not the place to bet on that.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
