# Cost Estimate + App Icon Implementation Plan

> **Amended during execution.** Task 1's code block below shows the family
> fallback as `normalized.contains($0.name)`. Review found this mispriced legacy
> ids (`claude-3-opus` → current Opus rate) and it was replaced by an
> `isFamily(_:of:)` helper anchored on both edges; `normalize` also gained an
> `anthropic.` provider-prefix strip. The shipped code in
> `Sources/YouSage/Pricing.swift` is authoritative. See the corrected spec.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show what YouSage's tracked tokens would cost at Anthropic's per-token API list prices, and give the app a bundle icon.

**Architecture:** A pure `Pricing` lookup maps a Claude model id to a per-million-token rate; `TokenTracker` (which already tags every transcript event with its model) sums those rates over the session and week windows into a `CostEstimate`; `TokenTrackerView` renders the dollar figure beside the token count it already displays. The icon is a standalone Core Graphics script that emits an `.iconset`, packed to `.icns` by `iconutil`.

**Tech Stack:** Swift 6 toolchain (language mode v5), SwiftPM, SwiftUI, swift-testing, AppKit/Core Graphics, `iconutil`.

## Global Constraints

- **Every `swift test` invocation must be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** `xcode-select` on this machine points at `/Library/Developer/CommandLineTools`, which ships no test frameworks. Without the prefix, `swift test` fails with `error: no such module 'Testing'`. `swift build` and `./build.sh` do **not** need it.
- **Use swift-testing (`import Testing`, `@Test`, `#expect`), not XCTest.** XCTest is unavailable for the same reason.
- Package is `swift-tools-version:6.0`, `swiftLanguageModes: [.v5]`, `platforms: [.macOS(.v14)]`. Do not change these.
- **Do not modify `Sources/YouSage/MenuBarLabel.swift`.** Its SF Symbol gauges already track live usage and are out of scope.
- Rate values are copied verbatim from the spec. Do not adjust, round, or "correct" them:
  `claude-fable-5` 10/50 · `claude-mythos-5` 10/50 · `claude-opus-4-8` 5/25 · `claude-opus-4-7` 5/25 · `claude-opus-4-6` 5/25 · `claude-sonnet-5` 3/15 · `claude-sonnet-4-6` 3/15 · `claude-haiku-4-5` 1/5. Family fallbacks: fable 10/50, mythos 10/50, opus 5/25, sonnet 3/15, haiku 1/5.
- Cache multipliers are exactly `input * 1.25` (write) and `input * 0.10` (read).
- The repo has uncommitted work in `AppState.swift`, `ClaudeClient.swift`, `Models.swift`, `PopoverView.swift`, `SettingsView.swift`, `README.md`, and an untracked `TokenTracker.swift`. **Stage only the files each task names.** Never `git add -A` or `git commit -a`.

## File Structure

| File | Status | Responsibility |
| --- | --- | --- |
| `Package.swift` | Modify | Add the test target. |
| `Sources/YouSage/Pricing.swift` | Create | Model id → rate table, id normalization, `cost(_:model:)`. Pure, no I/O. |
| `Sources/YouSage/Models.swift` | Modify | Add `CostEstimate`; add two fields to `TokenReport`. |
| `Sources/YouSage/TokenTracker.swift` | Modify | Sum per-event cost over each window. |
| `Sources/YouSage/PopoverView.swift` | Modify | Render the dollar figure; extend the info tooltip. |
| `Tests/YouSageTests/PricingTests.swift` | Create | Covers the rate lookup, id normalization, and cache multipliers. |
| `Tests/YouSageTests/CostEstimateTests.swift` | Create | Covers the `≥` lower-bound rendering. |
| `Tools/make-icon.swift` | Create | Draws the icon at each size; writes `Resources/AppIcon.iconset/`. |
| `Resources/AppIcon.icns` | Create | Committed build artifact; `build.sh` already copies it. |
| `.gitignore` | Modify | Ignore the intermediate `.iconset` directory. |

Tasks 1→3 are strictly sequential. Task 4 is independent and may run at any point.

---

### Task 1: Pricing lookup

**Files:**
- Modify: `Package.swift`
- Create: `Sources/YouSage/Pricing.swift`
- Test: `Tests/YouSageTests/PricingTests.swift`

**Interfaces:**
- Consumes: `TokenTotals` from `Sources/YouSage/Models.swift` — a struct with `Int` fields `input`, `output`, `cacheCreation`, `cacheRead`, `messages`, all defaulting to `0`.
- Produces: `struct ModelRate { let input: Double; let output: Double; var cacheWrite: Double; var cacheRead: Double }` and `enum Pricing` with `static func rate(for: String) -> ModelRate?`, `static func normalize(_: String) -> String`, `static func cost(_: TokenTotals, model: String) -> Double?`. Task 2 calls only `Pricing.cost`.

- [ ] **Step 1: Add the test target**

Replace the whole of `Package.swift` with:

```swift
// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "YouSage",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "YouSage",
            path: "Sources/YouSage"
        ),
        .testTarget(
            name: "YouSageTests",
            dependencies: ["YouSage"],
            path: "Tests/YouSageTests"
        )
    ],
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/YouSageTests/PricingTests.swift`:

```swift
import Testing
@testable import YouSage

/// One million tokens of each kind, so a cost assertion reads as the rate itself.
private let oneMillionInput = TokenTotals(input: 1_000_000)
private let oneMillionOutput = TokenTotals(output: 1_000_000)
private let oneMillionCacheWrites = TokenTotals(cacheCreation: 1_000_000)
private let oneMillionCacheReads = TokenTotals(cacheRead: 1_000_000)

@Test func exactModelIDPricesFromTheTable() {
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-4-8") == 5.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-sonnet-4-6") == 3.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-fable-5") == 10.0)
}

@Test func trailingDateStampIsStrippedBeforeLookup() {
    #expect(Pricing.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
    #expect(Pricing.cost(oneMillionInput, model: "claude-haiku-4-5-20251001") == 1.0)
}

@Test func bracketedVariantIsStrippedBeforeLookup() {
    #expect(Pricing.normalize("claude-opus-4-8[1m]") == "claude-opus-4-8")
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-4-8[1m]") == 5.0)
}

@Test func unknownPointReleaseFallsBackToItsFamilyRate() {
    #expect(Pricing.cost(oneMillionInput, model: "claude-sonnet-9-3") == 3.0)
    #expect(Pricing.cost(oneMillionInput, model: "claude-opus-7-0-20301231") == 5.0)
}

@Test func unrecognizedModelIsUnpricedRatherThanFree() {
    #expect(Pricing.cost(oneMillionInput, model: "gpt-5") == nil)
    #expect(Pricing.cost(oneMillionInput, model: "unknown") == nil)
}

@Test func outputBillsAtTheOutputRate() {
    #expect(Pricing.cost(oneMillionOutput, model: "claude-opus-4-8") == 25.0)
}

@Test func cacheWritesBillAtOnePointTwoFiveTimesInput() {
    #expect(Pricing.cost(oneMillionCacheWrites, model: "claude-opus-4-8") == 6.25)
}

@Test func cacheReadsBillAtOneTenthOfInput() {
    #expect(Pricing.cost(oneMillionCacheReads, model: "claude-opus-4-8") == 0.5)
}

@Test func emptyTotalsCostNothingYetAreStillPriced() {
    #expect(Pricing.cost(TokenTotals(), model: "claude-opus-4-8") == 0.0)
}
```

Every expected value above is exactly representable as a `Double`, so `==` is safe here — do not loosen these to tolerance comparisons.

- [ ] **Step 3: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: compile failure, `cannot find 'Pricing' in scope`.

- [ ] **Step 4: Write the implementation**

Create `Sources/YouSage/Pricing.swift`:

```swift
import Foundation

/// Anthropic's list price for one model, in US dollars per million tokens.
///
/// Cache traffic bills off the input rate rather than having rates of its own.
/// The spread matters: cache reads dominate Claude Code's token mix, so pricing
/// them as fresh input would overstate a week of usage several times over.
struct ModelRate: Equatable {
    let input: Double
    let output: Double

    /// 5-minute TTL. Transcripts don't record the TTL, and a 1-hour write
    /// actually costs 2x input, so heavy `ttl: "1h"` use underestimates.
    var cacheWrite: Double { input * 1.25 }
    var cacheRead: Double { input * 0.10 }
}

enum Pricing {
    private static let million = 1_000_000.0

    private static let table: [String: ModelRate] = [
        "claude-fable-5":    ModelRate(input: 10, output: 50),
        "claude-mythos-5":   ModelRate(input: 10, output: 50),
        "claude-opus-4-8":   ModelRate(input: 5,  output: 25),
        "claude-opus-4-7":   ModelRate(input: 5,  output: 25),
        "claude-opus-4-6":   ModelRate(input: 5,  output: 25),
        "claude-sonnet-5":   ModelRate(input: 3,  output: 15),
        "claude-sonnet-4-6": ModelRate(input: 3,  output: 15),
        "claude-haiku-4-5":  ModelRate(input: 1,  output: 5),
    ]

    /// Consulted when an id isn't in `table`, so a point release published after
    /// this code was written still prices at its family's rate instead of
    /// vanishing from the total.
    private static let families: [(name: String, rate: ModelRate)] = [
        ("fable",  ModelRate(input: 10, output: 50)),
        ("mythos", ModelRate(input: 10, output: 50)),
        ("opus",   ModelRate(input: 5,  output: 25)),
        ("sonnet", ModelRate(input: 3,  output: 15)),
        ("haiku",  ModelRate(input: 1,  output: 5)),
    ]

    /// Drops the parts of a model id that never affect price: a bracketed
    /// variant (`[1m]`) and a trailing 8-digit date stamp (`-20251001`).
    static func normalize(_ model: String) -> String {
        var id = model
        if let bracket = id.firstIndex(of: "[") {
            id = String(id[id.startIndex..<bracket])
        }
        var parts = id.split(separator: "-").map(String.init)
        if let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) {
            parts.removeLast()
        }
        return parts.joined(separator: "-")
    }

    static func rate(for model: String) -> ModelRate? {
        if let exact = table[model] { return exact }
        let normalized = normalize(model)
        if let match = table[normalized] { return match }
        return families.first { normalized.contains($0.name) }?.rate
    }

    /// Dollars these counters would cost at `model`'s list price, or nil when
    /// the model can't be priced at all. The nil is deliberate — an unknown
    /// model must surface as a gap, never as a silent zero.
    static func cost(_ totals: TokenTotals, model: String) -> Double? {
        guard let rate = rate(for: model) else { return nil }
        let dollars =
            Double(totals.input) * rate.input
            + Double(totals.output) * rate.output
            + Double(totals.cacheCreation) * rate.cacheWrite
            + Double(totals.cacheRead) * rate.cacheRead
        return dollars / million
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: `✔ Test run with 9 tests in 0 suites passed`.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/YouSage/Pricing.swift Tests/YouSageTests/PricingTests.swift
git commit -m "Add per-token pricing lookup for Claude models"
```

---

### Task 2: Cost estimate on TokenReport

**Files:**
- Modify: `Sources/YouSage/Models.swift`
- Modify: `Sources/YouSage/TokenTracker.swift`
- Test: `Tests/YouSageTests/CostEstimateTests.swift`

**Interfaces:**
- Consumes: `Pricing.cost(_ totals: TokenTotals, model: String) -> Double?` from Task 1. `NumberFormat.amount(_ value: Double, unit: String?) -> String` from `Models.swift` — passing `unit: "USD"` yields `"$4.12"` below \$1,000 and `"$1.2K"` above.
- Produces: `struct CostEstimate: Sendable, Equatable` with `var amount: Double`, `var unpricedModels: [String]`, `var isComplete: Bool`, `var display: String`. `TokenReport` gains stored properties `sessionCost: CostEstimate` and `weekCost: CostEstimate`. Task 3 reads only `report.sessionCost` / `report.weekCost` and their `display`.

- [ ] **Step 1: Write the failing test**

Create `Tests/YouSageTests/CostEstimateTests.swift`:

```swift
import Testing
@testable import YouSage

@Test func aCompleteEstimateRendersAsAPlainAmount() {
    #expect(CostEstimate(amount: 4.12).display == "$4.12")
    #expect(CostEstimate(amount: 27.6).display == "$27.60")
}

@Test func anEstimateWithUnpricedModelsRendersAsALowerBound() {
    let estimate = CostEstimate(amount: 27.6, unpricedModels: ["claude-zeta-9"])
    #expect(estimate.isComplete == false)
    #expect(estimate.display == "≥ $27.60")
}

@Test func anEstimateWithNoUnpricedModelsIsComplete() {
    #expect(CostEstimate(amount: 0).isComplete)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: compile failure, `cannot find 'CostEstimate' in scope`.

- [ ] **Step 3: Add `CostEstimate` to Models.swift**

In `Sources/YouSage/Models.swift`, directly above `struct TokenReport` (which begins with the comment `/// Totals inside the active 5-hour window.` on its first stored property), insert:

```swift
/// What a window's tokens would cost at Anthropic's API list prices. YouSage is
/// a subscription tool — nobody is billed for these. The number answers "what
/// would this have cost per-token?", which is curiosity, not accounting.
struct CostEstimate: Sendable, Equatable {
    /// Dollars across every event whose model could be priced.
    var amount: Double = 0
    /// Models seen in the window but absent from the rate table. A non-empty
    /// list means `amount` is an undercount, and `display` says so.
    var unpricedModels: [String] = []

    var isComplete: Bool { unpricedModels.isEmpty }

    /// "$4.12", or "≥ $27.60" when some of the window couldn't be priced.
    var display: String {
        let money = NumberFormat.amount(amount, unit: "USD")
        return isComplete ? money : "≥ \(money)"
    }
}
```

- [ ] **Step 4: Add the two fields to `TokenReport`**

Still in `Sources/YouSage/Models.swift`, `TokenReport` currently reads:

```swift
struct TokenReport: Sendable, Equatable {
    /// Totals inside the active 5-hour window. Empty when no window is active.
    let session: TokenTotals
    /// Start of the active 5-hour window, nil when there's no recent activity.
    let sessionStart: Date?
    /// True when `sessionStart` was pinned to claude.ai's own `five_hour`
    /// reset time rather than inferred from local timestamps.
    let sessionIsAuthoritative: Bool
    let week: TokenTotals
    let weekStart: Date?
```

Insert `sessionCost` after `sessionIsAuthoritative` and `weekCost` after `weekStart`, so it reads:

```swift
struct TokenReport: Sendable, Equatable {
    /// Totals inside the active 5-hour window. Empty when no window is active.
    let session: TokenTotals
    /// Start of the active 5-hour window, nil when there's no recent activity.
    let sessionStart: Date?
    /// True when `sessionStart` was pinned to claude.ai's own `five_hour`
    /// reset time rather than inferred from local timestamps.
    let sessionIsAuthoritative: Bool
    let sessionCost: CostEstimate
    let week: TokenTotals
    let weekStart: Date?
    let weekCost: CostEstimate
```

Leave the rest of `TokenReport` (`models`, `filesScanned`, `generatedAt`, `hasAnyData`) untouched. Field order here is the memberwise initializer's argument order, which Step 6 relies on.

- [ ] **Step 5: Add the summing helper to TokenTracker**

In `Sources/YouSage/TokenTracker.swift`, immediately after the `modelSplit(_:)` method (which ends with `.sorted { $0.totals.total > $1.totals.total }` followed by `}`), insert:

```swift
    /// Prices a window event-by-event, because the rate depends on which model
    /// produced each turn. Models missing from the table are collected rather
    /// than counted as zero.
    private func costEstimate(_ events: [Event]) -> CostEstimate {
        var estimate = CostEstimate()
        var unpriced: Set<String> = []
        for event in events {
            if let dollars = Pricing.cost(event.totals, model: event.model) {
                estimate.amount += dollars
            } else {
                unpriced.insert(event.model)
            }
        }
        estimate.unpricedModels = unpriced.sorted()
        return estimate
    }
```

- [ ] **Step 6: Populate the new fields**

In `Sources/YouSage/TokenTracker.swift`, the `report(sessionResetsAt:weekResetsAt:)` method ends with a `return TokenReport(...)`. Replace that entire return statement with:

```swift
        return TokenReport(
            session: sessionEvents.reduce(TokenTotals()) { $0 + $1.totals },
            sessionStart: sessionEvents.isEmpty ? nil : sessionStart,
            sessionIsAuthoritative: authoritative,
            sessionCost: costEstimate(sessionEvents),
            week: weekEvents.reduce(TokenTotals()) { $0 + $1.totals },
            weekStart: weekStart,
            weekCost: costEstimate(weekEvents),
            models: modelSplit(sessionEvents),
            filesScanned: filesScanned,
            generatedAt: now
        )
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -20`

Expected: `✔ Test run with 12 tests in 0 suites passed`.

If the build instead fails inside `PopoverView.swift`, that is expected only if you skipped ahead — `TokenTrackerView` does not yet reference the new fields, so it should compile untouched. Any other failure means the `TokenReport` field order in Step 4 disagrees with the initializer call in Step 6.

- [ ] **Step 8: Commit**

```bash
git add Sources/YouSage/Models.swift Sources/YouSage/TokenTracker.swift Tests/YouSageTests/CostEstimateTests.swift
git commit -m "Estimate pay-per-token cost for each usage window"
```

---

### Task 3: Show the cost in the popover

**Files:**
- Modify: `Sources/YouSage/PopoverView.swift:236-300`

**Interfaces:**
- Consumes: `report.sessionCost` and `report.weekCost` (`CostEstimate`) from Task 2, and `CostEstimate.display` (`String`).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Extend the info tooltip**

In `Sources/YouSage/PopoverView.swift`, replace the `sourceNote` constant inside `struct TokenTrackerView` with:

```swift
    private static let sourceNote = """
    Tokens counted from Claude Code transcripts stored on this Mac \
    (~/.claude/projects). Chats in the Claude app, on claude.ai, or on another \
    computer draw down the same limits but aren't counted here.

    Dollar amounts are what these tokens would cost at Anthropic's standard \
    API list prices. You're on a subscription and are not billed for them. \
    Cache writes are priced at 1.25× the input rate, cache reads at 0.1×.
    """
```

- [ ] **Step 2: Pass the estimates into each row**

In the same file, `TokenTrackerView.body` contains two `row(...)` calls. Replace both with:

```swift
            row(title: "Current session",
                subtitle: sessionSubtitle,
                totals: report.session,
                cost: report.sessionCost)

            row(title: "Last 7 days",
                subtitle: nil,
                totals: report.week,
                cost: report.weekCost)
```

- [ ] **Step 3: Render the amount beside the token count**

In the same file, replace the whole of `private func row(title:subtitle:totals:)` with:

```swift
    private func row(title: String, subtitle: String?, totals: TokenTotals, cost: CostEstimate) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .regular))
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    Text(NumberFormat.tokens(totals.total))
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                    Text("·")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                    // Secondary, not the headline: the count is the fact, the
                    // dollar figure is the annotation.
                    Text(cost.display)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Text(totals.breakdown)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
    }
```

- [ ] **Step 4: Verify it builds and the suite still passes**

Run: `swift build 2>&1 | tail -5`
Expected: `Build complete!`

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | tail -5`
Expected: `✔ Test run with 12 tests in 0 suites passed`.

- [ ] **Step 5: Verify it in the running app**

Run: `./build.sh && open build/YouSage.app`

Click the menu bar gauge. In the "Tokens used" section, confirm both rows read `<count> · $<amount>` on one line with the `in … · out … · cache …` breakdown beneath, and that hovering the ⓘ shows both paragraphs of the note. Confirm the dollar figure is *smaller than* the token count would imply if cache were billed as input — a week with a multi-million-token cache should read in the tens of dollars, not the hundreds.

Then quit the app from its menu.

- [ ] **Step 6: Commit**

```bash
git add Sources/YouSage/PopoverView.swift
git commit -m "Show pay-per-token cost beside each token count"
```

---

### Task 4: App icon

Independent of Tasks 1–3.

**Files:**
- Create: `Tools/make-icon.swift`
- Create: `Resources/AppIcon.icns` (generated, committed)
- Modify: `.gitignore`

**Interfaces:**
- Consumes: nothing. `Resources/Info.plist` already declares `CFBundleIconFile` = `AppIcon`, and `build.sh` already copies `Resources/AppIcon.icns` into the bundle when present. No wiring is required.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Ignore the intermediate iconset**

Append one line to `.gitignore`:

```
Resources/AppIcon.iconset/
```

The `.iconset` directory is scratch input for `iconutil`; only the packed `.icns` is committed.

- [ ] **Step 2: Write the generator**

Create `Tools/make-icon.swift`:

```swift
// Draws YouSage's app icon and writes Resources/AppIcon.iconset/.
// Run from the repo root:  swift Tools/make-icon.swift
// Then pack it:            iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns
//
// The tile echoes the menu bar's gauge SF Symbol so the two read as one app.
// The needle angle is fixed here; only the menu bar symbol tracks real usage.

import AppKit
import Foundation

let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

/// Fraction of the gauge sweep that reads as consumed.
let fraction = 0.67
/// The arc runs from 210° counter-clockwise-of-east, clockwise over the top to
/// -30°, leaving a 120° gap at the bottom. 240° of sweep in total.
let sweepStart = 210.0
let sweepDegrees = 240.0

func angle(atFraction t: Double) -> CGFloat {
    CGFloat((sweepStart - sweepDegrees * t) * .pi / 180)
}

func draw(_ c: CGContext, _ s: CGFloat) {
    // Tile: warm cream squircle with a hairline border.
    let inset = s * 0.045
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let corner = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    c.saveGState()
    c.addPath(tilePath)
    c.clip()
    let cream = CGGradient(colorsSpace: colorSpace,
                           colors: [rgb(0xFAF7F2), rgb(0xEDE7DE)] as CFArray,
                           locations: [0, 1])!
    c.drawLinearGradient(cream, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    c.restoreGState()

    c.addPath(tilePath)
    c.setStrokeColor(rgb(0xE0D8CC))
    c.setLineWidth(max(1, s * 0.006))
    c.strokePath()

    let center = CGPoint(x: s * 0.5, y: s * 0.44)
    let radius = s * 0.30
    let arcWidth = s * 0.085
    let start = angle(atFraction: 0)
    let end = angle(atFraction: 1)
    let needleAngle = angle(atFraction: fraction)

    // Unconsumed track.
    c.setLineCap(.round)
    c.setLineWidth(arcWidth)
    c.setStrokeColor(rgb(0xD8D0C6))
    c.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    c.strokePath()

    // Consumed portion, gradient-filled through a clip of its own stroked path.
    c.saveGState()
    c.setLineCap(.round)
    c.setLineWidth(arcWidth)
    c.addArc(center: center, radius: radius, startAngle: start, endAngle: needleAngle, clockwise: true)
    c.replacePathWithStrokedPath()
    c.clip()
    let terracotta = CGGradient(colorsSpace: colorSpace,
                                colors: [rgb(0xD97757), rgb(0xC4603F)] as CFArray,
                                locations: [0, 1])!
    c.drawLinearGradient(terracotta, start: CGPoint(x: 0, y: s), end: .zero, options: [])
    c.restoreGState()

    // Ticks echo `gauge.with.dots`. Below 128px they collapse into noise.
    if s >= 128 {
        let dot = s * 0.013
        for i in 0...8 {
            let t = Double(i) / 8.0
            let a = angle(atFraction: t)
            let p = CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
            c.setFillColor(t <= fraction ? rgb(0xFAF7F2) : rgb(0xBFB5A6))
            c.fillEllipse(in: CGRect(x: p.x - dot, y: p.y - dot, width: dot * 2, height: dot * 2))
        }
    }

    // Tapered needle.
    let length = radius * 0.85
    let halfBase = s * 0.022
    let tip = CGPoint(x: center.x + cos(needleAngle) * length,
                      y: center.y + sin(needleAngle) * length)
    let perp = CGPoint(x: -sin(needleAngle), y: cos(needleAngle))
    let needle = CGMutablePath()
    needle.move(to: CGPoint(x: center.x + perp.x * halfBase, y: center.y + perp.y * halfBase))
    needle.addLine(to: tip)
    needle.addLine(to: CGPoint(x: center.x - perp.x * halfBase, y: center.y - perp.y * halfBase))
    needle.closeSubpath()
    c.addPath(needle)
    c.setFillColor(rgb(0x2A2622))
    c.fillPath()

    // Hub.
    let hub = s * 0.055
    c.setFillColor(rgb(0x2A2622))
    c.fillEllipse(in: CGRect(x: center.x - hub, y: center.y - hub, width: hub * 2, height: hub * 2))
    let inner = s * 0.021
    c.setFillColor(rgb(0xFAF7F2))
    c.fillEllipse(in: CGRect(x: center.x - inner, y: center.y - inner, width: inner * 2, height: inner * 2))
}

func render(px: Int) -> Data {
    guard let c = CGContext(data: nil, width: px, height: px,
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fatalError("could not create a \(px)px context")
    }
    c.setAllowsAntialiasing(true)
    draw(c, CGFloat(px))
    let rep = NSBitmapImageRep(cgImage: c.makeImage()!)
    rep.size = NSSize(width: px, height: px)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("could not encode a \(px)px PNG")
    }
    return data
}

let sizes: [(px: Int, name: String)] = [
    (16, "icon_16x16.png"),     (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),     (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),  (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),  (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),  (1024, "icon_512x512@2x.png"),
]

let iconset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/AppIcon.iconset")

do {
    try? FileManager.default.removeItem(at: iconset)
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    for (px, name) in sizes {
        try render(px: px).write(to: iconset.appendingPathComponent(name))
        print("  \(name) — \(px)px")
    }
    print("wrote \(sizes.count) images to \(iconset.path)")
} catch {
    fatalError("icon generation failed: \(error)")
}
```

- [ ] **Step 3: Generate the images**

Run from the repo root: `swift Tools/make-icon.swift`

Expected: ten lines naming each PNG, then `wrote 10 images to …/Resources/AppIcon.iconset`.

- [ ] **Step 4: Look at the result before packing it**

Open `Resources/AppIcon.iconset/icon_512x512@2x.png` and inspect it. Confirm: a cream rounded square; a gray arc open at the bottom; roughly two-thirds of it overlaid in terracotta running clockwise from the lower-left; eight tick dots on the arc, cream where the terracotta covers them and gray beyond; a charcoal needle pointing up-and-right at the terracotta/gray boundary; a charcoal hub with a cream center.

Then open `Resources/AppIcon.iconset/icon_16x16.png`. Confirm the arc and needle are still distinguishable and that no tick dots are drawn.

If the arc sweeps the wrong way or the needle points into the bottom gap, the sign convention in `angle(atFraction:)` is inverted — the arc must pass through 90° (straight up), not 270°.

- [ ] **Step 5: Pack the .icns**

Run: `iconutil -c icns Resources/AppIcon.iconset -o Resources/AppIcon.icns`

Expected: no output. Then run `ls -la Resources/AppIcon.icns` and confirm a non-empty file (tens of KB).

- [ ] **Step 6: Verify the app picks it up**

Run: `./build.sh`

Expected: the script's output includes `==> Assembling app bundle`, and no error. Then confirm the icon landed in the bundle:

Run: `ls -la build/YouSage.app/Contents/Resources/AppIcon.icns`
Expected: the file exists.

Run: `open build/` and look at `YouSage.app` in Finder — as an icon, and in list view where it renders small. Quit any launched app afterwards.

- [ ] **Step 7: Commit**

```bash
git add .gitignore Tools/make-icon.swift Resources/AppIcon.icns
git commit -m "Add app icon"
```

---

## Self-Review

**Spec coverage.** Rate table → Task 1 Step 4. Cache multipliers → Task 1 Steps 2/4. Four-step id lookup (exact, normalized, family, nil) → Task 1 Step 4, tested in Step 2. `CostEstimate` with `unpricedModels` → Task 2 Step 3. Cost summed in `TokenTracker` over both windows → Task 2 Steps 5–6. Display beside the count reusing `NumberFormat.amount` → Task 3 Step 3. `≥` prefix → Task 2 Step 3, tested. Tooltip text → Task 3 Step 1. Spec's three named test cases (id variants, cache multipliers, zero totals) → Task 1 Step 2. Icon geometry, colors, tick suppression below 128px, fixed needle, generator script, committed `.icns` → Task 4. `MenuBarLabel` untouched → Global Constraints. Accepted inaccuracies are documented as code comments in Task 1's `ModelRate`, not silently dropped.

**Type consistency.** `TokenTotals` field names (`input`, `output`, `cacheCreation`, `cacheRead`) match `Models.swift`. `Pricing.cost(_:model:)` is called with the same signature in Task 1's tests and Task 2's `costEstimate`. `CostEstimate.display` is defined in Task 2 Step 3 and consumed in Task 3 Step 3. `TokenReport`'s field order in Task 2 Step 4 matches the initializer call in Step 6. `angle(atFraction:)` is defined once in Task 4 and used for the track, the fill, the ticks, and the needle.

**Known gap.** `TokenTracker.costEstimate` is not unit-tested — the actor's state is private and driving it would require synthesizing `.jsonl` transcript fixtures. Its logic is a fold over the already-tested `Pricing.cost`, and Task 3 Step 5 exercises it end-to-end against real transcripts. This matches the spec, which scopes testing to `Pricing.cost`.
