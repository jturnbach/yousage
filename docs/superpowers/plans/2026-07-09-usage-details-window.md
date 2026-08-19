# Usage Details Window Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A native macOS window, opened from the menu bar popover, charting seven calendar days of Claude Code token usage by model, by cost, and by token kind.

**Architecture:** `TokenTracker` (an actor) emits flat `UsageEvent` values; a pure `UsageBreakdown.make(from:now:calendar:dayCount:)` buckets them into calendar days, model-family segments, per-model costs, and token-kind totals. `AppState` publishes the result. A `Window` scene renders it with Swift Charts, using a colour map keyed on model family so a series never changes hue when its neighbours come and go.

**Tech Stack:** Swift 6 toolchain (language mode v5), SwiftPM, SwiftUI, **Swift Charts** (system framework, macOS 13+, no package dependency), swift-testing.

## Global Constraints

- **Every `swift test` invocation must be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** `xcode-select` points at the Command Line Tools, which ship no test frameworks. Without the prefix you get `error: no such module 'Testing'`, which looks like a broken package but is not. `swift build` and `./build.sh` do **not** need it.
- **Use swift-testing (`import Testing`, `@Test`, `#expect`), not XCTest.**
- **Do not add anything to `Package.swift`.** `import Charts` resolves against the macOS SDK. This was verified: it typechecks at `-target arm64-apple-macosx14.0`.
- **Do not modify `Sources/YouSage/MenuBarLabel.swift`.** The menu bar gauge is out of scope.
- **Do not change `Sources/YouSage/Pricing.swift`'s rate table, `normalize`, or `cost`.** Task 1 changes exactly one thing there: the access level of `isFamily`.
- Palette hex values, verbatim. Opus `#D97757` light / `#D3714E` dark. Sonnet `#2a78d6` / `#3987e5`. Haiku `#008300` / `#3aa63a`. Fable `#4a3aa7` / `#9085e9`. Other: the system `secondaryLabelColor`, no hex.
- **No chart may have two y-scales.** Tokens and dollars never share a plot.
- **Gridlines are solid hairlines.** Never dashed.
- `claude-mythos-5` resolves to `.other`, never `.fable`. `claude-3-opus` resolves to `.other`, never `.opus`.
- The window shows **seven local calendar days**. Its headline total is the sum of its own bars and is labelled `last 7 calendar days`. It must never be presented as equal to the popover's rolling-window total.
- The repo is clean on `main` at commit `38926f7`, with **16 passing tests**. Each task states how many tests it adds. A task must never make a previously passing test fail.
- Stage only the files each task names. Never `git add -A` or `git commit -a`.

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `Sources/YouSage/Models.swift` | Modify | Extract `modelDisplayName(_:)` as a free function; `ModelTokens.displayName` delegates to it. |
| `Sources/YouSage/Pricing.swift` | Modify | One word: `isFamily` loses `private` so family colouring resolves identically to family pricing. |
| `Sources/YouSage/UsageBreakdown.swift` | Create | `UsageEvent`, `ModelFamily`, `TokenKind`, `FamilyTokens`, `DayUsage`, `ModelCost`, `KindTotal`, `UsageBreakdown`, and the pure `make`. No I/O, no SwiftUI. |
| `Sources/YouSage/TokenTracker.swift` | Modify | `+ breakdown(now:calendar:)`. |
| `Sources/YouSage/AppState.swift` | Modify | `+ @Published usageBreakdown`, refreshed beside `tokenReport`. |
| `Sources/YouSage/ChartPalette.swift` | Create | `ModelFamily` → hex → `Color`, per colour scheme. |
| `Sources/YouSage/UsageCharts.swift` | Create | The three chart views and the trend tooltip. Marks only. |
| `Sources/YouSage/UsageWindow.swift` | Create | Window root: KPI row, empty states, chart/table toggle, table view. |
| `Sources/YouSage/App.swift` | Modify | `+ Window("Usage Details", id: "usage")`. |
| `Sources/YouSage/PopoverView.swift` | Modify | `+ "Usage Details…"` menu item. |
| `Tests/YouSageTests/ModelFamilyTests.swift` | Create | Naming + family resolution + token-kind counters. |
| `Tests/YouSageTests/UsageBreakdownTests.swift` | Create | Bucketing, DST, zero-fill, folding, cost, sorting. |
| `Tests/YouSageTests/ChartPaletteTests.swift` | Create | Hex values and colour stability. |

`UsageWindow` and `UsageCharts` are separate because one owns state and layout and the other owns marks; they change for different reasons.

Tasks run in order. Task 5 depends on 4; Task 6 depends on 3 and 5.

---

### Task 1: Model naming and family resolution

**Files:**
- Modify: `Sources/YouSage/Models.swift`
- Modify: `Sources/YouSage/Pricing.swift`
- Create: `Sources/YouSage/UsageBreakdown.swift` (types only; `make` arrives in Task 2)
- Test: `Tests/YouSageTests/ModelFamilyTests.swift`

**Interfaces:**
- Consumes: `Pricing.normalize(_ model: String) -> String` and `Pricing.isFamily(_ family: String, of id: String) -> Bool` (the latter is made non-private in this task). `TokenTotals`, a struct with `Int` fields `input`, `output`, `cacheCreation`, `cacheRead`, `messages`, all defaulting to `0`.
- Produces: free function `modelDisplayName(_ id: String) -> String`; `enum ModelFamily: String, Sendable, Equatable, CaseIterable { case opus, sonnet, haiku, fable, other }` with `var displayName: String` and `init(modelID: String)`; `enum TokenKind: String, Sendable, CaseIterable { case cacheRead, cacheWrite, output, input }` with `var displayName: String` and `func count(in: TokenTotals) -> Int`; `struct UsageEvent: Sendable, Equatable { let date: Date; let model: String; let totals: TokenTotals }`.

**Why `modelDisplayName` is extracted rather than copied:** `ModelTokens.displayName` currently strips `claude-` **or** `anthropic.`, never both, so `anthropic.claude-opus-4-8` renders as `Claude opus.4.8`. Routing it through `Pricing.normalize` fixes that bug at the root and gives the new window and the existing popover one definition of a model's name.

- [ ] **Step 1: Write the failing tests**

Create `Tests/YouSageTests/ModelFamilyTests.swift`:

```swift
import Testing
@testable import YouSage

@Test func modelDisplayNameStripsEveryPrefixAndSuffix() {
    #expect(modelDisplayName("claude-opus-4-8") == "Opus 4.8")
    #expect(modelDisplayName("claude-haiku-4-5-20251001") == "Haiku 4.5")
    #expect(modelDisplayName("claude-opus-4-8[1m]") == "Opus 4.8")
    // Previously rendered "Claude opus.4.8": the old loop stripped one prefix, not both.
    #expect(modelDisplayName("anthropic.claude-opus-4-8") == "Opus 4.8")
}

@Test func modelDisplayNamePassesUnknownIDsThroughLightlyCleaned() {
    #expect(modelDisplayName("gpt-5") == "Gpt 5")
    #expect(modelDisplayName("claude-sonnet-5") == "Sonnet 5")
}

@Test func modelTokensDisplayNameDelegatesToTheFreeFunction() {
    let t = ModelTokens(model: "anthropic.claude-opus-4-8", totals: TokenTotals())
    #expect(t.displayName == "Opus 4.8")
}

@Test func familyResolvesCurrentGenerations() {
    #expect(ModelFamily(modelID: "claude-opus-4-8") == .opus)
    #expect(ModelFamily(modelID: "anthropic.claude-opus-4-8") == .opus)
    #expect(ModelFamily(modelID: "claude-sonnet-5") == .sonnet)
    #expect(ModelFamily(modelID: "claude-haiku-4-5-20251001") == .haiku)
    #expect(ModelFamily(modelID: "claude-fable-5") == .fable)
    #expect(ModelFamily(modelID: "claude-opus-9-0") == .opus)   // future release
}

@Test func familyRejectsLegacyGenerationsAndNonModels() {
    // Same refusal pricing makes: a past generation is not the current family.
    #expect(ModelFamily(modelID: "claude-3-opus-20240229") == .other)
    #expect(ModelFamily(modelID: "claude-opusglobular") == .other)
    #expect(ModelFamily(modelID: "gpt-5") == .other)
    #expect(ModelFamily(modelID: "") == .other)
}

@Test func mythosIsOtherNotFable() {
    // Mythos prices like Fable but is a different model. Labelling it "Fable"
    // on screen would be a lie.
    #expect(ModelFamily(modelID: "claude-mythos-5") == .other)
}

@Test func tokenKindReadsTheCounterItNames() {
    let t = TokenTotals(input: 1, output: 2, cacheCreation: 3, cacheRead: 4, messages: 1)
    #expect(TokenKind.input.count(in: t) == 1)
    #expect(TokenKind.output.count(in: t) == 2)
    #expect(TokenKind.cacheWrite.count(in: t) == 3)   // cacheCreation
    #expect(TokenKind.cacheRead.count(in: t) == 4)
    #expect(TokenKind.allCases == [.cacheRead, .cacheWrite, .output, .input])
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: compile failure, `cannot find 'modelDisplayName' in scope`.

- [ ] **Step 3: Make `Pricing.isFamily` visible**

In `Sources/YouSage/Pricing.swift`, change the declaration line:

```swift
    private static func isFamily(_ family: String, of id: String) -> Bool {
```

to:

```swift
    /// Also used by `ModelFamily` so a model is coloured the same way it is priced.
    static func isFamily(_ family: String, of id: String) -> Bool {
```

Change nothing else in this file.

- [ ] **Step 4: Extract `modelDisplayName` in Models.swift**

In `Sources/YouSage/Models.swift`, replace the whole of `struct ModelTokens` with:

```swift
/// `claude-opus-4-8` → `Opus 4.8`. Normalizes first, so provider prefixes,
/// bracketed variants, and date stamps all fall away before formatting.
func modelDisplayName(_ id: String) -> String {
    var s = Pricing.normalize(id)
    if s.hasPrefix("claude-") { s = String(s.dropFirst("claude-".count)) }
    let parts = s.split(separator: "-").map(String.init)
    guard let family = parts.first, !family.isEmpty else { return id }
    let version = parts.dropFirst().joined(separator: ".")
    let name = family.prefix(1).uppercased() + family.dropFirst()
    return version.isEmpty ? name : "\(name) \(version)"
}

struct ModelTokens: Sendable, Equatable, Identifiable {
    let model: String
    let totals: TokenTotals
    var id: String { model }

    var displayName: String { modelDisplayName(model) }
}
```

- [ ] **Step 5: Create the type file**

Create `Sources/YouSage/UsageBreakdown.swift`:

```swift
import Foundation

/// One assistant turn, as `TokenTracker` saw it. Flat and Sendable so the
/// bucketing below can be a pure function tested without an actor or a disk.
struct UsageEvent: Sendable, Equatable {
    let date: Date
    let model: String
    let totals: TokenTotals
}

/// The colour-bearing identity of a model. Versions fold together: Opus 4.7 and
/// Opus 4.8 are one segment in the trend chart, because two segments of identical
/// terracotta would be a stripe you cannot read. They price identically, and the
/// cost list keeps both versions as separate rows.
enum ModelFamily: String, Sendable, Equatable, CaseIterable {
    case opus, sonnet, haiku, fable, other

    var displayName: String {
        switch self {
        case .opus:   return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku:  return "Haiku"
        case .fable:  return "Fable"
        case .other:  return "Other"
        }
    }

    /// Resolved through the same normalization and anchored family match that
    /// pricing uses, so a model is coloured exactly as it is priced.
    /// `claude-3-opus` is a past generation that priced differently — it is
    /// `.other`, not `.opus`. `claude-mythos-5` prices like Fable but is not
    /// Fable, so it is `.other` too.
    init(modelID: String) {
        let id = Pricing.normalize(modelID)
        if Pricing.isFamily("opus", of: id)        { self = .opus }
        else if Pricing.isFamily("sonnet", of: id) { self = .sonnet }
        else if Pricing.isFamily("haiku", of: id)  { self = .haiku }
        else if Pricing.isFamily("fable", of: id)  { self = .fable }
        else                                       { self = .other }
    }
}

/// Declaration order is display order: largest bucket first, as Claude Code's
/// token mix actually falls.
enum TokenKind: String, Sendable, CaseIterable {
    case cacheRead, cacheWrite, output, input

    var displayName: String {
        switch self {
        case .cacheRead:  return "cache read"
        case .cacheWrite: return "cache write"
        case .output:     return "output"
        case .input:      return "input"
        }
    }

    func count(in totals: TokenTotals) -> Int {
        switch self {
        case .cacheRead:  return totals.cacheRead
        case .cacheWrite: return totals.cacheCreation
        case .output:     return totals.output
        case .input:      return totals.input
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -6`

Expected: `✔ Test run with 23 tests in 0 suites passed` (16 before, 7 added).

- [ ] **Step 7: Commit**

```bash
git add Sources/YouSage/Models.swift Sources/YouSage/Pricing.swift Sources/YouSage/UsageBreakdown.swift Tests/YouSageTests/ModelFamilyTests.swift
git commit -m "Add model family resolution and fix provider-prefixed display names"
```

---

### Task 2: The pure breakdown

**Files:**
- Modify: `Sources/YouSage/UsageBreakdown.swift`
- Test: `Tests/YouSageTests/UsageBreakdownTests.swift`

**Interfaces:**
- Consumes: `UsageEvent`, `ModelFamily`, `TokenKind`, `modelDisplayName(_:)` from Task 1. `TokenTotals` with its `+` operator, `total`, `isEmpty`. `CostEstimate` with `var amount: Double = 0`, `var unpricedModels: [String] = []`, `var isComplete: Bool`, `var display: String`. `Pricing.cost(_ totals: TokenTotals, model: String) -> Double?`, returning nil for a model it cannot price.
- Produces: `FamilyTokens`, `DayUsage`, `ModelCost`, `KindTotal`, `UsageBreakdown`, and `static func UsageBreakdown.make(from:now:calendar:dayCount:) -> UsageBreakdown`. Tasks 3, 5, 6 read these.

**Note on `DayUsage.cost`:** the spec's tooltip shows "the day's cost", so `DayUsage` carries a `CostEstimate`. The spec's type sketch omitted the field; the requirement implies it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/YouSageTests/UsageBreakdownTests.swift`:

```swift
import Foundation
import Testing
@testable import YouSage

/// Fixed zone so bucketing tests do not depend on the machine's locale.
private let newYork = TimeZone(identifier: "America/New_York")!

private var cal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = newYork
    return c
}()

private func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12, _ mi: Int = 0) -> Date {
    cal.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

private func event(_ date: Date, _ model: String, input: Int = 1_000) -> UsageEvent {
    UsageEvent(date: date, model: model, totals: TokenTotals(input: input, messages: 1))
}

@Test func sevenDaysAreAlwaysReturnedEvenFromNoEvents() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.count == 7)
    #expect(b.totals.total == 0)
    #expect(b.cost.amount == 0)
    #expect(b.cost.isComplete)
}

@Test func daysAreOldestFirstAndOnlyTheLastIsToday() {
    let b = UsageBreakdown.make(from: [], now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.first!.day == cal.startOfDay(for: at(2026, 7, 3)))
    #expect(b.days.last!.day == cal.startOfDay(for: at(2026, 7, 9)))
    #expect(b.days.filter(\.isToday).count == 1)
    #expect(b.days.last!.isToday)
}

@Test func aDayWithNoActivityIsPresentAndEmptyRatherThanAbsent() {
    let events = [event(at(2026, 7, 9), "claude-opus-4-8")]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.count == 7)
    #expect(b.days[0].totals.total == 0)
    #expect(b.days[0].byFamily.isEmpty)
    #expect(b.days[6].totals.total == 1_000)
}

@Test func eventsOutsideTheSpanAreExcluded() {
    let events = [
        event(at(2026, 7, 1), "claude-opus-4-8"),   // 8 days ago — out
        event(at(2026, 7, 3), "claude-opus-4-8"),   // oldest day in span
        event(at(2026, 7, 9), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.totals.total == 2_000)
    #expect(b.totals.messages == 2)
}

@Test func bucketingSurvivesSpringForward() {
    // 2026-03-08 is 23 hours long in America/New_York.
    let events = [
        event(at(2026, 3, 8, 1, 30), "claude-opus-4-8"),   // before the jump
        event(at(2026, 3, 8, 3, 30), "claude-opus-4-8"),   // after the jump
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 3, 10), calendar: cal)
    let march8 = b.days.first { $0.day == cal.startOfDay(for: at(2026, 3, 8)) }
    #expect(march8?.totals.total == 2_000)
}

@Test func bucketingSurvivesFallBack() {
    // 2026-11-01 is 25 hours long; 01:30 occurs twice.
    let events = [
        event(at(2026, 11, 1, 1, 30), "claude-opus-4-8"),
        event(at(2026, 11, 1, 23, 0), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 11, 3), calendar: cal)
    let nov1 = b.days.first { $0.day == cal.startOfDay(for: at(2026, 11, 1)) }
    #expect(nov1?.totals.total == 2_000)
}

@Test func opusVersionsFoldToOneFamilySegmentButStayTwoCostRows() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8"),
        event(at(2026, 7, 9), "claude-opus-4-7"),
        event(at(2026, 7, 9), "claude-haiku-4-5"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let today = b.days.last!
    #expect(today.byFamily.map(\.family) == [.opus, .haiku])
    #expect(today.byFamily.first!.totals.total == 2_000)   // both Opus versions
    #expect(b.models.map(\.displayName).sorted() == ["Haiku 4.5", "Opus 4.7", "Opus 4.8"])
}

@Test func familySegmentsFollowDeclarationOrderNotInsertionOrder() {
    let events = [
        event(at(2026, 7, 9), "claude-haiku-4-5"),
        event(at(2026, 7, 9), "claude-opus-4-8"),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.days.last!.byFamily.map(\.family) == [.opus, .haiku])
}

@Test func modelsSortByCostNotByTokens() {
    // Haiku has more tokens; Opus costs more. Cost wins.
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 2_000_000),   // $10.00
        event(at(2026, 7, 9), "claude-haiku-4-5", input: 3_000_000),  // $3.00
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.models.map(\.displayName) == ["Opus 4.8", "Haiku 4.5"])
    #expect(b.models[0].cost.amount == 10.0)
    #expect(b.models[1].cost.amount == 3.0)
    #expect(b.totals.total == 5_000_000)
}

@Test func anUnpriceableModelIsOtherAndForcesALowerBound() {
    let events = [
        event(at(2026, 7, 9), "claude-opus-4-8", input: 1_000_000),   // $5.00
        event(at(2026, 7, 9), "gpt-5", input: 1_000_000),             // unpriceable
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.cost.amount == 5.0)
    #expect(b.cost.unpricedModels == ["gpt-5"])
    #expect(b.cost.isComplete == false)
    #expect(b.cost.display.hasPrefix("≥"))
    #expect(b.models.first(where: { $0.model == "gpt-5" })?.family == .other)
}

@Test func kindsAlwaysAppearInDeclarationOrderEvenWhenZero() {
    let events = [UsageEvent(date: at(2026, 7, 9), model: "claude-opus-4-8",
                             totals: TokenTotals(input: 5, output: 0, cacheCreation: 0,
                                                 cacheRead: 70, messages: 1))]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    #expect(b.kinds.map(\.kind) == [.cacheRead, .cacheWrite, .output, .input])
    #expect(b.kinds.map(\.count) == [70, 0, 0, 5])
}

@Test func perDayCostsSumToTheTotalCost() {
    let events = [
        event(at(2026, 7, 7), "claude-opus-4-8", input: 1_000_000),
        event(at(2026, 7, 9), "claude-haiku-4-5", input: 2_000_000),
    ]
    let b = UsageBreakdown.make(from: events, now: at(2026, 7, 9), calendar: cal)
    let summed = b.days.reduce(0.0) { $0 + $1.cost.amount }
    #expect(abs(summed - b.cost.amount) < 1e-9)
    #expect(abs(b.cost.amount - 7.0) < 1e-9)   // $5.00 + $2.00
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: compile failure, `type 'UsageBreakdown' has no member 'make'`.

- [ ] **Step 3: Append the aggregate types and `make` to UsageBreakdown.swift**

Append to `Sources/YouSage/UsageBreakdown.swift` (below `TokenKind`, leaving everything from Task 1 in place):

```swift
struct FamilyTokens: Sendable, Equatable, Identifiable {
    let family: ModelFamily
    let totals: TokenTotals
    var id: ModelFamily { family }
}

struct DayUsage: Sendable, Equatable, Identifiable {
    /// Local start of day.
    let day: Date
    /// Still accruing; the chart draws it at reduced opacity.
    let isToday: Bool
    /// Only families active that day, in `ModelFamily.allCases` order.
    let byFamily: [FamilyTokens]
    let totals: TokenTotals
    let cost: CostEstimate
    var id: Date { day }
}

struct ModelCost: Sendable, Equatable, Identifiable {
    /// Raw id, e.g. `claude-opus-4-8`.
    let model: String
    /// `Opus 4.8` — versions stay distinct here even though the chart folds them.
    let displayName: String
    let family: ModelFamily
    let totals: TokenTotals
    let cost: CostEstimate
    var id: String { model }
}

struct KindTotal: Sendable, Equatable, Identifiable {
    let kind: TokenKind
    let count: Int
    var id: TokenKind { kind }
}

/// Seven calendar days of usage, sliced three ways. A tuple would be lighter than
/// `KindTotal`, but tuples do not synthesize `Equatable` and SwiftUI needs that.
struct UsageBreakdown: Sendable, Equatable {
    /// Exactly `dayCount` entries, oldest first, zero-filled.
    let days: [DayUsage]
    /// Cost descending, then tokens descending, then name — so the order is total.
    let models: [ModelCost]
    /// Always four, in declaration order.
    let kinds: [KindTotal]
    let totals: TokenTotals
    let cost: CostEstimate
    let generatedAt: Date
}

extension UsageBreakdown {
    /// The last `dayCount` local calendar days ending on `now`'s day.
    ///
    /// Pure: everything the window draws is decided here, so it can be tested with
    /// synthetic events instead of transcript fixtures. Bucketing goes through
    /// `Calendar.startOfDay`, so a 23-hour spring-forward day and a 25-hour
    /// fall-back day both land where a human would put them.
    static func make(from events: [UsageEvent],
                     now: Date,
                     calendar: Calendar,
                     dayCount: Int = 7) -> UsageBreakdown {
        let emptyKinds = TokenKind.allCases.map { KindTotal(kind: $0, count: 0) }
        guard dayCount > 0 else {
            return UsageBreakdown(days: [], models: [], kinds: emptyKinds,
                                  totals: TokenTotals(), cost: CostEstimate(),
                                  generatedAt: now)
        }

        let today = calendar.startOfDay(for: now)
        let dayStarts: [Date] = (0..<dayCount).reversed().compactMap {
            calendar.date(byAdding: .day, value: -$0, to: today)
        }
        let spanStart = dayStarts[0]
        let spanEnd = calendar.date(byAdding: .day, value: 1, to: today) ?? now

        // Bucket once; every slice below reads from these two maps.
        var perDayModel: [Date: [String: TokenTotals]] = [:]
        var perModel: [String: TokenTotals] = [:]
        for e in events where e.date >= spanStart && e.date < spanEnd {
            let day = calendar.startOfDay(for: e.date)
            var models = perDayModel[day] ?? [:]
            models[e.model] = (models[e.model] ?? TokenTotals()) + e.totals
            perDayModel[day] = models
            perModel[e.model] = (perModel[e.model] ?? TokenTotals()) + e.totals
        }

        let days: [DayUsage] = dayStarts.map { day in
            let models = perDayModel[day] ?? [:]

            var byFamilyMap: [ModelFamily: TokenTotals] = [:]
            for (id, totals) in models {
                let family = ModelFamily(modelID: id)
                byFamilyMap[family] = (byFamilyMap[family] ?? TokenTotals()) + totals
            }
            let byFamily = ModelFamily.allCases.compactMap { family -> FamilyTokens? in
                guard let totals = byFamilyMap[family], !totals.isEmpty else { return nil }
                return FamilyTokens(family: family, totals: totals)
            }

            return DayUsage(day: day,
                            isToday: day == today,
                            byFamily: byFamily,
                            totals: byFamily.reduce(TokenTotals()) { $0 + $1.totals },
                            cost: estimate(over: models))
        }

        let models: [ModelCost] = perModel.map { id, totals in
            ModelCost(model: id,
                      displayName: modelDisplayName(id),
                      family: ModelFamily(modelID: id),
                      totals: totals,
                      cost: estimate(over: [id: totals]))
        }
        .sorted {
            if $0.cost.amount != $1.cost.amount { return $0.cost.amount > $1.cost.amount }
            if $0.totals.total != $1.totals.total { return $0.totals.total > $1.totals.total }
            return $0.displayName < $1.displayName
        }

        let totals = models.reduce(TokenTotals()) { $0 + $1.totals }
        let kinds = TokenKind.allCases.map { KindTotal(kind: $0, count: $0.count(in: totals)) }

        return UsageBreakdown(days: days,
                              models: models,
                              kinds: kinds,
                              totals: totals,
                              cost: estimate(over: perModel),
                              generatedAt: now)
    }

    /// Prices a model→totals map. A model the rate table cannot price contributes
    /// zero dollars and its id, so the figure renders as a lower bound rather than
    /// a confidently low number.
    private static func estimate(over models: [String: TokenTotals]) -> CostEstimate {
        var result = CostEstimate()
        var unpriced: Set<String> = []
        for (id, totals) in models {
            if let dollars = Pricing.cost(totals, model: id) {
                result.amount += dollars
            } else {
                unpriced.insert(id)
            }
        }
        result.unpricedModels = unpriced.sorted()
        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -6`

Expected: `✔ Test run with 35 tests in 0 suites passed` (23 before, 12 added).

- [ ] **Step 5: Commit**

```bash
git add Sources/YouSage/UsageBreakdown.swift Tests/YouSageTests/UsageBreakdownTests.swift
git commit -m "Bucket usage events into calendar days, families, and costs"
```

---

### Task 3: Publish the breakdown

**Files:**
- Modify: `Sources/YouSage/TokenTracker.swift`
- Modify: `Sources/YouSage/AppState.swift`

**Interfaces:**
- Consumes: `UsageBreakdown.make(from:now:calendar:dayCount:)` and `UsageEvent` from Task 2.
- Produces: `TokenTracker.breakdown(now:calendar:) async -> UsageBreakdown?` and `AppState.usageBreakdown: UsageBreakdown?` (`@Published private(set)`). Task 6 reads `AppState.shared.usageBreakdown`.

This task adds no tests. `TokenTracker` is an actor whose `events` are private, and driving it needs transcript fixtures; the logic it delegates to is already covered by Task 2's twelve tests. It is verified by `swift build` plus the manual check in Task 6.

- [ ] **Step 1: Add `breakdown` to TokenTracker**

In `Sources/YouSage/TokenTracker.swift`, immediately after the closing brace of `report(sessionResetsAt:weekResetsAt:)` and before `private func modelSplit(_:)`, insert:

```swift
    /// Seven calendar days of usage for the details window. Deliberately a
    /// different window from `report`'s rolling week: a bar labelled "Fri" must
    /// be Friday, so the two totals will not agree, and each is labelled with
    /// the window it describes.
    func breakdown(now: Date = Date(), calendar: Calendar = .current) -> UsageBreakdown? {
        guard isAvailable else { return nil }
        scan()
        let usage = events.map { UsageEvent(date: $0.date, model: $0.model, totals: $0.totals) }
        return UsageBreakdown.make(from: usage, now: now, calendar: calendar)
    }
```

- [ ] **Step 2: Publish it from AppState**

In `Sources/YouSage/AppState.swift`, directly below the line `@Published private(set) var tokenReport: TokenReport?`, add:

```swift
    @Published private(set) var usageBreakdown: UsageBreakdown?
```

- [ ] **Step 3: Refresh it beside the report**

Still in `Sources/YouSage/AppState.swift`, replace the body of the `tokenScan = Task { ... }` closure inside `refreshTokens(force:)` so it reads:

```swift
        tokenScan = Task { [weak self] in
            let report = await TokenTracker.shared.report(sessionResetsAt: session, weekResetsAt: week)
            // Same in-memory events, a different window. The second call re-enters
            // `scan()`, which is incremental and finds nothing new to read.
            let breakdown = await TokenTracker.shared.breakdown()
            await MainActor.run {
                guard let self else { return }
                self.tokenReport = report
                self.usageBreakdown = breakdown
                self.lastTokenScan = Date()
                self.tokenScan = nil
            }
        }
```

- [ ] **Step 4: Verify it builds and nothing regressed**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -3`
Expected: `✔ Test run with 35 tests in 0 suites passed` — unchanged from Task 2.

- [ ] **Step 5: Commit**

```bash
git add Sources/YouSage/TokenTracker.swift Sources/YouSage/AppState.swift
git commit -m "Publish a seven-day usage breakdown from AppState"
```

---

### Task 4: Chart palette

**Files:**
- Create: `Sources/YouSage/ChartPalette.swift`
- Test: `Tests/YouSageTests/ChartPaletteTests.swift`

**Interfaces:**
- Consumes: `ModelFamily` from Task 1.
- Produces: `ChartPalette.hex(for: ModelFamily, scheme: ColorScheme) -> UInt32?` (nil means "use the system secondary label colour"), `ChartPalette.color(for: ModelFamily, scheme: ColorScheme) -> Color`, and `ChartPalette.sequential(_ scheme: ColorScheme) -> Color`. Task 5 uses `color` and `sequential`.

The tests assert on `hex`, not on `Color`. SwiftUI's `Color` has no reliable component-wise equality across colour spaces, so the hex table is the testable surface and `color` is a thin wrapper over it.

- [ ] **Step 1: Write the failing tests**

Create `Tests/YouSageTests/ChartPaletteTests.swift`:

```swift
import SwiftUI
import Testing
@testable import YouSage

@Test func hexesMatchTheValidatedPalette() {
    // Validated for lightness band, chroma floor, 3:1 contrast, and CVD
    // separation (worst adjacent ΔE 19.6, target ≥ 12) in both modes.
    #expect(ChartPalette.hex(for: .opus, scheme: .light) == 0xD97757)
    #expect(ChartPalette.hex(for: .opus, scheme: .dark) == 0xD3714E)
    #expect(ChartPalette.hex(for: .sonnet, scheme: .light) == 0x2A78D6)
    #expect(ChartPalette.hex(for: .sonnet, scheme: .dark) == 0x3987E5)
    #expect(ChartPalette.hex(for: .haiku, scheme: .light) == 0x008300)
    #expect(ChartPalette.hex(for: .haiku, scheme: .dark) == 0x3AA63A)
    #expect(ChartPalette.hex(for: .fable, scheme: .light) == 0x4A3AA7)
    #expect(ChartPalette.hex(for: .fable, scheme: .dark) == 0x9085E9)
}

@Test func otherHasNoHexAndDefersToTheSystemColour() {
    #expect(ChartPalette.hex(for: .other, scheme: .light) == nil)
    #expect(ChartPalette.hex(for: .other, scheme: .dark) == nil)
}

@Test func everyColouredFamilyIsDistinctWithinAScheme() {
    for scheme in [ColorScheme.light, .dark] {
        let hexes = ModelFamily.allCases.compactMap { ChartPalette.hex(for: $0, scheme: scheme) }
        #expect(hexes.count == 4)
        #expect(Set(hexes).count == 4)
    }
}

@Test func aFamilysColourDependsOnNothingButItself() {
    // Colour follows the entity, never its rank: dropping Sonnet from a week
    // must not repaint Haiku. `hex` takes no context, so this holds by
    // construction — the test pins the property against a future refactor.
    let before = ChartPalette.hex(for: .haiku, scheme: .light)
    let subset: [ModelFamily] = [.opus, .haiku]
    let after = subset.compactMap { $0 == .haiku ? ChartPalette.hex(for: $0, scheme: .light) : nil }.first
    #expect(before == after)
}

@Test func theSequentialHueIsTheBrandTerracotta() {
    // The token-kind chart is one series, so it takes one colour.
    #expect(ChartPalette.sequentialHex(.light) == 0xD97757)
    #expect(ChartPalette.sequentialHex(.dark) == 0xD3714E)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: compile failure, `cannot find 'ChartPalette' in scope`.

- [ ] **Step 3: Write the implementation**

Create `Sources/YouSage/ChartPalette.swift`:

```swift
import SwiftUI

/// Chart colours, keyed on model family.
///
/// The assignment is fixed and takes no context: colour follows the entity, never
/// its rank. If it depended on which families were present in the current week,
/// dropping Sonnet would repaint Haiku, and a reader who learned "Haiku is green"
/// would be misled.
///
/// Every value below was checked with a palette validator in both modes: all four
/// sit inside the lightness band, clear the chroma floor, hold ≥ 3:1 against their
/// surface, and keep a worst adjacent colour-vision-deficiency separation of
/// ΔE 19.6 against a ≥ 12 target. The terracotta is stepped darker on the dark
/// surface because `#D97757` sits at OKLCH L 0.672, just over the dark band's
/// 0.67 ceiling.
enum ChartPalette {
    /// nil means the family has no brand hue — draw it in the system's secondary
    /// label colour and call it "Other".
    static func hex(for family: ModelFamily, scheme: ColorScheme) -> UInt32? {
        let dark = scheme == .dark
        switch family {
        case .opus:   return dark ? 0xD3714E : 0xD97757
        case .sonnet: return dark ? 0x3987E5 : 0x2A78D6
        case .haiku:  return dark ? 0x3AA63A : 0x008300
        case .fable:  return dark ? 0x9085E9 : 0x4A3AA7
        case .other:  return nil
        }
    }

    static func color(for family: ModelFamily, scheme: ColorScheme) -> Color {
        guard let hex = hex(for: family, scheme: scheme) else {
            return Color(nsColor: .secondaryLabelColor)
        }
        return Color(hex: hex)
    }

    /// The token-kind chart is a single series, so it gets a single hue. Shading
    /// its bars darker-where-bigger would encode bar length twice.
    static func sequentialHex(_ scheme: ColorScheme) -> UInt32 {
        scheme == .dark ? 0xD3714E : 0xD97757
    }

    static func sequential(_ scheme: ColorScheme) -> Color {
        Color(hex: sequentialHex(scheme))
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -6`

Expected: `✔ Test run with 40 tests in 0 suites passed` (35 before, 5 added).

- [ ] **Step 5: Commit**

```bash
git add Sources/YouSage/ChartPalette.swift Tests/YouSageTests/ChartPaletteTests.swift
git commit -m "Add a validated, family-keyed chart palette"
```

---

### Task 5: The three charts

**Files:**
- Create: `Sources/YouSage/UsageCharts.swift`

**Interfaces:**
- Consumes: `DayUsage`, `FamilyTokens`, `ModelCost`, `KindTotal`, `ModelFamily`, `TokenKind` from Tasks 1–2; `ChartPalette.color(for:scheme:)` and `ChartPalette.sequential(_:)` from Task 4; `NumberFormat.tokens(_ value: Int) -> String` and `CostEstimate.display` from the existing codebase.
- Produces: `TrendChart(days: [DayUsage])`, `CostByModelChart(models: [ModelCost])`, `TokenKindChart(kinds: [KindTotal])`. Task 6 composes all three.

This task adds no tests — SwiftUI views have no unit-testable surface here. It is verified by `swift build` and by the manual inspection in Task 6.

**Accepted rendering limitation:** Swift Charts does not expose per-segment corner radii or an inter-segment gap on a stacked `BarMark`. The design's "2px surface gap between fills, 4px rounded data-end" is approximated with `.cornerRadius(2)` on every segment. Do not hand-roll `yStart`/`yEnd` geometry to chase the exact spec — the approximation is deliberate.

- [ ] **Step 1: Write the charts**

Create `Sources/YouSage/UsageCharts.swift`:

```swift
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
                    .annotation(position: .top, spacing: 0,
                                overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
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
            AxisMarks { value in
                AxisGridLine()   // solid hairline; never dashed
                AxisValueLabel {
                    if let count = value.as(Int.self) {
                        Text(NumberFormat.tokens(count))
                    }
                }
            }
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
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .shadow(radius: 2, y: 1)
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
```

- [ ] **Step 2: Verify it builds and nothing regressed**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -3`
Expected: `✔ Test run with 40 tests in 0 suites passed` — unchanged from Task 4.

- [ ] **Step 3: Commit**

```bash
git add Sources/YouSage/UsageCharts.swift
git commit -m "Add trend, cost-by-model, and token-kind charts"
```

---

### Task 6: The window

**Files:**
- Create: `Sources/YouSage/UsageWindow.swift`
- Modify: `Sources/YouSage/App.swift`
- Modify: `Sources/YouSage/PopoverView.swift`

**Interfaces:**
- Consumes: `AppState.shared.usageBreakdown` and `.tokenTrackingEnabled` and `.setTokenTracking(_:)` and `.refresh()` from Task 3; `TrendChart`, `CostByModelChart`, `TokenKindChart` from Task 5; `UsageBreakdown`, `DayUsage`, `ModelCost` from Task 2; `NumberFormat.tokens(_:)` and `CostEstimate.display` from the existing codebase.
- Produces: nothing consumed by later tasks.

This task adds no tests. It ends with a manual inspection, because a window is the one thing a test cannot look at.

- [ ] **Step 1: Write the window**

Create `Sources/YouSage/UsageWindow.swift`:

```swift
import SwiftUI

struct UsageWindow: View {
    @ObservedObject private var state = AppState.shared
    @State private var showTable = false

    var body: some View {
        Group {
            if !state.tokenTrackingEnabled {
                message("Token tracking is off",
                        "YouSage reads Claude Code's local transcripts to count tokens.") {
                    Button("Turn on token tracking") { state.setTokenTracking(true) }
                }
            } else if let breakdown = state.usageBreakdown {
                if breakdown.totals.messages == 0 {
                    message("No activity in the last 7 days",
                            "Nothing in ~/.claude/projects falls inside this window.") { EmptyView() }
                } else {
                    content(breakdown)
                }
            } else {
                message("No Claude Code transcripts found",
                        "YouSage looks in ~/.claude/projects. Chats in the Claude app or on "
                        + "claude.ai draw down the same limits but leave nothing here.") { EmptyView() }
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .task { state.refresh() }
    }

    /// Generic over the action view rather than taking a defaulted opaque type —
    /// `@ViewBuilder action: () -> some View = { EmptyView() }` does not compile.
    private func message<Action: View>(_ title: String, _ detail: String,
                                       @ViewBuilder action: () -> Action) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            action().padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    @ViewBuilder
    private func content(_ breakdown: UsageBreakdown) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(breakdown)

                if showTable {
                    UsageTable(breakdown: breakdown)
                } else {
                    GroupBox("Tokens per day") {
                        TrendChart(days: breakdown.days).padding(.top, 6)
                    }
                    HStack(alignment: .top, spacing: 16) {
                        GroupBox("Cost by model") {
                            CostByModelChart(models: breakdown.models).padding(.top, 6)
                        }
                        GroupBox("Token kind") {
                            TokenKindChart(kinds: breakdown.kinds).padding(.top, 6)
                        }
                    }
                }

                if !breakdown.cost.isComplete {
                    Text("Costs exclude \(breakdown.cost.unpricedModels.joined(separator: ", ")) — "
                         + "no list price is known for \(breakdown.cost.unpricedModels.count == 1 ? "it" : "them"). "
                         + "Totals are lower bounds.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(20)
        }
    }

    private func header(_ breakdown: UsageBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline) {
            kpi(NumberFormat.tokens(breakdown.totals.total), "tokens")
            kpi(breakdown.cost.display, "at API list prices")
            kpi("\(breakdown.totals.messages)", "messages")
            Spacer()
            Picker("", selection: $showTable) {
                Image(systemName: "chart.bar.xaxis").tag(false)
                Image(systemName: "tablecells").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
        .overlay(alignment: .bottomLeading) {
            // The popover's "Last 7 days" is a rolling window pinned to claude.ai's
            // reset. This window is calendar days. The labels keep them apart.
            Text("last 7 calendar days")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .offset(y: 16)
        }
        .padding(.bottom, 16)
    }

    private func kpi(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.trailing, 26)
    }
}

/// The accessible twin every chart is supposed to have, and the place to read
/// exact numbers rather than approximate a bar's length.
private struct UsageTable: View {
    let breakdown: UsageBreakdown

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("By day") {
                Table(breakdown.days) {
                    TableColumn("Day") { day in
                        Text(day.day, format: .dateTime.weekday(.wide).month().day())
                            + Text(day.isToday ? " (so far)" : "")
                    }
                    TableColumn("Models") { day in
                        Text(day.byFamily.map(\.family.displayName).joined(separator: ", "))
                    }
                    TableColumn("Tokens") { day in
                        Text(NumberFormat.tokens(day.totals.total)).monospacedDigit()
                    }
                    TableColumn("Cost") { day in
                        Text(day.cost.display).monospacedDigit()
                    }
                }
                .frame(minHeight: 200)
            }
            GroupBox("By model") {
                Table(breakdown.models) {
                    TableColumn("Model", value: \.displayName)
                    TableColumn("Tokens") { m in
                        Text(NumberFormat.tokens(m.totals.total)).monospacedDigit()
                    }
                    TableColumn("Cost") { m in
                        Text(m.cost.display).monospacedDigit()
                    }
                }
                .frame(minHeight: 120)
            }
        }
    }
}
```

- [ ] **Step 2: Add the window scene**

In `Sources/YouSage/App.swift`, insert this scene directly after the closing `}` of the `MenuBarExtra { ... }.menuBarExtraStyle(.window)` block and before `Window("YouSage Settings", id: "settings")`:

```swift
        Window("Usage Details", id: "usage") {
            UsageWindow()
        }
        .defaultSize(width: 760, height: 640)
```

Do not add `.windowResizability(.contentSize)` here — the charts want a resizable window. Leave the settings window's own modifier untouched.

- [ ] **Step 3: Add the menu item**

In `Sources/YouSage/PopoverView.swift`, the ellipsis `Menu` contains:

```swift
                Divider()
                Button("Settings…") { openSettings() }
```

Replace those two lines with:

```swift
                Divider()
                Button("Usage Details…") { openUsageDetails() }
                Button("Settings…") { openSettings() }
```

Then, directly above the existing `private func openSettings()`, add:

```swift
    private func openUsageDetails() {
        openWindow(id: "usage")
        NSApp.activate(ignoringOtherApps: true)
    }
```

- [ ] **Step 4: Verify it builds and nothing regressed**

Run: `swift build 2>&1 | tail -3`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -3`
Expected: `✔ Test run with 40 tests in 0 suites passed` — unchanged from Task 5.

- [ ] **Step 5: Look at it**

Run: `./build.sh && open build/YouSage.app`

Click the menu bar gauge, then **Usage Details…**. Confirm, and report exactly what you see:

1. A window titled "Usage Details" opens and comes to the front.
2. Three KPI figures across the top, with `last 7 calendar days` beneath them.
3. A "Tokens per day" chart: seven bars labelled with weekday abbreviations, the rightmost drawn at reduced opacity because it is today.
4. Bars are stacked by model family, with a legend below naming only the families you actually used. Opus is terracotta.
5. Hovering a bar shows a tooltip with that day's per-family tokens, its total, and its cost.
6. Beneath: "Cost by model" and "Token kind", each with a dollar or token figure printed at the end of every bar — no hovering required to read any value.
7. Gridlines on the trend chart are solid, not dashed.
8. Toggling the segmented control to the table icon replaces both charts with two sortable tables.
9. The window resizes, and the charts grow with it.
10. Switch macOS to dark mode (System Settings → Appearance) and confirm the bars remain distinguishable against the dark surface.

If the trend chart's bars are all one colour, `chartForegroundStyleScale`'s domain does not match the strings produced by `.foregroundStyle(by:)` — both must be `family.displayName`.

Quit the app from its menu when done.

- [ ] **Step 6: Commit**

```bash
git add Sources/YouSage/UsageWindow.swift Sources/YouSage/App.swift Sources/YouSage/PopoverView.swift
git commit -m "Add the Usage Details window"
```

---

## Self-Review

**Spec coverage.** Native `Window` scene + `defaultSize` + resizable → Task 6 Step 2. Menu item above Settings → Task 6 Step 3. `UsageEvent` + pure `make` → Tasks 1–2. `TokenTracker.breakdown` → Task 3 Step 1. `AppState.usageBreakdown` → Task 3 Steps 2–3. All eight type declarations → Tasks 1–2 Step 3/5. Calendar-day bucketing with DST → Task 2, tested both directions. Zero-filled days → Task 2. Family-keyed fixed palette, both modes, validated hexes → Task 4. Mythos → `.other` → Task 1 test. Trend stacked by family with explicit `chartForegroundStyleScale` → Task 5. Today at reduced opacity → Task 5. Cost-by-model with trailing dollar annotations in family colours → Task 5. Token-kind single hue → Task 5. Solid gridlines → Task 5 (`AxisGridLine()`, no dash). No dual axis anywhere → no chart declares two y-scales. Trend-only tooltip → Task 5 `chartXSelection` + `RuleMark` annotation. Table toggle → Task 6. Four non-happy-path states → Task 6 Step 1. Testing list → Tasks 1, 2, 4.

Two spec items were extended rather than transcribed, both noted at their task: `DayUsage` gained a `cost` field (the spec's tooltip requires the day's cost but its type sketch omitted it), and `modelDisplayName` is extracted as a free function rather than duplicated (which also fixes a live bug where `anthropic.claude-opus-4-8` rendered as `Claude opus.4.8`).

**Placeholder scan.** No TBDs. Every code step carries complete code. Every command has an expected output. The one "approximate the spec" instruction — `.cornerRadius(2)` in place of per-segment gaps — is stated explicitly with the reason, and the plan tells the implementer *not* to chase the exact spec by hand.

**Type consistency.** `TokenTotals` field names match `Models.swift`. `ModelFamily.displayName` is the single string used as both the `chartForegroundStyleScale` domain and the `.foregroundStyle(by:)` value in Task 5. `CostEstimate.display` and `.isComplete` and `.unpricedModels` match the shipped type. `Pricing.isFamily(_:of:)` takes an already-normalized id, and `ModelFamily.init` normalizes before calling it. `NumberFormat.tokens(_:)` takes an `Int`. `ChartPalette.sequentialHex(_:)` is the name used in both the Task 4 test and the Task 4 implementation.

**Known gaps.** `TokenTracker.breakdown` and the three chart views have no unit tests, for the same reason in both cases: an actor with private state and a SwiftUI view have no seam a test can grip. Both are thin — `breakdown` is a `map` plus a call into the twelve-times-tested `make`, and the views are marks over data structures tested elsewhere. Task 6 Step 5's ten-point inspection is their coverage.
