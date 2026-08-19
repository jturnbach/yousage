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

    /// `timeZone` is a parameter rather than a constant so the tests can pin it;
    /// the app always exports in the zone the buckets were counted in.
    static func csv(_ breakdown: UsageBreakdown, timeZone: TimeZone = .current) -> String {
        let families = ModelFamily.allCases.filter { family in
            breakdown.buckets.contains { $0.byFamily.contains { $0.family == family } }
        }
        let hourly = breakdown.range.unit == .hour

        var rows: [[String]] = [
            [hourly ? "Hour" : "Day"] + families.map(\.displayName)
            + ["Total tokens", "Cost (USD)"]
        ]
        for bucket in breakdown.buckets {
            let counts = families.map { family -> String in
                let tokens = bucket.byFamily.first { $0.family == family }?.totals.total ?? 0
                return String(tokens)
            }
            rows.append(
                [timestamp(bucket.start, hourly: hourly, timeZone: timeZone)]
                + counts
                // Raw counts and unrounded dollars: a spreadsheet wants the number,
                // not the compacted "676.6M" the window shows a reader.
                + [String(bucket.totals.total), String(format: "%.4f", bucket.cost.amount)]
            )
        }
        return rows.map { $0.map(escape).joined(separator: ",") }.joined(separator: "\n") + "\n"
    }

    /// Buckets are local instants, so they are written in the local zone. The zone
    /// has to be given explicitly: `.iso8601` formats in GMT unless told otherwise,
    /// which would shift every hour — and, east of Greenwich, every date.
    private static func timestamp(_ date: Date, hourly: Bool, timeZone: TimeZone) -> String {
        let day = Date.ISO8601FormatStyle(timeZone: timeZone)
            .year().month().day().dateSeparator(.dash)
        guard hourly else { return date.formatted(day) }
        return date.formatted(day.dateTimeSeparator(.space).time(includingFractionalSeconds: false))
    }

    /// RFC 4180: quote anything holding a comma, quote, or newline, and double the
    /// quotes inside it. Model display names are tame today, but a file format is
    /// not the place to bet on that.
    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
