# Usage Details window — design

Date: 2026-07-09

A native macOS window, opened from the menu, showing a visual breakdown of the
tokens Claude Code spent on this Mac over the last seven calendar days.

This is a **SwiftUI `Window` scene rendered with Swift Charts**. Nothing about it
is web-based. It should look like Activity Monitor: system materials, SF Pro,
native light and dark.

---

## Purpose

The popover answers "how close am I to my limits, and what did that cost?" in a
strip 380 points wide. It cannot answer:

- Is my usage trending up or down across the week?
- Which models am I actually reaching for, day to day?
- Where does the *money* go — which is not the same question as where the tokens go?

That last one is the point of the feature. Opus bills at five times Haiku, so a
model can be a large share of your tokens and a rounding error in your bill. The
existing per-model line in the popover shows tokens only, and therefore hides this.

## Non-goals

- **No history beyond the retention window.** `TokenTracker.retention` is 8 days
  and `prune()` discards older events. There is no month view, no all-time view,
  and no on-disk store. If the app hasn't run, that history does not exist.
- No export, no per-project breakdown, no session-block timeline.
- The menu bar gauge and the popover are unchanged.

---

## Where it lives

`App.swift` gains a second `Window` scene beside the existing settings one:

```swift
Window("Usage Details", id: "usage") {
    UsageWindow()
}
.defaultSize(width: 760, height: 640)
```

Resizable — charts benefit from it. (The settings window stays
`.windowResizability(.contentSize)`; this one does not adopt that.)

`PopoverView`'s ellipsis menu gains **Usage Details…** immediately above
**Settings…**, opening it through the same `openWindow(id:)` +
`NSApp.activate(ignoringOtherApps: true)` pattern `openSettings()` already uses.

---

## The data seam

`TokenTracker` already holds everything needed: a private `[Event]`, each tagged
with `date`, `model`, and a `TokenTotals`. It exposes only aggregates.

Rather than widen the actor's surface with view-shaped queries, it emits one flat
value type, and **all bucketing lives in a pure function** that a test can drive
with synthetic events — no transcript fixtures, no filesystem, no actor.

```swift
/// One assistant turn, as the tracker saw it.
struct UsageEvent: Sendable, Equatable {
    let date: Date
    let model: String
    let totals: TokenTotals
}

extension UsageBreakdown {
    /// The last `dayCount` local calendar days ending on `now`'s day.
    /// Days with no activity are present and empty, never absent.
    static func make(from events: [UsageEvent],
                     now: Date,
                     calendar: Calendar,
                     dayCount: Int = 7) -> UsageBreakdown
}
```

`TokenTracker` gains one method, which maps its private `Event` to `UsageEvent`
and delegates:

```swift
func breakdown(now: Date = Date(), calendar: Calendar = .current) -> UsageBreakdown?
```

It returns `nil` only when `isAvailable` is false, matching `report(...)`.

`AppState` gains `@Published private(set) var usageBreakdown: UsageBreakdown?`,
refreshed in `refreshTokens` alongside `tokenReport`. The computation is a fold
over events already in memory; it does not rescan.

### Types

```swift
enum ModelFamily: String, Sendable, CaseIterable {
    case opus, sonnet, haiku, fable, other
    var displayName: String   // "Opus", "Sonnet", "Haiku", "Fable", "Other"

    /// Derived from the id via `Pricing.normalize`, so `anthropic.` prefixes,
    /// `[1m]` variants, and date stamps all resolve the same way pricing does.
    init(modelID: String)
}

struct FamilyTokens: Sendable, Equatable, Identifiable {
    let family: ModelFamily
    let totals: TokenTotals
    var id: ModelFamily { family }
}

struct DayUsage: Sendable, Equatable, Identifiable {
    let day: Date              // calendar.startOfDay, local
    let isToday: Bool          // still accruing; drawn at reduced opacity
    let byFamily: [FamilyTokens]   // families present that day, fixed order
    let totals: TokenTotals
    var id: Date { day }
}

struct ModelCost: Sendable, Equatable, Identifiable {
    let model: String          // raw id, e.g. "claude-opus-4-8"
    let displayName: String    // "Opus 4.8" — reuses ModelTokens.displayName
    let family: ModelFamily
    let totals: TokenTotals
    let cost: CostEstimate
    var id: String { model }
}

enum TokenKind: String, Sendable, CaseIterable {
    case cacheRead, cacheWrite, output, input   // declaration order = display order
    var displayName: String    // "cache read", "cache write", "output", "input"
}

struct KindTotal: Sendable, Equatable, Identifiable {
    let kind: TokenKind
    let count: Int
    var id: TokenKind { kind }
}

struct UsageBreakdown: Sendable, Equatable {
    let days: [DayUsage]       // exactly dayCount, oldest first, zero-filled
    let models: [ModelCost]    // cost descending, then tokens descending
    let kinds: [KindTotal]     // always four, declaration order
    let totals: TokenTotals
    let cost: CostEstimate
    let generatedAt: Date
}
```

`kinds` is a `[KindTotal]` rather than `[(TokenKind, Int)]` because tuples do not
synthesize `Equatable`, and `UsageBreakdown` must be `Equatable` for SwiftUI diffing.

---

## The time window, and why its total differs from the popover's

`TokenTracker.report` defines the week as a **rolling** span: seven days before
claude.ai's weekly reset when that reset is known, otherwise exactly 168 hours
before now. That is what the popover's "Last 7 days" means, and it is correct —
it lines up with the percentage bar directly above it.

This window instead shows **seven local calendar days**, today included and drawn
as partial. A bar labelled "Fri" must be Friday.

**These two totals will not agree, and that is intended.** The window's headline
is the sum of its own bars and is labelled `last 7 calendar days`. It never
claims to be the popover's number. Changing the popover to match was considered
and rejected: it would redefine a shipped number and decouple the token count
from the reset its adjacent percentage tracks.

Calendar-day bucketing goes through `Calendar.startOfDay(for:)`, so a
spring-forward day is 23 hours and a fall-back day is 25, and both land in the
right bucket.

---

## Model colours

Four validated hues plus a neutral. Assignment is **by family, fixed, and
independent of which families are present** — this is what stops a filtered-out
model from repainting the survivors.

| Family | Light | Dark |
|---|---|---|
| Opus | `#D97757` | `#D3714E` |
| Sonnet | `#2a78d6` | `#3987e5` |
| Haiku | `#008300` | `#3aa63a` |
| Fable | `#4a3aa7` | `#9085e9` |
| Other | `secondaryLabelColor` | `secondaryLabelColor` |

Verified with the dataviz validator, both modes: all four inside the lightness
band, all above the chroma floor, all ≥ 3:1 against their surface, worst adjacent
CVD separation ΔE 19.6 against a ≥ 12 target. The terracotta is stepped darker on
the dark surface (`#D3714E`) because `#D97757` sits at OKLCH L 0.672, just above
the dark band's 0.67 ceiling.

`ChartPalette.color(for: ModelFamily, scheme: ColorScheme) -> Color`.

### The trend chart's series is the family, not the model id

Opus 4.7 and Opus 4.8 in the same week would otherwise stack as two segments of
identical terracotta. They price identically, so nothing is lost by folding them.
The **cost list keeps full version detail** — `Opus 4.8` and `Opus 4.7` are
separate rows — so the information is on screen, in the place where it matters.

`claude-mythos-5` maps to `.other`, not to `.fable`. It prices the same as Fable
but it is a different model, and labelling it "Fable" would be a lie.

---

## The three charts

All Swift Charts. Hairline **solid** gridlines (never dashed). A legend is always
present on the trend chart, which has ≥ 2 series. **No chart has two y-scales:**
tokens and dollars never share a plot, because the alignment between two scales
is arbitrary and invents a correlation that is not in the data.

**Trend — daily tokens, stacked by family.** Seven `BarMark`s, `.foregroundStyle(by:)`
family, with an explicit `chartForegroundStyleScale` so the mapping is the fixed
one above rather than Swift Charts' default cycling. Today's bar renders at reduced
opacity, annotated `today`, because it is still accruing.

**Cost by model — horizontal bars.** One row per exact model, sorted by cost
descending, each `.annotation(position: .trailing)` carrying its dollar figure.
Bars take their family's colour, so Opus is the same terracotta here as in the
trend chart.

**Token kind — horizontal bars.** Four rows: cache read, cache write, output,
input; each direct-labelled with its count. **All one colour.** These are one
series; shading each bar darker-where-bigger would encode bar length twice and
add nothing.

### Interaction

A hover tooltip on the **trend chart only**, via `chartOverlay` and `ChartProxy`,
showing the day, each family's tokens, the day's total, and the day's cost. That
is where values are hidden inside stacked segments.

The two composition charts deliberately have no tooltip. The rule is that a
tooltip must never be the *only* way to read a value; those bars are fully
direct-labelled, so every number is already on screen and a tooltip would add a
second path to information the reader already has.

A **Show as table** toggle replaces the charts with a `Table` — the accessible
twin, and the place to read exact per-day, per-model numbers.

---

## States that are not the happy path

| Condition | What the window shows |
|---|---|
| `state.tokenTrackingEnabled == false` | An explanation and a button that enables it. |
| `TokenTracker.isAvailable == false` (no `~/.claude/projects`) | "No Claude Code transcripts found on this Mac," and what that means. |
| Seven consecutive empty days | The axes render, with "No activity in the last 7 days." Not an empty chart with no context. |
| Any model in the span is unpriceable | Every dollar figure carries the `≥` prefix `CostEstimate.display` already produces, and a footnote names the models. |

---

## Files

| File | Status | Responsibility |
|---|---|---|
| `Sources/YouSage/UsageBreakdown.swift` | Create | The types above, and the pure `UsageBreakdown.make(from:now:calendar:dayCount:)`. |
| `Sources/YouSage/ChartPalette.swift` | Create | `ModelFamily` → `Color`, per scheme. |
| `Sources/YouSage/UsageWindow.swift` | Create | Window root: KPI row, empty states, chart/table toggle. |
| `Sources/YouSage/UsageCharts.swift` | Create | The three chart views and the trend tooltip. |
| `Sources/YouSage/TokenTracker.swift` | Modify | `+ breakdown(now:calendar:)`. |
| `Sources/YouSage/AppState.swift` | Modify | `+ @Published usageBreakdown`, refreshed with `tokenReport`. |
| `Sources/YouSage/App.swift` | Modify | `+ Window("Usage Details", id: "usage")`. |
| `Sources/YouSage/PopoverView.swift` | Modify | `+ "Usage Details…"` menu item. |
| `Tests/YouSageTests/UsageBreakdownTests.swift` | Create | Bucketing, folding, zero-fill, cost. |
| `Tests/YouSageTests/ChartPaletteTests.swift` | Create | Family derivation and colour stability. |

`UsageWindow` and `UsageCharts` are separate because the window's job is state and
layout while the charts' job is marks — they change for different reasons.

---

## Testing

`UsageBreakdown.make` is pure over `([UsageEvent], Date, Calendar, Int)` and
carries the coverage:

- Seven days are always returned, oldest first, even from an empty event list.
- A day with no events is present with zero totals — absent days would leave a
  gap in the axis rather than an empty bar.
- The last day is `isToday`; no other day is.
- Events outside the span are excluded.
- Day bucketing is correct across a **spring-forward and a fall-back boundary**,
  driven by a fixed `TimeZone(identifier: "America/New_York")` calendar so the
  test does not depend on the machine's locale.
- `claude-opus-4-8` and `claude-opus-4-7` in one day fold to a single `.opus`
  `FamilyTokens`, while remaining two separate `ModelCost` rows.
- An unpriceable model lands in `.other`, contributes zero dollars, and puts its
  id in `cost.unpricedModels` so the total renders as `≥`.
- `models` sorts by cost descending.
- The four `kinds` always appear, in declaration order, even when zero.

`ChartPalette`:

- `ModelFamily(modelID:)` resolves `anthropic.claude-opus-4-8`, `claude-opus-4-8[1m]`,
  and `claude-haiku-4-5-20251001` correctly, reusing `Pricing.normalize`.
- `claude-3-opus` → `.other`, matching pricing's refusal to treat it as current Opus.
- `claude-mythos-5` → `.other`, not `.fable`.
- Removing a family from the input changes no other family's colour.

The window and chart views have no unit-testable surface; they are verified by
running the app.

---

## Accepted limitations

- **Seven days is the ceiling, forever**, unless a persistent store is added later.
  A fresh install shows only as much history as the local transcripts hold.
- Two versions of one family share a colour in the trend chart. Deliberate; the
  cost list disambiguates.
- `.other` is a single bucket. A week using both Mythos and some unknown model
  would stack them as one gray segment. Acceptable: `.other` should be rare.
- The window's total will not equal the popover's, by construction. Both are
  labelled with the window they describe.
