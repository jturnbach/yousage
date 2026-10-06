"""Tests for yousage_server. Run: python3 -m unittest -v (from Server/)."""

import gzip
import json
import os
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from http.server import ThreadingHTTPServer

import yousage_server as ys

NOW = datetime(2026, 10, 6, 12, 0, 0, tzinfo=timezone.utc)


def stamp(delta: timedelta) -> str:
    return (NOW + delta).isoformat().replace("+00:00", "Z")


def turn(rid="req_1", mid="msg_1", ts=None, model="claude-opus-4-8",
         usage=None, kind="assistant", content="secret words"):
    obj = {
        "type": kind,
        "timestamp": ts or stamp(timedelta(minutes=-10)),
        "cwd": "/home/agent/private-project",
        "message": {
            "id": mid,
            "model": model,
            "content": [{"type": "text", "text": content}],
            "usage": usage if usage is not None else {
                "input_tokens": 10, "output_tokens": 20,
                "cache_creation_input_tokens": 30, "cache_read_input_tokens": 40,
            },
        },
    }
    if rid is not None:
        obj["requestId"] = rid
    return json.dumps(obj)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = os.path.join(self.tmp.name, "projects")
        os.makedirs(os.path.join(self.root, "-home-agent-proj"))
        self.clock = NOW.timestamp()
        self.scanner = ys.Scanner(self.root, now=lambda: self.clock)

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, lines, mode="w", newline=True):
        path = os.path.join(self.root, name)
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, mode) as f:
            f.write("\n".join(lines) + ("\n" if newline else ""))
        return path


class ParseTests(Fixture):
    def test_assistant_turn_with_usage(self):
        e = self.scanner.parse(turn().encode())
        self.assertEqual((e.id, e.model, e.input, e.output, e.cache_write, e.cache_read),
                         ("req_1", "claude-opus-4-8", 10, 20, 30, 40))

    def test_non_assistant_lines_are_ignored(self):
        self.assertIsNone(self.scanner.parse(turn(kind="user").encode()))
        self.assertIsNone(self.scanner.parse(b'{"type":"summary"}'))
        self.assertIsNone(self.scanner.parse(b"not json but has \"usage\""))

    def test_synthetic_model_is_ignored(self):
        self.assertIsNone(self.scanner.parse(turn(model="<synthetic>").encode()))

    def test_missing_model_is_unknown(self):
        obj = json.loads(turn())
        del obj["message"]["model"]
        self.assertEqual(self.scanner.parse(json.dumps(obj).encode()).model, "unknown")

    def test_message_id_is_the_fallback_key(self):
        self.assertEqual(self.scanner.parse(turn(rid=None, mid="msg_9").encode()).id, "msg_9")

    def test_no_id_at_all_is_dropped(self):
        obj = json.loads(turn(rid=None))
        del obj["message"]["id"]
        self.assertIsNone(self.scanner.parse(json.dumps(obj).encode()))

    def test_zero_usage_is_dropped(self):
        usage = {"input_tokens": 0, "output_tokens": 0}
        self.assertIsNone(self.scanner.parse(turn(usage=usage).encode()))

    def test_bad_timestamp_is_dropped(self):
        self.assertIsNone(self.scanner.parse(turn(ts="yesterday").encode()))
        self.assertIsNone(self.scanner.parse(turn(ts="2026-10-06T10:00:00").encode()))  # no offset

    def test_non_numeric_counts_read_as_zero(self):
        usage = {"input_tokens": "lots", "output_tokens": 5.9, "cache_read_input_tokens": True}
        e = self.scanner.parse(turn(usage=usage).encode())
        self.assertEqual((e.input, e.output, e.cache_read), (0, 5, 0))

    def test_timestamp_is_normalized_to_utc_millis(self):
        e = self.scanner.parse(turn(ts="2026-10-06T14:00:00.123456+02:00").encode())
        self.assertEqual(ys.format_ts(e.date), "2026-10-06T12:00:00.123Z")


class ScanTests(Fixture):
    def ids(self):
        return [e.id for e in self.scanner.recent()]

    def test_dedupes_the_same_request_across_transcripts(self):
        self.write("-home-agent-proj/a.jsonl", [turn("r1"), turn("r2")])
        self.write("-home-agent-proj/b.jsonl", [turn("r2"), turn("r3")])
        self.scanner.scan()
        self.assertEqual(sorted(self.ids()), ["r1", "r2", "r3"])

    def test_incremental_reads_only_appended_lines(self):
        path = self.write("-home-agent-proj/a.jsonl", [turn("r1")])
        self.scanner.scan()
        offset = self.scanner.cursors[path][0]
        self.assertEqual(offset, os.path.getsize(path))
        self.write("-home-agent-proj/a.jsonl", [turn("r2")], mode="a")
        self.scanner.scan()
        self.assertEqual(sorted(self.ids()), ["r1", "r2"])
        self.assertEqual(self.scanner.cursors[path][0], os.path.getsize(path))

    def test_partial_last_line_waits_for_completion(self):
        path = os.path.join(self.root, "-home-agent-proj", "a.jsonl")
        full = turn("r1") + "\n" + turn("r2")
        with open(path, "w") as f:
            f.write(full[:-15])
        self.scanner.scan()
        self.assertEqual(self.ids(), ["r1"])
        with open(path, "w") as f:
            f.write(full + "\n")
        self.scanner.scan()
        self.assertEqual(sorted(self.ids()), ["r1", "r2"])

    def test_replaced_file_is_reread_without_double_counting(self):
        path = self.write("-home-agent-proj/a.jsonl", [turn("r1"), turn("r2")])
        self.scanner.scan()
        tmp = path + ".new"
        with open(tmp, "w") as f:
            f.write(turn("r1") + "\n" + turn("r3") + "\n")
        os.replace(tmp, path)  # new inode
        self.scanner.scan()
        self.assertEqual(sorted(self.ids()), ["r1", "r2", "r3"])

    def test_stale_unread_files_are_skipped_but_tailed(self):
        path = self.write("-home-agent-proj/old.jsonl", [turn("old")])
        old = self.clock - 9 * 24 * 3600
        os.utime(path, (old, old))
        self.scanner.scan()
        self.assertEqual(self.ids(), [])
        self.write("-home-agent-proj/old.jsonl", [turn("new")], mode="a")
        self.scanner.scan()
        self.assertEqual(self.ids(), ["new"])

    def test_hidden_files_and_other_extensions_are_skipped(self):
        self.write(".hidden/a.jsonl", [turn("h1")])
        self.write("-home-agent-proj/.b.jsonl", [turn("h2")])
        self.write("-home-agent-proj/c.json", [turn("h3")])
        self.write("-home-agent-proj/sub/d.jsonl", [turn("ok")])
        self.scanner.scan()
        self.assertEqual(self.ids(), ["ok"])
        self.assertEqual(self.scanner.files_scanned, 1)

    def test_retention_keeps_eight_days(self):
        self.write("-home-agent-proj/a.jsonl", [
            turn("too-old", ts=stamp(timedelta(days=-8, minutes=-1))),
            turn("seven-days", ts=stamp(timedelta(days=-7, hours=-12))),
            turn("today", ts=stamp(timedelta(hours=-1))),
        ])
        self.scanner.scan()
        self.assertEqual(self.ids(), ["seven-days", "today"])
        self.assertNotIn("too-old", self.scanner.seen)

    def test_events_age_out_as_the_clock_moves(self):
        self.write("-home-agent-proj/a.jsonl", [turn("r1", ts=stamp(timedelta(days=-7)))])
        self.scanner.scan()
        self.assertEqual(self.ids(), ["r1"])
        self.clock += 2 * 24 * 3600
        self.scanner.scan()
        self.assertEqual(self.ids(), [])

    def test_recent_is_sorted_oldest_first(self):
        self.write("-home-agent-proj/a.jsonl", [
            turn("late", ts=stamp(timedelta(hours=-1))),
            turn("early", ts=stamp(timedelta(hours=-3))),
        ])
        self.scanner.scan()
        self.assertEqual(self.ids(), ["early", "late"])

    def test_a_single_scan_stops_at_the_byte_budget(self):
        self.write("-home-agent-proj/a.jsonl", [turn(f"a{i}") for i in range(10)])
        self.write("-home-agent-proj/b.jsonl", [turn(f"b{i}") for i in range(10)])
        line = len(turn("a0")) + 1
        old = ys.BYTE_BUDGET_PER_SCAN
        ys.BYTE_BUDGET_PER_SCAN = line * 3 + 5
        try:
            self.assertTrue(self.scanner.scan())
            self.assertEqual(len(self.ids()), 3)
            self.scanner.scan_all()
            self.assertEqual(len(self.ids()), 20)
            self.assertFalse(self.scanner.scan())
        finally:
            ys.BYTE_BUDGET_PER_SCAN = old

    def test_missing_root_is_harmless(self):
        ys.Scanner(os.path.join(self.tmp.name, "nope")).scan()


class AuthTests(unittest.TestCase):
    def test_allowlist(self):
        allow = ys.parse_allowlist("Alice@Example.com, bob@example.com ,")
        self.assertEqual(allow, {"alice@example.com", "bob@example.com"})
        self.assertTrue(ys.is_authorized("alice@example.com", allow))
        self.assertTrue(ys.is_authorized(" ALICE@example.com ", allow))
        self.assertFalse(ys.is_authorized("mallory@example.com", allow))
        self.assertFalse(ys.is_authorized(None, allow))
        self.assertFalse(ys.is_authorized("", allow))

    def test_default_allowlist(self):
        self.assertEqual(ys.parse_allowlist(None), {"jturnbach524@gmail.com"})

    def test_empty_allowlist_denies_everyone(self):
        self.assertFalse(ys.is_authorized("jturnbach524@gmail.com", ys.parse_allowlist("")))


class ServiceTests(Fixture):
    def setUp(self):
        super().setUp()
        self.claude_json = os.path.join(self.tmp.name, "claude.json")
        with open(self.claude_json, "w") as f:
            json.dump({"oauthAccount": {
                "accountUuid": "acct-1", "organizationUuid": "org-1",
                "emailAddress": "someone@example.com", "displayName": "Someone",
            }, "projects": {"/home/agent/private-project": {}}}, f)
        self.write("-home-agent-proj/a.jsonl", [turn("r1"), turn("r2", model="claude-sonnet-5")])
        self.service = ys.UsageService(self.root, self.claude_json, "TServer",
                                       ys.parse_allowlist("me@example.com"),
                                       now=lambda: self.clock)

    def test_rejects_missing_and_unknown_logins(self):
        self.assertEqual(self.service.handle("GET", "/yousage/v1/usage", None)[0], 403)
        self.assertEqual(self.service.handle("GET", "/yousage/v1/usage", "x@example.com")[0], 403)
        # Auth runs before routing, so nothing about the API leaks either.
        self.assertEqual(self.service.handle("GET", "/elsewhere", None)[0], 403)

    def test_routes(self):
        self.assertEqual(self.service.handle("GET", "/yousage/v1/usage", "me@example.com")[0], 200)
        # tailscale serve may strip its mount path before proxying.
        self.assertEqual(self.service.handle("GET", "/v1/usage?x=1", "me@example.com")[0], 200)
        self.assertEqual(self.service.handle("GET", "/yousage/v2/usage", "me@example.com")[0], 404)
        self.assertEqual(self.service.handle("POST", "/yousage/v1/usage", "me@example.com")[0], 405)

    def test_payload_shape_and_privacy(self):
        status, body = self.service.handle("GET", "/yousage/v1/usage", "me@example.com")
        self.assertEqual(status, 200)
        self.assertEqual(set(body), {"version", "host", "account", "generatedAt", "events"})
        self.assertEqual(body["version"], 1)
        self.assertEqual(body["host"], "TServer")
        self.assertEqual(body["account"], {"accountUuid": "acct-1", "organizationUuid": "org-1"})
        self.assertEqual(body["generatedAt"], "2026-10-06T12:00:00.000Z")
        self.assertEqual(len(body["events"]), 2)
        self.assertEqual(set(body["events"][0]),
                         {"id", "ts", "model", "input", "output", "cacheRead", "cacheWrite"})
        text = json.dumps(body)
        for leak in ("someone@example.com", "Someone", "secret words", "private-project",
                     "-home-agent-proj", "a.jsonl"):
            self.assertNotIn(leak, text)

    def test_since_returns_only_the_tail(self):
        self.write("-home-agent-proj/b.jsonl", [turn("old", ts=stamp(timedelta(hours=-5)))])
        _, body = self.service.handle("GET", "/yousage/v1/usage", "me@example.com")
        self.assertEqual(len(body["events"]), 3)
        since = stamp(timedelta(hours=-1)).replace(":", "%3A")
        _, body = self.service.handle("GET", "/yousage/v1/usage?since=" + since, "me@example.com")
        self.assertEqual(sorted(e["id"] for e in body["events"]), ["r1", "r2"])
        self.assertEqual(self.service.handle("GET", "/yousage/v1/usage?since=nope",
                                             "me@example.com")[0], 400)

    def test_missing_account_file(self):
        self.assertEqual(ys.read_account(os.path.join(self.tmp.name, "nope")),
                         {"accountUuid": None, "organizationUuid": None})


class HTTPTests(Fixture):
    """End to end over a real loopback socket."""

    def setUp(self):
        super().setUp()
        self.write("-home-agent-proj/a.jsonl", [turn(f"r{i}") for i in range(1, 21)])
        service = ys.UsageService(self.root, os.path.join(self.tmp.name, "none.json"), "TServer",
                                  ys.parse_allowlist("me@example.com"), now=lambda: self.clock)
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), ys.make_handler(service))
        self.httpd.RequestHandlerClass.log_message = lambda *a: None
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.base = f"http://127.0.0.1:{self.httpd.server_address[1]}"

    def tearDown(self):
        self.httpd.shutdown()
        self.httpd.server_close()
        super().tearDown()

    def get(self, login=None, gzipped=False):
        req = urllib.request.Request(self.base + "/yousage/v1/usage")
        if login:
            req.add_header("Tailscale-User-Login", login)
        if gzipped:
            req.add_header("Accept-Encoding", "gzip")
        try:
            with urllib.request.urlopen(req, timeout=5) as resp:
                data = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    data = gzip.decompress(data)
                return resp.status, json.loads(data)
        except urllib.error.HTTPError as e:
            with e:
                return e.code, json.loads(e.read())

    def test_http(self):
        self.assertEqual(self.get()[0], 403)
        self.assertEqual(self.get("other@example.com")[0], 403)
        status, body = self.get("me@example.com")
        self.assertEqual(status, 200)
        self.assertEqual(len(body["events"]), 20)
        self.assertEqual(self.get("me@example.com", gzipped=True), (status, body))


if __name__ == "__main__":
    unittest.main()
