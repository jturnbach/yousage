# YouSage remote source (Linux)

Lets the YouSage menu bar app count Claude Code tokens spent on another
machine — a home server, a dev box — alongside the ones spent on the Mac.

`yousage_server.py` scans that machine's Claude Code transcripts
(`~/.claude/projects/**/*.jsonl`) exactly the way the app's `TokenTracker`
does (same fields, same dedupe key, incremental by file offset, 181-day
retention) and serves the events as JSON. Python 3 standard library only.

## API

`GET /yousage/v1/usage[?since=<ISO 8601>]` (also answered at `/v1/usage`, in
case the proxy strips its mount path):

```json
{
  "version": 1,
  "host": "TServer",
  "account": { "accountUuid": "…", "organizationUuid": "…" },
  "generatedAt": "2026-10-06T12:00:00.000Z",
  "events": [
    { "id": "req_…", "ts": "2026-10-06T11:52:03.120Z", "model": "claude-opus-5-5",
      "input": 12, "output": 480, "cacheRead": 81200, "cacheWrite": 1900 }
  ]
}
```

- `events`: one per API call in the last 181 days (or since `since`), oldest
  first. `id` is the transcript's `requestId` (message id as fallback) — the
  same dedupe key the app uses.
- `account`: the two UUIDs from Claude Code's `oauthAccount` in
  `~/.claude.json`. The app merges a source only when its organization matches
  the claude.ai organization the app is signed in to.
- Never returned: message content, file paths, project names, the email
  address, or any token.
- Responses are gzipped when the client accepts it.

## Access control

The service binds `127.0.0.1:3095` only and is published on the tailnet with
`tailscale serve`, which adds a `Tailscale-User-Login` header to every request
from a tailnet user. Requests whose login isn't on the allowlist
(`YOUSAGE_ALLOW`, comma-separated, default `jturnbach524@gmail.com`) get 403,
and so do requests without the header (tagged devices, or anything that didn't
come through serve).

## Install

```bash
sudo Server/install.sh          # copies to /usr/local/lib/yousage-server, enables + starts the unit
sudo tailscale serve --bg --set-path /yousage http://127.0.0.1:3095
tailscale serve status          # /yousage should sit next to any existing handlers
```

The unit (`yousage-server.service`) runs as `agent` with `ProtectSystem=strict`
and `ProtectHome=tmpfs`: of `/home`, only the transcripts directory and
`~/.claude.json` are visible, both read-only. It may only talk to loopback.
Overrides (another port, more logins) go in `/etc/yousage-server.env`.

Check it locally:

```bash
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3095/yousage/v1/usage    # 403
curl -s -H 'Tailscale-User-Login: jturnbach524@gmail.com' \
  http://127.0.0.1:3095/yousage/v1/usage | head -c 300                            # JSON
journalctl -u yousage-server -n 20
```

To update after a `git pull`, rerun `sudo Server/install.sh`.

To remove: `sudo tailscale serve --https=443 --set-path /yousage off`,
`sudo systemctl disable --now yousage-server`, then delete
`/etc/systemd/system/yousage-server.service` and `/usr/local/lib/yousage-server`.

## How the Mac finds it

No setup on the Mac. The app runs `tailscale status --json`, takes online peers
tagged `tag:server`, and probes `https://<peer>/yousage/v1/usage`. Whatever
answers with this payload becomes a source. See the main README.

## Plan limits CLI (`yousage-limits`)

`yousage_limits.py`, installed by `install.sh` as `/usr/local/bin/yousage-limits`,
prints this machine's Claude plan limits (session, weekly, per-model) with
reset times, read from Claude Code's own `/usage` (no model call; cached 60 s):

```
$ yousage-limits
session 7% (resets 12:59) · week 64% (resets 16:59) · fable week 0%
$ yousage-limits --json
```

It never reads Claude Code's credentials. The source and its limits are
described in [docs/limits-source.md](../docs/limits-source.md).

## Tests

```bash
cd Server && python3 -m unittest -v
```
