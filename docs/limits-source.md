# Plan limits on a Linux machine: where the numbers come from

`yousage-limits` (Server/yousage_limits.py) prints the plan limits Claude
Code's `/usage` shows: the current session window, the weekly all-models
limit, and every per-model weekly cap. For each it gives the used % and the
reset time. Investigated 2026-10-09 against Claude Code 2.1.295.

## What was checked

| Path | Result |
| --- | --- |
| `claude --help`, `claude usage`, `claude auth status` | No usage subcommand. `auth` only covers login/logout/status. |
| Status line JSON (`rate_limits`) | Official and structured (`five_hour`, `seven_day`, `seven_day_opus/sonnet`, `model_scoped[]`), but it is only pushed to a status-line command while an interactive session renders. Using it means a settings change, and the data goes stale when no session is open. Not used. |
| `claude -p "/usage"` | **Works.** `/usage` is a local command: `num_turns: 0`, `total_cost_usd: 0`, and no model call. Plain or `--output-format json` gives the human text in `result`. |
| `claude -p "/usage" --output-format stream-json --verbose` | **Used.** The assistant line carries a structured `usage_report.rate_limits` with the same self-describing `limits[]` array that claude.ai's `/usage` returns, which the Mac app's `ClaudeClient.parseSections` already parses: `kind` (`session`, `weekly_all`, `weekly_scoped`), `group`, `percent`, `resets_at` (ISO 8601), `scope.model.display_name`, `severity`, and `extra_usage`. |
| `GET https://api.anthropic.com/api/oauth/usage` with the OAuth bearer from `~/.claude/.credentials.json` | What `/usage` calls internally. **Not needed and not used**, because the CLI path above gives the same data without YouSage ever touching the token. |

The Mac app gets its limits from a different place:
`https://claude.ai/api/organizations/{org}/usage`, authenticated with a pasted
claude.ai `sessionKey` cookie. TServer has no sessionKey, only Claude Code's
OAuth login. Asking Claude Code itself returns the same `limits[]` shape, so
the parsing rules match: classify on `kind`/`group` and take a scoped row's
label from the server.

## How it runs

```
claude -p /usage --output-format stream-json --verbose \
       --safe-mode --strict-mcp-config --no-session-persistence
```

- It runs in a fresh empty temp directory, so no project's CLAUDE.md,
  settings or hooks load. `--safe-mode` also turns off user plugins, hooks and
  MCP servers, and `--no-session-persistence` keeps the run out of
  `~/.claude/projects`.
- Cost: no model call. Each run takes about 18 s and about 290 MB RSS, mostly
  because `/usage` also builds its "what's contributing" summary. Results are
  therefore cached for 60 s in `~/.cache/yousage/limits.json` (mode 0600, dir
  0700). Concurrent callers wait on a lock and share one run, so there is at
  most one run per minute. A failed run is also retried at most once per
  minute.
- Tokens: YouSage never reads `~/.claude/.credentials.json` and never sees a
  token. Claude Code refreshes its own login as it normally does. Claude
  Code's stdout and stderr are never echoed. Errors are reported only as fixed
  categories (`not signed in or login expired`, `timed out`, `claude not
  found`, …), and a test checks that a token-like string in Claude Code's
  output never reaches yousage-limits' output or cache.
- On failure, the last good windows are shown marked `stale`, with their
  original `fetchedAt` and the error category. Exit status: 0 fresh, 3 stale,
  1 no data.

## Output

```
$ yousage-limits
session 7% (resets 12:59) · week 64% (resets 16:59) · fable week 0%
$ yousage-limits --json
{"source": "claude /usage", "fetchedAt": "…Z", "stale": false,
 "windows": [{"name": "session", "usedPercent": 7, "resetsAt": "…Z", "kind": "session", …},
             {"name": "fable week", "usedPercent": 0, "resetsAt": "…Z", "kind": "weekly_scoped",
              "model": "Fable", …}]}
```

Reset times are local, as `HH:MM` today, `Ddd HH:MM` within a week, and
`Mon DD HH:MM` after that. Per-model caps omit the reset on the terse line,
because they share the weekly reset. `--json` has every reset.

## Caveats

- The `usage_report` field is in Claude Code's stream-json output, but this
  is not a documented contract. If a future version drops it, the CLI reports
  `claude /usage failed` (stale) rather than guessing. The fallback would be
  parsing the `result` text, which this tool deliberately doesn't do.
- The Mac app was not changed: it already shows these limits from claude.ai.
