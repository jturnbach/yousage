import Foundation
import Testing
@testable import YouSage

/// Times what one click on the range picker or the paging buttons costs: the
/// tracker's report, breakdown and history over a realistic event load — this
/// Mac's transcripts plus a remote source holding a full retention window.
///
/// Opt-in, because timings are not assertions: `YOUSAGE_BENCH=1 swift test
/// --filter Benchmark`. Prints milliseconds per operation, best of five.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["YOUSAGE_BENCH"] != nil),
       .serialized)
struct Benchmark {
    static let localCount = 8_000
    static let remoteCount = 50_000
    static let models = ["claude-opus-4-8", "claude-opus-4-8[1m]", "claude-sonnet-5",
                         "claude-haiku-4-5-20251001", "claude-fable-5", "some-unpriced-model"]

    /// Local transcripts over the last 30 days, split across a few files.
    static func transcripts(now: Date) throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("yousage-bench-\(UUID().uuidString)", isDirectory: true)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var rng = SystemRandomNumberGenerator()
        var files: [[String]] = Array(repeating: [], count: 8)
        for i in 0..<localCount {
            let date = now.addingTimeInterval(-Double.random(in: 0..<(30 * 86_400), using: &rng))
            let model = models[i % 4]
            files[i % files.count].append("""
                {"type":"assistant","requestId":"local-\(i)","timestamp":"\(stamp.string(from: date))",\
                "message":{"id":"msg-\(i)","model":"\(model)",\
                "usage":{"input_tokens":\(i % 900 + 10),"output_tokens":\(i % 300),\
                "cache_creation_input_tokens":\(i % 5000),"cache_read_input_tokens":\(i % 70000)}}}
                """)
        }
        for (n, lines) in files.enumerated() {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: project.appendingPathComponent("s\(n).jsonl"), atomically: true, encoding: .utf8)
        }
        return root
    }

    static func remote(now: Date, count: Int = remoteCount, days: Double = 180,
                       prefix: String = "remote-") -> [RemoteUsageEvent] {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return (0..<count).map { i in
            let date = now.addingTimeInterval(-Double(i) / Double(count) * days * 86_400)
            return RemoteUsageEvent(id: "\(prefix)\(i)", ts: stamp.string(from: date),
                                    model: models[i % models.count],
                                    input: i % 800 + 5, output: i % 400,
                                    cacheRead: i % 60_000, cacheWrite: i % 4_000)
        }
    }

    static func time(_ label: String, runs: Int = 5, _ body: () async -> Void) async -> Double {
        var best = Double.infinity
        for _ in 0..<runs {
            let start = DispatchTime.now().uptimeNanoseconds
            await body()
            best = min(best, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        print("BENCH " + label.padding(toLength: 40, withPad: " ", startingAt: 0)
              + String(format: "%9.2f ms", best))
        return best
    }

    @Test func rangeSwitch() async throws {
        let now = Date()
        let root = try Self.transcripts(now: now)
        defer { try? FileManager.default.removeItem(at: root) }
        let tracker = TokenTracker(root: root)
        let remote = Self.remote(now: now)

        await Self.time("mergeRemote full (50k)", runs: 3) {
            await tracker.mergeRemote(source: "tserver", name: "TServer", events: remote, replace: true)
        }
        // A 30-second poll: the server's 15-minute overlap re-sends events
        // already held, plus a few new ones.
        let overlap = Self.remote(now: now, count: 40, days: 15.0 / 1440, prefix: "remote-")
        await Self.time("mergeRemote incremental (40)") {
            await tracker.mergeRemote(source: "tserver", name: "TServer", events: overlap, replace: false)
        }
        _ = await tracker.report(sessionResetsAt: nil, weekResetsAt: nil, now: now)

        await Self.time("report") {
            _ = await tracker.report(sessionResetsAt: nil, weekResetsAt: nil, now: now)
        }
        await Self.time("history") { _ = await tracker.history(now: now) }

        let switches: [(UsageRange, Int)] = [(.today, 0), (.week, 0), (.month, 0), (.quarter, 0),
                                             (.week, 1), (.week, 10), (.today, 3)]
        for (range, offset) in switches {
            await Self.time("breakdown \(range.label) offset \(offset)") {
                _ = await tracker.breakdown(range: range, offset: offset, now: now)
            }
        }
        // What AppState runs for one click: the bucketing alone, over the
        // events already held.
        for (range, offset) in switches {
            await Self.time("click \(range.label) offset \(offset)") {
                _ = await tracker.breakdown(range: range, offset: offset, now: now, rescan: false)
            }
        }
        // A whole refresh: rescan, report, breakdown, history — what a click
        // cost before it was split from the refresh, and what a poll costs.
        for (range, offset) in switches {
            await Self.time("refresh \(range.label) offset \(offset)") {
                _ = await tracker.report(sessionResetsAt: nil, weekResetsAt: nil, now: now)
                _ = await tracker.breakdown(range: range, offset: offset, now: now)
                _ = await tracker.history(now: now)
            }
        }
    }
}
