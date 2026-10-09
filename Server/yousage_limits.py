#!/usr/bin/python3 -I
"""yousage-limits: this machine's Claude plan limits, read from Claude Code.

Prints the windows Claude Code's `/usage` shows (current session, weekly all
models, weekly per-model caps) with how much of each is used and when it
resets:

  $ yousage-limits
  session 6% (resets 12:59) · week 64% (resets 16:59) · fable week 0%
  $ yousage-limits --json

The source is Claude Code itself, run non-interactively:

  claude -p /usage --output-format stream-json --verbose
         --safe-mode --strict-mcp-config --no-session-persistence

`/usage` is a local command: it makes no model call and costs nothing. Its
stream-json output carries a structured `usage_report.rate_limits` block (the
same `limits` array claude.ai returns, which the Mac app already parses).
Claude Code reads and refreshes its own login; this tool never opens the
credentials file and never sees a token. See docs/limits-source.md.

A run takes ~20 s and ~300 MB, so results are cached for 60 s
(~/.cache/yousage/limits.json) and concurrent callers share one run under a
lock. If a run fails, the last good result is served marked stale.

Exit status: 0 fresh, 3 stale (last good result shown), 1 no data at all.

Python 3 standard library only. Environment:

  YOUSAGE_CLAUDE       claude binary      (default: `claude` on PATH, else
                                           ~/.local/bin/claude)
  YOUSAGE_LIMITS_CACHE cache file         (default ~/.cache/yousage/limits.json)
"""

from __future__ import annotations

import fcntl
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

CACHE_TTL = 60.0
RUN_TIMEOUT = 90.0
SOURCE = "claude /usage"
CLAUDE_ARGS = ["-p", "/usage", "--output-format", "stream-json", "--verbose",
               "--safe-mode", "--strict-mcp-config", "--no-session-persistence"]

# Errors are reported by category only. Claude Code's own output is never
# echoed: whatever it prints stays in this process.
ERR_NOT_FOUND = "claude not found"
ERR_TIMEOUT = "claude /usage timed out"
ERR_AUTH = "not signed in or login expired (run claude to refresh it)"
ERR_NO_LIMITS = "no plan limits reported (API key or non-subscription login?)"
ERR_FAILED = "claude /usage failed"


# -- parsing ------------------------------------------------------------------

def _number(value) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    return None


def _iso(value) -> str | None:
    """Normalizes an ISO 8601 stamp with an offset to UTC `…Z`, seconds."""
    if not isinstance(value, str):
        return None
    try:
        date = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if date.tzinfo is None:
        return None
    return date.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def window_from_limit(entry: dict) -> dict | None:
    """One `limits[]` row → {name, usedPercent, resetsAt, model?, kind}.
    Classified on `kind`/`group`, never on a label, as Claude Code does."""
    percent = _number(entry.get("percent"))
    if percent is None:
        percent = _number(entry.get("utilization"))
    if percent is None:
        return None
    kind = entry.get("kind") if isinstance(entry.get("kind"), str) else ""
    group = entry.get("group") if isinstance(entry.get("group"), str) else ""
    scope = entry.get("scope") if isinstance(entry.get("scope"), dict) else {}
    model = None
    for key in ("model", "surface"):
        part = scope.get(key)
        if isinstance(part, dict) and isinstance(part.get("display_name"), str):
            model = part["display_name"]
            break

    if kind == "session" or (not kind and group == "session"):
        name = "session"
    elif kind == "weekly_all":
        name = "week"
    elif model and (kind.startswith("weekly") or group == "weekly"):
        name = f"{model.lower()} week"
    elif model:
        name = f"{model.lower()} {group or kind or 'limit'}"
    else:
        name = (kind or group or "limit").replace("_", " ")

    window = {
        "name": name,
        "usedPercent": round(percent, 1) if percent % 1 else int(percent),
        "resetsAt": _iso(entry.get("resets_at") or entry.get("reset_at")),
        "kind": kind or group or None,
    }
    if model:
        window["model"] = model
    if isinstance(entry.get("severity"), str):
        window["severity"] = entry["severity"]
    return window


def windows_from_rate_limits(rate_limits: dict) -> list[dict]:
    windows = []
    limits = rate_limits.get("limits")
    if isinstance(limits, list):
        for entry in limits:
            if isinstance(entry, dict):
                window = window_from_limit(entry)
                if window is not None:
                    windows.append(window)
    extra = rate_limits.get("extra_usage")
    if isinstance(extra, dict) and extra.get("is_enabled") is True:
        percent = _number(extra.get("utilization"))
        if percent is not None:
            windows.append({"name": "extra usage", "usedPercent": int(percent),
                            "resetsAt": None, "kind": "extra_usage"})
    return windows


def parse_stream(output: str) -> tuple[list[dict] | None, str | None]:
    """Claude Code's stream-json output → (windows, error category).

    The `/usage` turn is an assistant line with a `usage_report`. Anything
    else — a result with is_error, an auth complaint, no report — maps to one
    of the fixed error categories."""
    report = None
    is_error = False
    for line in output.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            continue
        if not isinstance(obj, dict):
            continue
        if isinstance(obj.get("usage_report"), dict):
            report = obj["usage_report"]
        if obj.get("type") == "result" and obj.get("is_error") is True:
            is_error = True
    if report is not None:
        rate_limits = report.get("rate_limits")
        if isinstance(rate_limits, dict):
            windows = windows_from_rate_limits(rate_limits)
            if windows:
                return windows, None
        return None, ERR_NO_LIMITS
    if is_error or _looks_like_auth_failure(output):
        return None, ERR_AUTH
    return None, ERR_FAILED


def _looks_like_auth_failure(text: str) -> bool:
    lowered = text.lower()
    return any(s in lowered for s in ("not logged in", "please run /login", "oauth token has expired",
                                      "authentication_error", "invalid api key"))


# -- running Claude Code ------------------------------------------------------

def find_claude() -> str | None:
    explicit = os.environ.get("YOUSAGE_CLAUDE")
    if explicit:
        return explicit if os.access(explicit, os.X_OK) else None
    found = shutil.which("claude")
    if found:
        return found
    fallback = os.path.expanduser("~/.local/bin/claude")
    return fallback if os.access(fallback, os.X_OK) else None


def run_claude(claude: str, timeout: float = RUN_TIMEOUT) -> tuple[list[dict] | None, str | None]:
    """Runs `claude -p /usage` in an empty scratch directory, so no project's
    CLAUDE.md, settings or hooks load and nothing is written next to them."""
    with tempfile.TemporaryDirectory(prefix="yousage-limits-") as scratch:
        try:
            proc = subprocess.run([claude, *CLAUDE_ARGS], cwd=scratch, stdin=subprocess.DEVNULL,
                                  capture_output=True, text=True, timeout=timeout)
        except FileNotFoundError:
            return None, ERR_NOT_FOUND
        except subprocess.TimeoutExpired:
            return None, ERR_TIMEOUT
        except OSError:
            return None, ERR_FAILED
    windows, error = parse_stream(proc.stdout)
    if windows is None and error == ERR_FAILED and _looks_like_auth_failure(proc.stderr):
        error = ERR_AUTH
    return windows, error


# -- cache --------------------------------------------------------------------

def cache_path() -> str:
    return os.environ.get("YOUSAGE_LIMITS_CACHE") or os.path.expanduser("~/.cache/yousage/limits.json")


def read_cache(path: str) -> dict | None:
    try:
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or not isinstance(data.get("windows"), list):
        return None
    return data


def write_cache(path: str, data: dict) -> None:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".limits-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            json.dump(data, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass


def _fetched_epoch(data: dict) -> float | None:
    stamp = data.get("fetchedAt")
    if not isinstance(stamp, str):
        return None
    try:
        return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def _stamp(epoch: float) -> str:
    return datetime.fromtimestamp(epoch, timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _usable(cached: dict | None, now: float, ttl: float) -> bool:
    """A good result under `ttl` old, or a failure retried under `ttl` ago."""
    if cached is None:
        return False
    if cached.get("stale") is False:
        stamp = _fetched_epoch(cached)
    else:
        stamp = _number(cached.get("lastAttempt"))
    return stamp is not None and 0 <= now - stamp < ttl


def get_limits(now=time.time, runner=None, path: str | None = None, ttl: float = CACHE_TTL) -> dict:
    """The current limits: from the cache when it's under `ttl` old, else from
    one Claude Code run. Callers that arrive while a run is in flight wait on
    the lock and then read its result instead of starting their own.

    Returns {source, fetchedAt, stale, windows[, error]}; with no good result
    ever, windows is empty and stale is true."""
    path = path or cache_path()
    if runner is None:
        def runner():
            claude = find_claude()
            return run_claude(claude) if claude else (None, ERR_NOT_FOUND)

    cached = read_cache(path)
    if _usable(cached, now(), ttl):
        return cached

    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    with os.fdopen(os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600), "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            # Someone else may have refreshed while we waited for the lock.
            cached = read_cache(path)
            if _usable(cached, now(), ttl):
                return cached
            windows, error = runner()
            if windows is not None:
                data = {"source": SOURCE, "fetchedAt": _stamp(now()), "stale": False,
                        "windows": windows}
            else:
                # Keep the last good windows and their fetchedAt; say why
                # they're old. A failure is retried at most once per ttl.
                base = cached if cached is not None and cached.get("windows") else None
                data = {"source": SOURCE,
                        "fetchedAt": base["fetchedAt"] if base else None,
                        "stale": True,
                        "error": error or ERR_FAILED,
                        "lastAttempt": now(),
                        "windows": base["windows"] if base else []}
            write_cache(path, data)
            return data
        finally:
            fcntl.flock(lock, fcntl.LOCK_UN)


# -- output -------------------------------------------------------------------

def format_reset(stamp: str | None, now: float) -> str | None:
    if not stamp:
        return None
    try:
        when = datetime.fromisoformat(stamp.replace("Z", "+00:00")).astimezone()
    except ValueError:
        return None
    local_now = datetime.fromtimestamp(now).astimezone()
    if when.date() == local_now.date():
        return when.strftime("%H:%M")
    if 0 < (when - local_now).total_seconds() < 6 * 86400:
        return when.strftime("%a %H:%M")
    return when.strftime("%b %d %H:%M")


def format_line(data: dict, now: float) -> str:
    parts = []
    for w in data.get("windows", []):
        text = f"{w.get('name', 'limit')} {w.get('usedPercent', '?')}%"
        # Per-model caps share the weekly reset; the line stays short.
        if not w.get("model"):
            reset = format_reset(w.get("resetsAt"), now)
            if reset:
                text += f" (resets {reset})"
        parts.append(text)
    line = " · ".join(parts) if parts else "no limits"
    if data.get("stale"):
        fetched = _fetched_epoch(data)
        age = f"{int((now - fetched) // 60)}m old" if fetched else "no data"
        line += f" · STALE ({age}: {data.get('error', ERR_FAILED)})"
    return line


def main(argv: list[str]) -> int:
    if any(a in ("-h", "--help") for a in argv):
        print("usage: yousage-limits [--json]\n"
              "Claude plan limits (session, weekly, per-model) via Claude Code's /usage; cached 60 s.")
        return 0
    data = get_limits()
    public = {k: v for k, v in data.items() if k != "lastAttempt"}
    if "--json" in argv:
        print(json.dumps(public, indent=2))
    else:
        print(format_line(public, time.time()))
    if not data.get("windows"):
        return 1
    return 3 if data.get("stale") else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
