import Foundation
import Testing
@testable import YouSage

private func iso(_ date: Date) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: date)
}

private func remoteEvent(_ id: String, minutesAgo: Double, model: String = "claude-opus-4-8",
                         output: Int = 100) -> RemoteUsageEvent {
    RemoteUsageEvent(id: id, ts: iso(Date().addingTimeInterval(-minutesAgo * 60)), model: model,
                     input: 10, output: output, cacheRead: 1000, cacheWrite: 50)
}

/// A transcript root holding one assistant turn per id, `minutesAgo` old.
private func transcriptRoot(_ turns: [(id: String, minutesAgo: Double)]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("yousage-tests-\(UUID().uuidString)", isDirectory: true)
    let dir = root.appendingPathComponent("-Users-me-proj", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let lines = turns.map { turn in
        """
        {"type":"assistant","requestId":"\(turn.id)","timestamp":"\(iso(Date().addingTimeInterval(-turn.minutesAgo * 60)))","message":{"id":"m-\(turn.id)","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":3,"cache_read_input_tokens":4}}}
        """
    }
    try (lines.joined(separator: "\n") + "\n").write(to: dir.appendingPathComponent("a.jsonl"),
                                                     atomically: true, encoding: .utf8)
    return root
}

@Test func remoteEventsJoinTheWindowsAndSplitBySource() async throws {
    let root = try transcriptRoot([("local-1", 10)])
    defer { try? FileManager.default.removeItem(at: root) }
    let tracker = TokenTracker(root: root)

    let held = await tracker.mergeRemote(source: "tserver.example.ts.net", name: "TServer",
                                         events: [remoteEvent("r1", minutesAgo: 20),
                                                  remoteEvent("r2", minutesAgo: 3 * 24 * 60)],
                                         replace: true)
    #expect(held == 2)

    let report = try #require(await tracker.report(sessionResetsAt: Date().addingTimeInterval(3600),
                                                   weekResetsAt: nil))
    #expect(report.session.messages == 2)        // local-1 + r1
    #expect(report.week.messages == 3)           // + r2
    #expect(report.sources.map(\.name) == ["This Mac", "TServer"])
    #expect(report.sources[0].session.messages == 1)
    #expect(report.sources[1].session.messages == 1)
    #expect(report.sources[1].week.messages == 2)
    #expect(report.sources[1].week.output == 200)
    // Remote turns are priced and split by model through the same code.
    #expect(report.models.map(\.model).sorted() == ["claude-opus-4-8", "claude-sonnet-5"])
    #expect(report.sessionCost.isComplete)
}

@Test func remoteEventsReachTheBreakdownAndTheHistory() async throws {
    let root = try transcriptRoot([("local-1", 10)])
    defer { try? FileManager.default.removeItem(at: root) }
    let tracker = TokenTracker(root: root)

    // A lone Mac: no split in the details window either.
    #expect(try #require(await tracker.breakdown()).sources.isEmpty)

    await tracker.mergeRemote(source: "tserver.example.ts.net", name: "TServer",
                              events: [remoteEvent("r1", minutesAgo: 20),
                                       remoteEvent("r2", minutesAgo: 40 * 24 * 60)],
                              replace: true)

    // The activity grid spans 180 days, so it holds all three wherever the
    // calendar boundaries fall today.
    let history = try #require(await tracker.history())
    #expect(history.totals.messages == 3)

    // Whatever span the quarter covers today, the split adds up to it.
    let breakdown = try #require(await tracker.breakdown(range: .quarter))
    #expect(breakdown.sources.map(\.name) == ["This Mac", "TServer"])
    #expect(breakdown.sources.map(\.totals.messages).reduce(0, +) == breakdown.totals.messages)
}

@Test func aRemoteOnlyMacStillHasABreakdownAndAHistory() async throws {
    let tracker = TokenTracker(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(await tracker.breakdown() == nil)
    #expect(await tracker.history() == nil)
    await tracker.mergeRemote(source: "s", name: "S", events: [remoteEvent("a", minutesAgo: 5)], replace: true)
    #expect(try #require(await tracker.history()).totals.messages == 1)
    #expect(try #require(await tracker.breakdown()).sources.map(\.name) == ["This Mac", "S"])
}

@Test func anEventSeenLocallyIsNotCountedAgainFromARemote() async throws {
    let root = try transcriptRoot([("shared", 10)])
    defer { try? FileManager.default.removeItem(at: root) }
    let tracker = TokenTracker(root: root)
    _ = await tracker.report(sessionResetsAt: nil, weekResetsAt: nil)  // scan local first

    await tracker.mergeRemote(source: "a.ts.net", name: "A", events: [remoteEvent("shared", minutesAgo: 10)], replace: true)
    await tracker.mergeRemote(source: "b.ts.net", name: "B", events: [remoteEvent("x", minutesAgo: 5)], replace: true)
    await tracker.mergeRemote(source: "c.ts.net", name: "C", events: [remoteEvent("x", minutesAgo: 5)], replace: true)

    let report = try #require(await tracker.report(sessionResetsAt: nil, weekResetsAt: nil))
    #expect(report.week.messages == 2)
}

@Test func incrementalMergesUpsertAndFullMergesReplace() async throws {
    let tracker = TokenTracker(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    await tracker.mergeRemote(source: "s", name: "S", events: [remoteEvent("a", minutesAgo: 30)], replace: true)
    // Overlapping incremental fetch: "a" again plus a new "b".
    let held = await tracker.mergeRemote(source: "s", name: "S",
                                         events: [remoteEvent("a", minutesAgo: 30), remoteEvent("b", minutesAgo: 1)],
                                         replace: false)
    #expect(held == 2)
    #expect(await tracker.mergeRemote(source: "s", name: "S", events: [remoteEvent("c", minutesAgo: 1)], replace: true) == 1)
}

@Test func remoteOnlyStillReportsAndRemovalClearsIt() async throws {
    let tracker = TokenTracker(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    #expect(await tracker.report(sessionResetsAt: nil, weekResetsAt: nil) == nil)
    await tracker.mergeRemote(source: "s", name: "S", events: [remoteEvent("a", minutesAgo: 5)], replace: true)
    let report = try #require(await tracker.report(sessionResetsAt: nil, weekResetsAt: nil))
    #expect(report.week.messages == 1)
    await tracker.removeRemote(source: "s")
    #expect(await tracker.report(sessionResetsAt: nil, weekResetsAt: nil) == nil)
}

@Test func remoteEventsOutsideRetentionOrMalformedAreDropped() async throws {
    let tracker = TokenTracker(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    let held = await tracker.mergeRemote(source: "s", name: "S", events: [
        remoteEvent("old", minutesAgo: Double(UsageRange.historyDays + 2) * 24 * 60),
        RemoteUsageEvent(id: "bad-ts", ts: "yesterday", model: "m", input: 1, output: 1, cacheRead: 0, cacheWrite: 0),
        RemoteUsageEvent(id: "synthetic", ts: iso(Date()), model: "<synthetic>", input: 1, output: 1, cacheRead: 0, cacheWrite: 0),
        RemoteUsageEvent(id: "zero", ts: iso(Date()), model: "m", input: 0, output: 0, cacheRead: 0, cacheWrite: 0),
        remoteEvent("ok", minutesAgo: 1),
    ], replace: true)
    #expect(held == 1)
}

@Test func theServerPayloadDecodes() throws {
    let json = """
    {"version":1,"host":"TServer","account":{"accountUuid":"a","organizationUuid":"o"},
     "generatedAt":"2026-10-06T12:00:00.000Z",
     "events":[{"id":"r","ts":"2026-10-06T11:00:00.123Z","model":"claude-opus-5-5",
                "input":1,"output":2,"cacheRead":3,"cacheWrite":4}]}
    """
    let payload = try JSONDecoder().decode(RemoteUsagePayload.self, from: Data(json.utf8))
    #expect(payload.host == "TServer")
    #expect(payload.account.organizationUuid == "o")
    #expect(payload.events.first?.cacheWrite == 4)
}

@Test func onlyPeersTaggedServerAreCandidates() throws {
    let json = """
    {"BackendState":"Running",
     "Self":{"DNSName":"mac.tail1.ts.net.","Online":true,"Tags":["tag:server"]},
     "Peer":{
       "k1":{"DNSName":"tserver.tail1.ts.net.","Online":true,"Tags":["tag:server"]},
       "k2":{"DNSName":"phone.tail1.ts.net.","Online":true},
       "k3":{"DNSName":"Other.tail1.ts.net.","Online":false,"Tags":["tag:ci","tag:server"]},
       "k4":{"DNSName":"ci.tail1.ts.net.","Online":true,"Tags":["tag:ci"]}
     }}
    """
    let peers = try #require(RemoteSources.taggedPeers(statusJSON: Data(json.utf8)))
    #expect(peers == [
        RemoteSources.TaggedPeer(host: "other.tail1.ts.net", online: false),
        RemoteSources.TaggedPeer(host: "tserver.tail1.ts.net", online: true),
    ])
}

@Test func aStoppedTailscaleYieldsNothing() {
    #expect(RemoteSources.taggedPeers(statusJSON: Data(#"{"BackendState":"Stopped","Peer":{}}"#.utf8)) == nil)
    #expect(RemoteSources.taggedPeers(statusJSON: Data("not json".utf8)) == nil)
    #expect(RemoteSources.taggedPeers(statusJSON: Data(#"{"BackendState":"Running"}"#.utf8)) == [])
}

@Test func theServerStampIsReadExactlyAsTheFormatterReadsIt() {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let stamps = ["1970-01-01T00:00:00.000Z", "2000-02-29T23:59:59.999Z", "2026-03-08T07:30:00.125Z",
                  "2026-12-31T12:00:00.500Z", "2100-03-01T00:00:00.001Z"]
        + (0..<200).map { i in f.string(from: Date(timeIntervalSince1970: 1.7e9 + Double(i) * 97_531.237)) }
    for stamp in stamps {
        let fast = TokenTracker.parseServerStamp(stamp)
        let slow = f.date(from: stamp)
        #expect(fast != nil && slow != nil, "\(stamp)")
        if let fast, let slow {
            #expect(abs(fast.timeIntervalSince(slow)) < 0.000_5, "\(stamp)")
        }
    }
    // Anything but the server's exact shape is left to the formatter.
    for other in ["2026-07-14T09:30:05Z", "2026-07-14T09:30:05.123+02:00", "2026-13-01T00:00:00.000Z",
                  "yesterday", "2026-07-14 09:30:05.123Z"] {
        #expect(TokenTracker.parseServerStamp(other) == nil, "\(other)")
    }
}

@Test func aPollThatReSendsHeldEventsIsNotAChange() async throws {
    let tracker = TokenTracker(root: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
    let a = remoteEvent("a", minutesAgo: 30)
    await tracker.mergeRemote(source: "s", name: "S", events: [a], replace: true)
    let version = await tracker.dataVersion
    // The `since` overlap: the same event again, incrementally and in full.
    await tracker.mergeRemote(source: "s", name: "S", events: [a], replace: false)
    await tracker.mergeRemote(source: "s", name: "S", events: [a], replace: true)
    #expect(await tracker.dataVersion == version)
    await tracker.mergeRemote(source: "s", name: "S", events: [a, remoteEvent("b", minutesAgo: 1)], replace: false)
    #expect(await tracker.dataVersion != version)
}
