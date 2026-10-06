import Foundation
import Testing
@testable import YouSage

/// Reads a throwaway transcript tree, so the windows are tested through the same
/// parse-and-bucket path the app uses rather than around it.
private func transcripts(_ events: [(Date, Int)]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("yousage-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("project"),
                                            withIntermediateDirectories: true)
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let lines = events.enumerated().map { index, event in
        """
        {"type":"assistant","requestId":"req-\(index)","timestamp":"\(stamp.string(from: event.0))",\
        "message":{"id":"msg-\(index)","model":"claude-opus-4-8",\
        "usage":{"input_tokens":\(event.1),"output_tokens":0,\
        "cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
        """
    }
    try (lines.joined(separator: "\n") + "\n")
        .write(to: root.appendingPathComponent("project/session.jsonl"), atomically: true, encoding: .utf8)
    return root
}

@Test func todayStartsAtLocalMidnightAndTheRollingWeekDoesNot() async throws {
    // Anchored to the machine's own midnight, so the test means the same thing
    // whatever time of day it runs.
    let calendar = Calendar.current
    let now = Date()
    let midnight = calendar.startOfDay(for: now)
    let root = try transcripts([
        (midnight.addingTimeInterval(1), 500),                  // just after midnight
        (midnight.addingTimeInterval(-3_600), 700),             // late yesterday
        (midnight.addingTimeInterval(-3 * 24 * 3_600), 900)     // three days ago
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let tracker = TokenTracker(root: root)
    let report = try #require(await tracker.report(sessionResetsAt: nil, weekResetsAt: nil,
                                                  now: now, calendar: calendar))

    // Yesterday's late turn is inside the rolling week and outside today, which
    // is the whole point of showing the two separately.
    #expect(report.today.input == 500)
    #expect(report.today.messages == 1)
    #expect(report.week.input == 2_100)
}

@Test func aDayWithNothingOnItIsZeroRatherThanTheDayBefore() async throws {
    let calendar = Calendar.current
    let now = Date()
    let midnight = calendar.startOfDay(for: now)
    let root = try transcripts([(midnight.addingTimeInterval(-7_200), 400)])
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try #require(await TokenTracker(root: root)
        .report(sessionResetsAt: nil, weekResetsAt: nil, now: now, calendar: calendar))
    #expect(report.today.isEmpty)
    #expect(report.todayCost.amount == 0)
    // The popover still has something to show, so it stays open on the day's zero
    // instead of hiding the section that says so.
    #expect(report.hasAnyData)
}

@Test func todaysDollarsArePricedTheSameWayTheSessionsAre() async throws {
    let calendar = Calendar.current
    let now = Date()
    let midnight = calendar.startOfDay(for: now)
    let root = try transcripts([(midnight.addingTimeInterval(30), 1_000_000)])
    defer { try? FileManager.default.removeItem(at: root) }

    let report = try #require(await TokenTracker(root: root)
        .report(sessionResetsAt: nil, weekResetsAt: nil, now: now, calendar: calendar))
    #expect(report.todayCost.amount == Pricing.cost(report.today, model: "claude-opus-4-8"))
    #expect(report.todayCost.isComplete)
}
