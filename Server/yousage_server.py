#!/usr/bin/env python3
"""YouSage remote source: serves this machine's Claude Code token usage.

Scans Claude Code transcripts (~/.claude/projects/**/*.jsonl) exactly the way
the Mac app's TokenTracker does — same fields, same dedupe key, incremental by
byte offset, 8-day retention — and serves the resulting events as JSON at
GET /yousage/v1/usage (optionally ?since=<ISO 8601>), so the Mac can bucket them into its own windows.

Only token counts leave this machine: never message content, file paths or
project names. The account block carries the Claude account and organization
UUIDs (so the Mac can tell whether this is the same account), never the email
address or any token.

Binds to loopback only. It is meant to sit behind `tailscale serve`, which
stamps every tailnet request with a Tailscale-User-Login header; a request
whose login isn't on the allowlist — or that carries no login at all — gets 403.

Python 3 standard library only. Configuration comes from the environment:

  YOUSAGE_BIND         listen address           (default 127.0.0.1)
  YOUSAGE_PORT         listen port              (default 3095)
  YOUSAGE_ALLOW        comma-separated allowed Tailscale logins
                                                (default jturnbach524@gmail.com)
  YOUSAGE_PROJECTS     transcript root          (default ~/.claude/projects)
  YOUSAGE_CLAUDE_JSON  Claude Code config file  (default ~/.claude.json)
  YOUSAGE_HOST         host label in responses  (default: the hostname)
"""

from __future__ import annotations

import gzip
import json
import os
import socket
import sys
import threading
import time
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

VERSION = 1

# Mirrors TokenTracker.swift.
RETENTION = 8 * 24 * 3600
BYTE_BUDGET_PER_SCAN = 96 * 1024 * 1024
USAGE_MARKER = b'"usage"'

# A request never triggers more than one scan per this many seconds; anything
# in between is served from the last result.
MIN_SCAN_INTERVAL = 5.0

PATHS = ("/yousage/v1/usage", "/v1/usage")
DEFAULT_ALLOW = "jturnbach524@gmail.com"


def parse_iso8601(stamp: str) -> datetime | None:
    """ISO 8601 with an explicit offset, like ClaudeClient.parseISO8601."""
    try:
        date = datetime.fromisoformat(stamp)
    except (TypeError, ValueError):
        return None
    if date.tzinfo is None:
        return None
    return date


def format_ts(date: datetime) -> str:
    """UTC, millisecond precision, `Z` suffix — what Swift's
    ISO8601DateFormatter reads with .withFractionalSeconds."""
    utc = date.astimezone(timezone.utc)
    return utc.strftime("%Y-%m-%dT%H:%M:%S.") + f"{utc.microsecond // 1000:03d}Z"


def _int(value) -> int:
    # bool is an int subclass; a JSON true is not a token count.
    if isinstance(value, bool):
        return 0
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    return 0


class Event:
    __slots__ = ("id", "date", "model", "input", "output", "cache_read", "cache_write")

    def __init__(self, id, date, model, input, output, cache_read, cache_write):
        self.id = id
        self.date = date
        self.model = model
        self.input = input
        self.output = output
        self.cache_read = cache_read
        self.cache_write = cache_write

    def to_json(self) -> dict:
        return {
            "id": self.id,
            "ts": format_ts(self.date),
            "model": self.model,
            "input": self.input,
            "output": self.output,
            "cacheRead": self.cache_read,
            "cacheWrite": self.cache_write,
        }


class Scanner:
    """Incremental transcript scanner; a port of TokenTracker's scan/parse."""

    def __init__(self, root: str, now=time.time):
        self.root = root
        self.now = now
        # path -> (offset, identity). Identity is (st_dev, st_ino): Linux has no
        # creation date, and a new inode at the same path means the file was
        # replaced and the old offset is meaningless.
        self.cursors: dict[str, tuple[int, tuple[int, int]]] = {}
        self.events: list[Event] = []
        self.seen: set[str] = set()
        self.files_scanned = 0

    # -- parsing ------------------------------------------------------------

    def parse(self, line: bytes) -> Event | None:
        # Most lines aren't assistant turns; skip the decode unless a usage
        # block is present.
        if USAGE_MARKER not in line:
            return None
        try:
            obj = json.loads(line)
        except (ValueError, UnicodeDecodeError):
            return None
        if not isinstance(obj, dict) or obj.get("type") != "assistant":
            return None
        message = obj.get("message")
        if not isinstance(message, dict):
            return None
        usage = message.get("usage")
        if not isinstance(usage, dict):
            return None

        # Placeholder turns (model `<synthetic>`) never hit the API.
        model = message.get("model")
        if not isinstance(model, str):
            model = "unknown"
        if model.startswith("<"):
            return None

        # requestId is per API call and unique; message id is the fallback. The
        # same turn is replayed into every transcript that resumes it.
        rid = obj.get("requestId")
        mid = message.get("id")
        event_id = rid if isinstance(rid, str) else (mid if isinstance(mid, str) else None)
        if event_id is None or event_id in self.seen:
            return None

        stamp = obj.get("timestamp")
        date = parse_iso8601(stamp) if isinstance(stamp, str) else None
        if date is None:
            return None

        input_ = _int(usage.get("input_tokens"))
        output = _int(usage.get("output_tokens"))
        cache_write = _int(usage.get("cache_creation_input_tokens"))
        cache_read = _int(usage.get("cache_read_input_tokens"))
        if input_ + output + cache_write + cache_read <= 0:
            return None

        return Event(event_id, date, model, input_, output, cache_read, cache_write)

    # -- scanning -----------------------------------------------------------

    def _walk(self):
        """Every *.jsonl under root, skipping hidden files and directories
        (FileManager's .skipsHiddenFiles)."""
        for dirpath, dirnames, filenames in os.walk(self.root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".")]
            for name in filenames:
                if name.endswith(".jsonl") and not name.startswith("."):
                    yield os.path.join(dirpath, name)

    def scan(self) -> None:
        if not os.path.isdir(self.root):
            return
        cutoff = self.now() - RETENTION
        budget = BYTE_BUDGET_PER_SCAN
        count = 0

        for path in self._walk():
            count += 1
            try:
                st = os.stat(path)
            except OSError:
                continue
            identity = (st.st_dev, st.st_ino)
            size = st.st_size

            existing = self.cursors.get(path)
            if existing is not None and existing[1] == identity and size >= existing[0]:
                offset = existing[0]
            elif existing is None and st.st_mtime < cutoff:
                # Never read and untouched for longer than we retain: nothing in
                # it can land in a window. Mark it consumed so later appends are
                # still picked up without reading its history.
                self.cursors[path] = (size, identity)
                continue
            else:
                # New, or replaced/truncated under us: read from the top. The
                # dedupe set keeps a re-read from double counting.
                offset = 0

            if size <= offset or budget <= 0:
                self.cursors[path] = (offset, identity)
                continue
            consumed = self._ingest(path, offset, budget)
            budget -= consumed
            self.cursors[path] = (offset + consumed, identity)

        self.files_scanned = count
        self._prune()

    def _ingest(self, path: str, offset: int, budget: int) -> int:
        """Reads appended bytes up to the last complete line, so a half-written
        record is re-read next scan rather than dropped. Returns bytes used."""
        try:
            with open(path, "rb") as f:
                f.seek(offset)
                data = f.read(budget)
        except OSError:
            return 0
        last_newline = data.rfind(b"\n")
        if last_newline < 0:
            return 0
        complete = data[: last_newline + 1]
        for line in complete.split(b"\n"):
            if not line:
                continue
            event = self.parse(line)
            if event is not None:
                self.events.append(event)
                self.seen.add(event.id)
        return len(complete)

    def _prune(self) -> None:
        cutoff = self.now() - RETENTION
        if not any(e.date.timestamp() < cutoff for e in self.events):
            return
        self.events = [e for e in self.events if e.date.timestamp() >= cutoff]
        self.seen = {e.id for e in self.events}

    def recent(self, since: float | None = None) -> list[Event]:
        """Events inside the retention window (and at or after `since`, epoch
        seconds, when given), oldest first."""
        cutoff = self.now() - RETENTION
        if since is not None:
            cutoff = max(cutoff, since)
        return sorted((e for e in self.events if e.date.timestamp() >= cutoff),
                      key=lambda e: e.date)


def read_account(path: str) -> dict:
    """Only the two UUIDs from Claude Code's oauthAccount; never the email,
    names or anything else in that file."""
    account = {"accountUuid": None, "organizationUuid": None}
    try:
        with open(path, "rb") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return account
    oauth = data.get("oauthAccount") if isinstance(data, dict) else None
    if isinstance(oauth, dict):
        for key in account:
            value = oauth.get(key)
            if isinstance(value, str) and value:
                account[key] = value
    return account


def parse_allowlist(raw: str | None) -> frozenset[str]:
    raw = DEFAULT_ALLOW if raw is None else raw
    return frozenset(x.strip().lower() for x in raw.split(",") if x.strip())


def is_authorized(login: str | None, allow: frozenset[str]) -> bool:
    """tailscale serve sets Tailscale-User-Login for requests from tailnet
    users. No header means the request didn't come through serve from a user
    (a tagged device, or a local process) — rejected like a wrong login."""
    if not login:
        return False
    return login.strip().lower() in allow


class UsageService:
    def __init__(self, projects: str, claude_json: str, host: str, allow: frozenset[str],
                 now=time.time):
        self.scanner = Scanner(projects, now=now)
        self.claude_json = claude_json
        self.host = host
        self.allow = allow
        self.now = now
        self.lock = threading.Lock()
        self.last_scan = 0.0

    def payload(self, since: float | None = None) -> dict:
        with self.lock:
            now = self.now()
            if now - self.last_scan >= MIN_SCAN_INTERVAL or self.last_scan == 0.0:
                self.scanner.scan()
                self.last_scan = now
            events = [e.to_json() for e in self.scanner.recent(since)]
        return {
            "version": VERSION,
            "host": self.host,
            "account": read_account(self.claude_json),
            "generatedAt": format_ts(datetime.fromtimestamp(self.now(), timezone.utc)),
            "events": events,
        }

    def handle(self, method: str, path: str, login: str | None) -> tuple[int, dict]:
        if not is_authorized(login, self.allow):
            return 403, {"error": "forbidden"}
        if method != "GET":
            return 405, {"error": "method not allowed"}
        url = urlsplit(path)
        if url.path.rstrip("/") not in PATHS:
            return 404, {"error": "not found"}
        # ?since=<ISO 8601> limits events to those at or after it, so a client
        # that already holds the history only pulls the tail.
        since = None
        raw = parse_qs(url.query).get("since")
        if raw:
            date = parse_iso8601(raw[0])
            if date is None:
                return 400, {"error": "bad since"}
            since = date.timestamp()
        return 200, self.payload(since)


def make_handler(service: UsageService):
    class Handler(BaseHTTPRequestHandler):
        server_version = "yousage-server"
        sys_version = ""

        def _respond(self):
            status, body = service.handle(self.command, self.path,
                                          self.headers.get("Tailscale-User-Login"))
            data = json.dumps(body, separators=(",", ":")).encode()
            gzipped = "gzip" in self.headers.get("Accept-Encoding", "").lower() and len(data) > 1024
            if gzipped:
                data = gzip.compress(data, compresslevel=6)
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            if gzipped:
                self.send_header("Content-Encoding", "gzip")
            self.send_header("Vary", "Accept-Encoding")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)

        do_GET = do_POST = do_PUT = do_DELETE = do_PATCH = do_HEAD = _respond

        def log_message(self, fmt, *args):
            # Method, path and status only: no client identity in the journal.
            sys.stderr.write("%s %s %s\n" % (self.command, self.path.split("?", 1)[0],
                                              args[1] if len(args) > 1 else "-"))

    return Handler


def main() -> None:
    home = os.path.expanduser("~")
    service = UsageService(
        projects=os.environ.get("YOUSAGE_PROJECTS", os.path.join(home, ".claude", "projects")),
        claude_json=os.environ.get("YOUSAGE_CLAUDE_JSON", os.path.join(home, ".claude.json")),
        host=os.environ.get("YOUSAGE_HOST") or socket.gethostname(),
        allow=parse_allowlist(os.environ.get("YOUSAGE_ALLOW")),
    )
    bind = os.environ.get("YOUSAGE_BIND", "127.0.0.1")
    port = int(os.environ.get("YOUSAGE_PORT", "3095"))
    httpd = ThreadingHTTPServer((bind, port), make_handler(service))
    httpd.daemon_threads = True
    sys.stderr.write(f"yousage-server listening on {bind}:{port}, "
                     f"{len(service.allow)} allowed login(s)\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
