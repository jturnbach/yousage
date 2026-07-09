# Cost estimate + app icon — design

Date: 2026-07-09

Two independent additions to YouSage:

1. Show what the tracked tokens **would** cost at Anthropic's per-token API list
   prices, alongside the existing token counts.
2. Give the app an icon.

They share no code and can be built in either order.

---

## Part 1 — Pay-per-token cost estimate

### Goal

YouSage already sums the tokens Claude Code spent on this Mac. A subscription
doesn't bill for them. The estimate answers "what would this have cost on the
API?" — a curiosity number, not an invoice.

### Why the data is already there

`TokenTracker.parse(line:)` reads all four usage counters separately —
`input_tokens`, `output_tokens`, `cache_creation_input_tokens`,
`cache_read_input_tokens` — and tags each `Event` with its `model`. Cost is a
rate table applied to counters that already exist. No new parsing.

### Rates

Anthropic prices cache traffic differently from fresh input:

- **cache write** = 1.25× the input rate (5-minute TTL)
- **cache read** = 0.10× the input rate

This is the single most important detail in the feature. `TokenTotals.cache`
routinely dwarfs `input` and `output` combined; pricing it at the plain input
rate would overstate the total by roughly 5–10×.

List prices, USD per million tokens:

| Model ID prefix     | Input | Output |
| ------------------- | ----- | ------ |
| `claude-fable-5`    | 10.00 | 50.00  |
| `claude-mythos-5`   | 10.00 | 50.00  |
| `claude-opus-4-8`   | 5.00  | 25.00  |
| `claude-opus-4-7`   | 5.00  | 25.00  |
| `claude-opus-4-6`   | 5.00  | 25.00  |
| `claude-sonnet-5`   | 3.00  | 15.00  |
| `claude-sonnet-4-6` | 3.00  | 15.00  |
| `claude-haiku-4-5`  | 1.00  | 5.00   |

Family fallbacks, used when no specific ID matches: `opus` → 5/25, `sonnet` →
3/15, `haiku` → 1/5, `fable` → 10/50.

### New file: `Sources/YouSage/Pricing.swift`

```swift
struct ModelRate {
    let input: Double          // USD per 1M tokens
    let output: Double         // USD per 1M tokens
    var cacheWrite: Double { input * 1.25 }
    var cacheRead:  Double { input * 0.10 }
}

enum Pricing {
    /// USD for these counters at `model`'s list price. nil when the model is
    /// unrecognized — better to report a gap than to invent a number.
    static func cost(_ totals: TokenTotals, model: String) -> Double?
}
```

Lookup order, each step falling through to the next:

1. Exact match against the table.
2. Normalize, then match again — strip a leading provider prefix
   (`anthropic.`), any bracketed suffix (`[1m]`), and a trailing 8-digit date
   stamp (`-20251001`). All three appear in real transcripts; `ModelTokens
   .displayName` already strips the same provider prefix.
3. Family match, anchored on both edges: the family word must sit immediately
   after `claude-` and end at a hyphen or the end of the id. So `claude-opus-9-0`
   matches, while `claude-3-opus` (a past generation that priced differently)
   and `claude-opusglobular` (not a model) do not.
4. No match: return `nil`.

### Where the arithmetic lives

`TokenTracker.report(...)` is the only place holding events tagged by model, so
it sums cost there — once over `sessionEvents`, once over `weekEvents`. (The
existing `modelSplit` only covers the session window, so cost cannot be derived
from `TokenReport.models` after the fact.)

New type in `Models.swift`:

```swift
struct CostEstimate: Sendable, Equatable {
    /// USD across every event whose model could be priced.
    var amount: Double = 0
    /// Models encountered but absent from the rate table. Non-empty means
    /// `amount` is an undercount.
    var unpricedModels: [String] = []
}
```

`TokenReport` gains `sessionCost: CostEstimate` and `weekCost: CostEstimate`.

`unpricedModels` exists so a model Anthropic ships after this code was written
degrades into a visible caveat rather than a silently low number.

### Display

Chosen layout: the dollar figure sits beside the token count on each row, so no
vertical space is added.

```
Tokens used ⓘ

Current session              12.4M · $4.12
Since 3:00 PM       in 12K · out 48K · cache 1.3M

Last 7 days                   84.1M · $27.60
                    in 210K · out 890K · cache 8.2M

Opus 4.8 71.2M · Haiku 4.5 12.9M
```

Implemented in `TokenTrackerView.row(title:subtitle:totals:)`, which gains a
`cost: CostEstimate` parameter. The price renders in the secondary text style —
it is context, not the headline.

Formatting reuses `NumberFormat.amount(_:unit: "USD")` unchanged. It already
yields `$4.12` below \$1,000 and `$1.2K` above, which spans a week of heavy use.
No new formatter.

When `unpricedModels` is non-empty the amount is prefixed with `≥` (`≥ $27.60`),
which is the honest claim.

### Tooltip

Fold the caveat into the existing "Tokens used" `InfoTip` rather than adding a
second one. Appended text:

> Dollar amounts are what these tokens would cost at Anthropic's standard API
> list prices. You're on a subscription and are not billed for them. Cache
> writes are priced at 1.25× the input rate, cache reads at 0.1×.

### Accepted inaccuracies

Each is a deliberate simplification, not an oversight:

- **Cache TTL.** Every cache write is priced at the 5-minute rate (1.25×).
  Claude Code's transcripts do not record the TTL. A 1-hour-TTL write really
  costs 2× input, so heavy `ttl: "1h"` use underestimates.
- **Sonnet 5 introductory pricing.** Sonnet 5 carries a promotional \$2/\$10
  rate through 2026-08-31, after which it returns to \$3/\$15. The table uses
  the standard \$3/\$15 rather than encoding a date-dependent rate for a
  promotion that expires within weeks. Slight overestimate until then.
- **Legacy generations report as unpriced, not approximated.** Opus 4.1 and
  earlier, and Haiku 3.x, listed at prices differing from their current family —
  Claude 3 Opus at \$15/\$75 against today's \$5/\$25. Because the family match is
  anchored, `claude-3-opus` does not match `opus`; it returns `nil` and the
  window renders as `≥ $x`. Reporting a gap beats reporting a number that is
  three times wrong. (They cannot appear regardless: the retention window is
  eight days and those models retired months ago.)
- **Future point releases are approximated silently.** `claude-opus-9-0` matches
  the `opus` family and prices at \$5/\$25 with no `≥` marker. If Anthropic
  changes a family's rate, the estimate is quietly wrong until the table is
  updated. This is the deliberate price of the fallback: an unknown *family*
  surfaces as a gap, an unknown *version within a known family* does not.
- **Region-prefixed Bedrock ids** (`us.anthropic.claude-…`) are unpriced. Only
  the bare `anthropic.` prefix is stripped, matching the existing scope of
  `ModelTokens.displayName`.
- **Long-context premiums** are not modeled.

None of these change the number's purpose, which is order-of-magnitude
curiosity. The tooltip says "standard API list prices", not "your bill".

### Testing

`Pricing.cost` is a pure function over `(TokenTotals, String)` and is the only
part with branching worth covering:

- Exact ID, dated ID, bracketed ID, family fallback, unknown ID → `nil`.
- Cache multipliers: a totals value that is pure `cacheRead` costs exactly
  one-tenth of the same value as pure `input`.
- Zero totals → \$0, not `nil`.

---

## Part 2 — App icon

### What already exists

`Info.plist` declares `CFBundleIconFile` = `AppIcon`. `build.sh` copies
`Resources/AppIcon.icns` into the bundle when the file is present. Nothing needs
wiring; only the file is missing.

`MenuBarLabel` renders SF Symbol gauges (`gauge.with.dots.needle.*`) that track
the live percentage. **That stays exactly as it is.** This part adds only the
static bundle icon shown in Finder, Get Info, and the Settings window. (YouSage
is `LSUIElement`, so it has no persistent Dock tile.)

### Design

A rounded-square tile echoing the menu bar gauge, so the two read as the same
app.

- **Background:** warm cream squircle, vertical gradient `#FAF7F2` → `#EDE7DE`,
  with a hairline inner border a shade darker.
- **Track:** a 240° arc (sweeping over the top, gap at the bottom) in muted
  warm gray `#D8D0C6`.
- **Fill:** the consumed portion of the arc, ~67% of the sweep, in a terracotta
  gradient `#D97757` → `#C4603F`.
- **Ticks:** dots along the arc, echoing `gauge.with.dots`. **Rendered only at
  128px and above** — below that they collapse into noise.
- **Needle:** tapered, warm charcoal `#2A2622`, pointing at the ~67% mark.
- **Hub:** charcoal circle with a small cream center dot.

The needle angle is **fixed**. Only the menu bar symbol responds to real usage.

### Generation

`Tools/make-icon.swift` — a standalone script drawing each size into a
`CGContext` via AppKit and writing PNGs into `Resources/AppIcon.iconset/`, then
shelling out to `iconutil -c icns`. No new package dependencies.

Sizes (the standard `.iconset` set): 16, 32, 64, 128, 256, 512, 1024, covering
the `@1x`/`@2x` pairs Apple requires.

The generated `AppIcon.icns` is **committed**, so a fresh clone builds a
correctly-iconed app without running the script. The script is committed too, so
the icon can be regenerated or tweaked.

### Verification

Build the bundle and confirm the icon renders: `./build.sh`, then check
`build/YouSage.app` in Finder and at small sizes in a list view, where the tick
suppression matters most.
