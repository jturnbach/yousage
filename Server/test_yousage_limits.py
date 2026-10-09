"""Tests for yousage_limits. Run: cd Server && python3 -m unittest -v"""

import io
import json
import os
import stat
import tempfile
import unittest
from contextlib import redirect_stdout
from datetime import datetime, timezone
from unittest import mock

import yousage_limits as yl

HERE = os.path.dirname(os.path.abspath(__file__))
FAKE_TOKEN = "sk-ant-oat01-FAKEFAKEFAKEFAKEFAKEFAKE"


def fixture(name: str) -> str:
    with open(os.path.join(HERE, "fixtures", name), encoding="utf-8") as f:
        return f.read()


def epoch(stamp: str) -> float:
    return datetime.fromisoformat(stamp.replace("Z", "+00:00")).timestamp()


class Clock:
    def __init__(self, t: float):
        self.t = t

    def __call__(self) -> float:
        return self.t


class ParseTests(unittest.TestCase):
    def test_parses_session_week_and_scoped_model(self):
        windows, error = yl.parse_stream(fixture("usage-stream.jsonl"))
        self.assertIsNone(error)
        self.assertEqual([w["name"] for w in windows], ["session", "week", "opus week"])
        self.assertEqual([w["usedPercent"] for w in windows], [34, 61, 48])
        self.assertEqual(windows[0]["resetsAt"], "2026-10-09T16:59:59Z")
        self.assertEqual(windows[2]["model"], "Opus")
        self.assertNotIn("model", windows[0])

    def test_auth_error_maps_to_category(self):
        windows, error = yl.parse_stream(fixture("usage-stream-auth-error.jsonl"))
        self.assertIsNone(windows)
        self.assertEqual(error, yl.ERR_AUTH)

    def test_no_rate_limits(self):
        windows, error = yl.parse_stream(fixture("usage-stream-no-limits.jsonl"))
        self.assertIsNone(windows)
        self.assertEqual(error, yl.ERR_NO_LIMITS)

    def test_garbage_is_a_failure(self):
        self.assertEqual(yl.parse_stream("not json\n{broken"), (None, yl.ERR_FAILED))

    def test_unknown_kinds_and_utilization_key(self):
        windows = yl.windows_from_rate_limits({"limits": [
            {"kind": "daily_thing", "utilization": 12.5, "resets_at": "2026-10-10T00:00:00Z"},
            {"kind": "weekly_scoped", "group": "weekly", "percent": 3,
             "scope": {"surface": {"display_name": "Claude Code"}}},
            {"kind": "session"},  # no percent: dropped
            "nonsense",
        ], "extra_usage": {"is_enabled": True, "utilization": 20}})
        self.assertEqual([w["name"] for w in windows], ["daily thing", "claude code week", "extra usage"])
        self.assertEqual(windows[0]["usedPercent"], 12.5)
        self.assertIsNone(windows[0].get("model"))
        self.assertEqual(windows[1]["model"], "Claude Code")

    def test_bool_is_not_a_percent(self):
        self.assertEqual(yl.windows_from_rate_limits({"limits": [{"kind": "session", "percent": True}]}), [])


class FormatTests(unittest.TestCase):
    def setUp(self):
        self._tz = os.environ.get("TZ")
        os.environ["TZ"] = "America/New_York"
        import time
        time.tzset()

    def tearDown(self):
        import time
        if self._tz is None:
            os.environ.pop("TZ", None)
        else:
            os.environ["TZ"] = self._tz
        time.tzset()

    def test_line(self):
        windows, _ = yl.parse_stream(fixture("usage-stream.jsonl"))
        now = epoch("2026-10-09T12:00:00Z")  # 08:00 in New York
        data = {"windows": windows, "stale": False, "fetchedAt": "2026-10-09T12:00:00Z"}
        self.assertEqual(yl.format_line(data, now),
                         "session 34% (resets 12:59) · week 61% (resets 16:59) · opus week 48%")

    def test_reset_on_another_day_shows_weekday(self):
        now = epoch("2026-10-09T12:00:00Z")
        self.assertEqual(yl.format_reset("2026-10-11T20:00:00Z", now), "Sun 16:00")
        self.assertEqual(yl.format_reset("2026-11-01T20:00:00Z", now), "Nov 01 15:00")
        self.assertIsNone(yl.format_reset(None, now))

    def test_stale_line(self):
        now = epoch("2026-10-09T12:10:00Z")
        data = {"windows": [{"name": "session", "usedPercent": 5, "resetsAt": None}],
                "stale": True, "fetchedAt": "2026-10-09T12:00:00Z", "error": yl.ERR_AUTH}
        self.assertEqual(yl.format_line(data, now),
                         f"session 5% · STALE (10m old: {yl.ERR_AUTH})")


class CacheTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, "sub", "limits.json")
        self.clock = Clock(epoch("2026-10-09T12:00:00Z"))
        self.calls = 0
        self.next = (yl.parse_stream(fixture("usage-stream.jsonl"))[0], None)

    def tearDown(self):
        self.dir.cleanup()

    def runner(self):
        self.calls += 1
        return self.next

    def get(self):
        return yl.get_limits(now=self.clock, runner=self.runner, path=self.path)

    def test_cached_for_60_seconds(self):
        first = self.get()
        self.assertFalse(first["stale"])
        self.assertEqual(first["fetchedAt"], "2026-10-09T12:00:00Z")
        self.clock.t += 59
        self.get()
        self.assertEqual(self.calls, 1)
        self.clock.t += 2
        self.get()
        self.assertEqual(self.calls, 2)

    def test_cache_file_is_private(self):
        self.get()
        self.assertEqual(stat.S_IMODE(os.stat(self.path).st_mode) & 0o077, 0)
        self.assertEqual(stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode) & 0o077, 0)

    def test_failure_keeps_last_good_windows_marked_stale(self):
        good = self.get()
        self.clock.t += 120
        self.next = (None, yl.ERR_AUTH)
        data = self.get()
        self.assertTrue(data["stale"])
        self.assertEqual(data["error"], yl.ERR_AUTH)
        self.assertEqual(data["windows"], good["windows"])
        self.assertEqual(data["fetchedAt"], good["fetchedAt"])
        # A failure is not retried within the ttl either.
        self.clock.t += 30
        self.get()
        self.assertEqual(self.calls, 2)
        # Recovery clears stale.
        self.clock.t += 31
        self.next = (good["windows"], None)
        self.assertFalse(self.get()["stale"])

    def test_failure_with_no_history(self):
        self.next = (None, yl.ERR_NOT_FOUND)
        data = self.get()
        self.assertTrue(data["stale"])
        self.assertEqual(data["windows"], [])
        self.assertIsNone(data["fetchedAt"])

    def test_corrupt_cache_is_ignored(self):
        os.makedirs(os.path.dirname(self.path))
        with open(self.path, "w") as f:
            f.write("{nope")
        self.assertFalse(self.get()["stale"])
        self.assertEqual(self.calls, 1)


class FakeClaudeTests(unittest.TestCase):
    """End to end through run_claude with a stand-in `claude` executable."""

    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.argv_log = os.path.join(self.dir.name, "argv")
        self.cwd_log = os.path.join(self.dir.name, "cwd")

    def tearDown(self):
        self.dir.cleanup()

    def fake(self, stdout_fixture: str | None, stderr: str = "", exit_code: int = 0) -> str:
        path = os.path.join(self.dir.name, "claude")
        body = "#!/bin/sh\n"
        body += f'printf "%s\\n" "$@" > {self.argv_log}\npwd > {self.cwd_log}\n'
        if stdout_fixture:
            body += f"cat {os.path.join(HERE, 'fixtures', stdout_fixture)}\n"
        body += f"echo {FAKE_TOKEN}\n"  # junk on stdout must not leak either
        if stderr:
            body += f"echo '{stderr}' >&2\n"
        body += f"exit {exit_code}\n"
        with open(path, "w") as f:
            f.write(body)
        os.chmod(path, 0o755)
        return path

    def test_runs_usage_in_safe_mode_from_a_scratch_dir(self):
        windows, error = yl.run_claude(self.fake("usage-stream.jsonl"))
        self.assertIsNone(error)
        self.assertEqual(len(windows), 3)
        with open(self.argv_log) as f:
            argv = f.read().split("\n")
        for flag in ("-p", "/usage", "stream-json", "--safe-mode", "--strict-mcp-config",
                     "--no-session-persistence"):
            self.assertIn(flag, argv)
        with open(self.cwd_log) as f:
            self.assertIn("yousage-limits-", f.read())

    def test_expired_login_is_stale_and_never_echoes_output(self):
        claude = self.fake(None, stderr=f"OAuth token has expired: Bearer {FAKE_TOKEN}", exit_code=1)
        cache = os.path.join(self.dir.name, "cache", "limits.json")
        with mock.patch.dict(os.environ, {"YOUSAGE_CLAUDE": claude, "YOUSAGE_LIMITS_CACHE": cache}):
            for args in ([], ["--json"]):
                out = io.StringIO()
                with redirect_stdout(out):
                    code = yl.main(args)
                self.assertEqual(code, 1)
                self.assertNotIn(FAKE_TOKEN, out.getvalue())
                self.assertNotIn("sk-ant", out.getvalue())
                self.assertIn(yl.ERR_AUTH, out.getvalue())
        with open(cache) as f:
            self.assertNotIn("sk-ant", f.read())

    def test_success_output_has_no_token(self):
        claude = self.fake("usage-stream.jsonl", stderr=FAKE_TOKEN)
        cache = os.path.join(self.dir.name, "cache", "limits.json")
        with mock.patch.dict(os.environ, {"YOUSAGE_CLAUDE": claude, "YOUSAGE_LIMITS_CACHE": cache}):
            out = io.StringIO()
            with redirect_stdout(out):
                code = yl.main(["--json"])
        self.assertEqual(code, 0)
        data = json.loads(out.getvalue())
        self.assertEqual(sorted(data), ["fetchedAt", "source", "stale", "windows"])
        self.assertNotIn("sk-ant", out.getvalue())

    def test_missing_claude(self):
        self.assertEqual(yl.run_claude(os.path.join(self.dir.name, "nope")), (None, yl.ERR_NOT_FOUND))

    def test_timeout(self):
        path = os.path.join(self.dir.name, "slow")
        with open(path, "w") as f:
            f.write("#!/bin/sh\nexec sleep 5\n")
        os.chmod(path, 0o755)
        self.assertEqual(yl.run_claude(path, timeout=0.5), (None, yl.ERR_TIMEOUT))

    def test_never_touches_credentials(self):
        with open(yl.__file__, encoding="utf-8") as f:
            source = f.read()
        self.assertNotIn(".credentials", source)
        self.assertNotIn("Authorization", source)


if __name__ == "__main__":
    unittest.main()
