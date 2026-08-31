#!/usr/bin/env python3
"""Deterministic tests for the batch and live Python log analyzer."""

import importlib.util
import io
import json
import select
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "analyze.py"
SPEC = importlib.util.spec_from_file_location("analyze", SCRIPT)
analyze = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(analyze)


def event_line(event, timestamp="2026-08-31T12:00:00.000Z"):
    payload = {"event": event, "timestamp": timestamp}
    payload.update({"name": "Ghostty", "bundleID": "com.mitchellh.ghostty"})
    return json.dumps(payload) + "\n"


class FakeNotification:
    def __init__(self, ident, fflags=0):
        self.ident = ident
        self.fflags = fflags


class FakeKEvent:
    def __init__(self, ident, *, filter, flags, fflags=0):
        self.ident = ident
        self.filter = filter
        self.flags = flags
        self.fflags = fflags


class FakeKQueue:
    def __init__(self, current_path, rotated_path, replacement_path):
        self.current_path = current_path
        self.rotated_path = rotated_path
        self.replacement_path = replacement_path
        self.active = set()
        self.registered = []
        self.wait_calls = 0
        self.timeouts = []

    def control(self, changes, max_events, timeout=None):
        if changes is not None:
            for change in changes:
                if change.flags & TEST_KQ_EV_ADD:
                    self.active.add(change.ident)
                    self.registered.append(change.ident)
                if change.flags & TEST_KQ_EV_DELETE:
                    self.active.discard(change.ident)
            return []

        self.wait_calls += 1
        self.timeouts.append(timeout)
        directory_fd = self.registered[0]
        file_fds = [fd for fd in self.active if fd != directory_fd]
        if self.wait_calls == 1:
            with self.current_path.open("a", encoding="utf-8") as handle:
                handle.write(event_line("APP_ACTIVATED"))
            return [FakeNotification(file_fds[0], TEST_NOTE_WRITE)]
        if self.wait_calls == 2:
            self.current_path.rename(self.rotated_path)
            self.replacement_path.write_text(
                json.dumps(
                    {
                        "event": "ANOMALY",
                        "timestamp": "2026-08-31T12:00:01.000Z",
                        "anomalyType": "UNKNOWN_BUNDLE",
                        "triggerApp": {"name": "Mystery", "bundleID": "x.mystery"},
                    }
                )
                + "\n",
                encoding="utf-8",
            )
            return [
                FakeNotification(file_fds[0], TEST_NOTE_RENAME),
                FakeNotification(directory_fd, TEST_NOTE_WRITE),
            ]

        replacement_fd = [fd for fd in self.active if fd != directory_fd][0]
        with self.replacement_path.open("a", encoding="utf-8") as handle:
            handle.write(event_line("POLL_FOCUS_CHANGE", "2026-08-31T12:00:02.000Z"))
        return [FakeNotification(replacement_fd, TEST_NOTE_WRITE)]

    def close(self):
        pass


TEST_KQ_FILTER_VNODE = 1
TEST_KQ_EV_ADD = 2
TEST_KQ_EV_CLEAR = 4
TEST_KQ_EV_DELETE = 8
TEST_NOTE_WRITE = 16
TEST_NOTE_EXTEND = 32
TEST_NOTE_RENAME = 64
TEST_NOTE_DELETE = 128


class AnalyzeTests(unittest.TestCase):
    def select_constants(self):
        return {
            "KQ_FILTER_VNODE": TEST_KQ_FILTER_VNODE,
            "KQ_EV_ADD": TEST_KQ_EV_ADD,
            "KQ_EV_CLEAR": TEST_KQ_EV_CLEAR,
            "KQ_EV_DELETE": TEST_KQ_EV_DELETE,
            "NOTE_WRITE": TEST_NOTE_WRITE,
            "NOTE_EXTEND": TEST_NOTE_EXTEND,
            "NOTE_RENAME": TEST_NOTE_RENAME,
            "NOTE_DELETE": TEST_NOTE_DELETE,
        }

    def test_partial_lines_are_buffered_until_newline(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "focus-current.ndjson"
            path.write_text('{"event":"APP_ACTIVATED"', encoding="utf-8")
            reader = analyze._FollowFile(path, start_at_end=False)
            try:
                self.assertEqual(reader.read_events(), [])
                with path.open("a", encoding="utf-8") as handle:
                    handle.write(',"timestamp":"2026-08-31T12:00:00Z"}\n')
                self.assertEqual(reader.read_events()[0]["event"], "APP_ACTIVATED")
            finally:
                reader.close()

    def test_truncation_on_restart_rewinds_reader(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "focus-current.ndjson"
            path.write_text(event_line("APP_ACTIVATED"), encoding="utf-8")
            reader = analyze._FollowFile(path, start_at_end=False)
            try:
                self.assertEqual(len(reader.read_events()), 1)
                path.write_text(event_line("DAEMON_START", "2026-08-31T12:00:03Z"), encoding="utf-8")
                events = reader.read_events()
                self.assertEqual([event["event"] for event in events], ["DAEMON_START"])
            finally:
                reader.close()

    def test_follow_handles_write_rotation_and_replacement_without_spin(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp)
            current = log_dir / "focus-current.ndjson"
            rotated = log_dir / "focus-current.rotated"
            replacement = log_dir / "focus-restarted.ndjson"
            current.write_text(event_line("DAEMON_START"), encoding="utf-8")
            fake_kqueue = FakeKQueue(current, rotated, replacement)
            output = io.StringIO()

            with ExitStack() as stack:
                stack.enter_context(mock.patch.object(analyze, "LOG_DIR", log_dir))
                for name, value in self.select_constants().items():
                    stack.enter_context(mock.patch.object(select, name, value, create=True))
                result = analyze.follow_events(
                    output=output,
                    use_color=False,
                    kqueue_factory=lambda: fake_kqueue,
                    kevent_factory=FakeKEvent,
                    stop_when=lambda: len(output.getvalue().splitlines()) >= 3,
                )

            lines = output.getvalue().splitlines()
            self.assertEqual(result, 0)
            self.assertEqual(len(lines), 3)
            self.assertIn("APP_ACTIVATED", lines[0])
            self.assertIn("⚠ ANOMALY[UNKNOWN_BUNDLE]", lines[1])
            self.assertIn("POLL_FOCUS_CHANGE", lines[2])
            self.assertNotIn("\033[", output.getvalue())
            self.assertEqual(fake_kqueue.wait_calls, 3)
            self.assertEqual(fake_kqueue.timeouts, [0.5, 0.5, 0.5])

    def test_batch_loader_remains_timestamp_sorted(self):
        with tempfile.TemporaryDirectory() as tmp:
            log_dir = Path(tmp)
            (log_dir / "focus-b.ndjson").write_text(
                event_line("LATE", "2026-08-31T12:00:02Z"), encoding="utf-8"
            )
            (log_dir / "focus-a.ndjson").write_text(
                event_line("EARLY", "2026-08-31T12:00:01Z"), encoding="utf-8"
            )
            with mock.patch.object(analyze, "LOG_DIR", log_dir):
                events = analyze.load_events()
            self.assertEqual([event["event"] for event in events], ["EARLY", "LATE"])

    def test_follow_reports_platform_requirement_without_kqueue(self):
        with tempfile.TemporaryDirectory() as tmp:
            with mock.patch.object(analyze, "LOG_DIR", Path(tmp)), mock.patch.object(analyze.sys, "platform", "linux"):
                result = analyze.follow_events(output=io.StringIO())
            self.assertEqual(result, 2)


if __name__ == "__main__":
    unittest.main()
