# YouSage

A tiny macOS menu bar app that mirrors your Claude subscription usage from
[claude.ai/settings/usage](https://claude.ai/settings/usage).

- Shows current 5-hour session % and weekly limits (All models, Sonnet only,
  Claude Design / Opus, OAuth apps).
- Pick which metric the menu bar % reflects — highest of all, current session,
  or weekly all-models.
- Auto-refreshes every 60s in the background, every 15s while the popover is
  open. Pauses on sleep, refreshes on wake.
- Session key is stored in the macOS Keychain. Network traffic goes only to
  `claude.ai`.

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

The parser tolerates both the `utilization` / `utilization_pct` and
`resets_at` / `reset_at` field-name variants that community reverse-engineering
efforts have reported, and surfaces any unknown usage-shaped fields so new
Anthropic categories show up automatically.

If Anthropic changes the schema, the **Debug** disclosure inside Settings shows
the raw JSON so the parser is easy to update.

## Project layout

```
Package.swift            Swift Package manifest (executable target)
Sources/YouSage/         Swift source — App, AppState, ClaudeClient, views
Resources/Info.plist     LSUIElement bundle metadata
build.sh                 Build the .app bundle (release, ad-hoc signed)
install.sh               Build + replace /Applications/YouSage.app + relaunch
```

## Uninstall

```bash
rm -rf /Applications/YouSage.app
security delete-generic-password -s com.john.yousage -a sessionKey 2>/dev/null || true
defaults delete com.john.yousage 2>/dev/null || true
```

## License

MIT.
