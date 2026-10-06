# YouSage

A tiny macOS menu bar app that mirrors your Claude usage from
[claude.ai/settings/usage](https://claude.ai/settings/usage). Works with both
**subscription** plans (Pro/Max rate limits) and **enterprise / team** plans
with **allotted usage**.

- **Subscription:** shows the current 5-hour session, the weekly all-models
  limit, and **every other limit your account reports** — including per-model
  weekly caps like Fable. New limits appear on their own: the app reads the
  self-describing limit list claude.ai returns rather than a hardcoded set of
  names, so a cap for a model that doesn't exist yet still shows up, correctly
  labelled, with no app update.
- **Enterprise / pay-per-token:** shows allotted usage, extra usage, and prepaid
  usage credits as an absolute "used / total" amount, the derived percentage,
  and when it renews.
- **Plan detection is automatic** — absolute used-of-granted amounts mean an
  enterprise plan, rate-limit percentages mean a subscription. Settings → Plan
  lets you pin it to Subscription or Enterprise if the guess is ever wrong.
- **Token tracker** at the bottom of the popover: tokens used in the current
  5-hour window and over the last 7 days, split into input / output / cache,
  with a per-model breakdown. Counted from Claude Code transcripts on this Mac
  (`~/.claude/projects`) and bucketed into the *same* windows claude.ai reports,
  so the numbers line up with the percentages above them.
- **Remote sources:** Claude Code on your other machines counts too. Any
  server on your Tailscale tailnet running the small YouSage server
  (`Server/`) is found automatically and its tokens join the same windows,
  with a This Mac / server split in the popover. Nothing to configure on the
  Mac. See [Remote sources](#remote-sources).
- Pick which metric the menu bar % reflects — highest of all, allotted usage,
  current session, or weekly all-models.
- Auto-refreshes every 60s in the background, every 15s while the popover is
  open. Pauses on sleep, refreshes on wake.
- Session key is stored in the macOS Keychain and sent only to `claude.ai`.
  The only other traffic is to YouSage servers on your own tailnet.

> The token tracker sees Claude Code on **this Mac**, plus any remote source
> it finds on your tailnet. Conversations in the Claude desktop app, on
> claude.ai, or on a computer without a YouSage server draw down the same
> limits but leave no transcript YouSage can read, so they aren't counted. The
> percentages come from claude.ai and are always complete; the token counts
> are not.

> Unofficial. Not affiliated with Anthropic. Uses undocumented endpoints that
> the claude.ai web app calls — they can change without notice.

## Requirements

macOS 14+ and Swift 6 (Xcode 16+ command-line tools — `xcode-select --install`
is enough).

## Install / Update

One command does everything (build → quit running copy → install to
`/Applications` → relaunch):

```bash
./install.sh
```

Use the same command to update later.

If you only want to build without installing:

```bash
./build.sh   # produces build/YouSage.app
```

Because the bundle is ad-hoc signed, macOS may complain the first time. If it
does:

1. Right-click `YouSage.app` in Finder → **Open** → **Open** again, *or*
2. `xattr -dr com.apple.quarantine /Applications/YouSage.app` and open again.

The app has no Dock icon — it only adds an icon to the menu bar (top right).

## Connect your Claude account

1. Click the menu bar icon → **Connect Claude…**.
2. Follow the in-app instructions to grab the `sessionKey` cookie from
   `claude.ai` (DevTools → Application → Cookies → `https://claude.ai`).
3. Paste, hit **Save & Connect**.

Usage populates within a second or two.

### About the sessionKey

The cookie is long-lived — usually weeks to months. Sharing it with YouSage
does **not** sign you out of your browser. The key will eventually expire (or
get invalidated if you sign out of claude.ai); when that happens YouSage shows
a warning and you re-paste a fresh one.

## How it works

It calls two unofficial endpoints the `claude.ai` web frontend uses:

- `GET https://claude.ai/api/organizations` — to discover your org UUID
- `GET https://claude.ai/api/organizations/{uuid}/usage` — for the usage data

The same `/usage` endpoint serves two shapes, and the parser handles both:

- **Rate-limit (subscription):** a bare `utilization` / `utilization_pct`
  percentage with a rolling `resets_at` / `reset_at` window.
- **Allotment (enterprise / team):** an absolute amount consumed of a granted
  total. The parser probes the common container keys (`allotments`, `limits`,
  `quotas`, `usage`, …) and a broad set of field names (`used` / `consumed` /
  `spent`, `limit` / `allotment` / `quota` / `granted` / `total`, `remaining` /
  `available`), reconstructing whichever of used/total is missing from
  `remaining`, and reads the `unit` / `currency` if present.

Anything usage-shaped that isn't explicitly recognized is still surfaced rather
than dropped, and the **Debug** disclosure inside Settings shows the raw JSON —
so if your plan uses field names not listed above, they're easy to pin down and
add.

## Remote sources

Claude Code running on another machine (a home server, a dev box) spends the
same limits but leaves its transcripts there. Run the YouSage server on that
machine and the Mac picks it up by itself.

**On the server** (Linux): install `Server/` as a systemd service and publish
it on the tailnet with `tailscale serve` at `/yousage`. See
[Server/README.md](Server/README.md). It serves token counts only: no message
content, paths or project names. Only tailnet users on its allowlist get an
answer.

**On the Mac:** nothing. YouSage:

1. runs the Tailscale CLI (`/Applications/Tailscale.app/Contents/MacOS/Tailscale`,
   else `tailscale` on `PATH`) with `status --json`;
2. takes the peers tagged `tag:server` and probes
   `https://<peer>.<tailnet>.ts.net/yousage/v1/usage` with a 5-second timeout;
3. keeps every peer that answers as a source, rediscovering hourly (or a few
   minutes after a failure). Each source is polled at most every 30 seconds,
   fetching only events newer than the last ones it holds;
4. merges a source's events only when its Claude Code is signed in to the
   **same claude.ai organization** the app reads usage for (the org UUID from
   `/api/organizations`). A source on a different organization is listed in
   Settings and ignored;
5. feeds the events into the same `TokenTracker`, deduplicated by request id,
   so the windows, cost estimates and model split all include them, and the
   popover shows a This Mac / server split.

Without Tailscale, or with Tailscale stopped, none of this runs. Settings →
Remote sources lists what was found and how each source is doing, and has a
switch to turn remote sources off.

## Project layout

```
Package.swift            Swift Package manifest (executable target)
Sources/YouSage/         Swift source — App, AppState, ClaudeClient, views
Resources/Info.plist     LSUIElement bundle metadata
build.sh                 Build the .app bundle (release, ad-hoc signed)
install.sh               Build + replace /Applications/YouSage.app + relaunch
Server/                  Remote source for Linux machines (Python, systemd)
```

## Uninstall

```bash
rm -rf /Applications/YouSage.app
security delete-generic-password -s com.john.yousage -a sessionKey 2>/dev/null || true
defaults delete com.john.yousage 2>/dev/null || true
```

## License

MIT.
