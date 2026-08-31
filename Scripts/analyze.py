#!/usr/bin/env python3
"""Analyze attention-thief-catcher focus logs.

Usage:
    python3 analyze.py                           # Full analysis
    python3 analyze.py --anomalies               # Anomalies only
    python3 analyze.py --last 2h                 # Last 2 hours
    python3 analyze.py --last 30m                # Last 30 minutes
    python3 analyze.py --around "2026-02-02T15:30:00"  # ±30s around timestamp
"""

import argparse
import json
import os
import re
import select
import sys
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from pathlib import Path


LOG_DIR = Path.home() / "Library" / "Logs" / "attention-thief-catcher"


def parse_timestamp(ts_str):
    """Parse ISO8601 timestamp string to UTC datetime."""
    # Strip timezone info — all daemon timestamps are UTC
    ts_str = ts_str.rstrip("Z")
    if "+" in ts_str[10:]:
        ts_str = ts_str[:ts_str.rindex("+")]
    elif ts_str.count("-") > 2:
        # Timezone offset with minus after date
        parts = ts_str.rsplit("-", 1)
        if len(parts[1]) <= 6:  # looks like tz offset
            ts_str = parts[0]
    for fmt in (
        "%Y-%m-%dT%H:%M:%S.%f",
        "%Y-%m-%dT%H:%M:%S",
    ):
        try:
            return datetime.strptime(ts_str, fmt).replace(tzinfo=timezone.utc)
        except ValueError:
            continue
    return None


def parse_duration(s):
    """Parse duration string like '2h', '30m', '1d' to timedelta."""
    m = re.match(r"^(\d+)([smhd])$", s)
    if not m:
        print(f"Invalid duration: {s}. Use e.g. 30m, 2h, 1d", file=sys.stderr)
        sys.exit(1)
    val = int(m.group(1))
    unit = m.group(2)
    if unit == "s":
        return timedelta(seconds=val)
    elif unit == "m":
        return timedelta(minutes=val)
    elif unit == "h":
        return timedelta(hours=val)
    elif unit == "d":
        return timedelta(days=val)


def load_events(after=None, before=None):
    """Load all NDJSON events from log files, optionally filtered by time."""
    events = []
    if not LOG_DIR.exists():
        print(f"No log directory found at {LOG_DIR}", file=sys.stderr)
        sys.exit(1)

    log_files = sorted(LOG_DIR.glob("focus-*.ndjson"))
    if not log_files:
        print(f"No log files found in {LOG_DIR}", file=sys.stderr)
        sys.exit(1)

    for path in log_files:
        with open(path) as f:
            for line_num, line in enumerate(f, 1):
                line = line.strip()
                if not line:
                    continue
                try:
                    obj = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts_str = obj.get("timestamp")
                if ts_str:
                    ts = parse_timestamp(ts_str)
                    if ts:
                        obj["_ts"] = ts
                        obj["_source"] = path.name
                        if after and ts < after:
                            continue
                        if before and ts > before:
                            continue
                events.append(obj)

    events.sort(key=lambda e: e.get("_ts", datetime.min))
    return events


def parse_event_line(line, after=None, before=None):
    """Decode one NDJSON line and apply optional timestamp filters."""
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        return None

    if not isinstance(event, dict):
        return None

    timestamp = event.get("timestamp")
    if timestamp:
        parsed = parse_timestamp(timestamp)
        if parsed:
            event["_ts"] = parsed
            if after and parsed < after:
                return None
            if before and parsed > before:
                return None
    elif after or before:
        # A time-windowed follow cannot place an event without a timestamp.
        return None

    return event


class _FollowFile:
    """A newline-buffered reader for one inode currently being followed."""

    def __init__(self, path, start_at_end):
        self.path = path
        self.handle = open(path, "r", encoding="utf-8", errors="replace", newline="")
        stat_result = os.fstat(self.handle.fileno())
        self.identity = (stat_result.st_dev, stat_result.st_ino)
        self.buffer = ""
        if start_at_end:
            self.handle.seek(0, os.SEEK_END)

    @property
    def fd(self):
        return self.handle.fileno()

    def current_size(self):
        try:
            return os.fstat(self.fd).st_size
        except OSError:
            return None

    def read_events(self, after=None, before=None):
        """Read complete lines, preserving an incomplete final line."""
        size = self.current_size()
        if size is not None and self.handle.tell() > size:
            # The daemon may have truncated a file in place during restart.
            self.handle.seek(0)
            self.buffer = ""

        self.buffer += self.handle.read()
        events = []
        while "\n" in self.buffer:
            line, self.buffer = self.buffer.split("\n", 1)
            line = line.rstrip("\r")
            if not line.strip():
                continue
            event = parse_event_line(line, after=after, before=before)
            if event is not None:
                events.append(event)
        return events

    def close(self):
        self.handle.close()


def _follow_vnode_flags():
    """Return vnode flags used by follow mode on macOS."""
    return (
        _kq_constant("NOTE_WRITE")
        | _kq_constant("NOTE_EXTEND")
        | _kq_constant("NOTE_RENAME")
        | _kq_constant("NOTE_DELETE")
    )


def _kq_constant(name):
    """Support both CPython's KQ_NOTE_* and older NOTE_* spellings."""
    value = getattr(select, name, None)
    if value is not None:
        return value
    return getattr(select, f"KQ_{name}")


def _event_display(event):
    """Format one event as a compact line suitable for a live terminal."""
    timestamp = event.get("timestamp", "?")
    event_type = event.get("event", "?")
    if event_type == "ANOMALY":
        anomaly_type = event.get("anomalyType", "UNKNOWN")
        trigger = event.get("triggerApp") or {}
        name = trigger.get("name") or event.get("name", "")
        bundle_id = trigger.get("bundleID") or event.get("bundleID", "")
        line = f"{timestamp}  ⚠ ANOMALY[{anomaly_type}]"
    else:
        name = event.get("name", "")
        bundle_id = event.get("bundleID", "")
        line = f"{timestamp}  {event_type}"

    if name:
        line += f"  {name}"
    if bundle_id:
        line += f" ({bundle_id})"
    detail = event.get("detail", "")
    if detail:
        line += f"  [{detail}]"
    return line


def _emit_follow_event(event, output, use_color):
    line = _event_display(event)
    if use_color:
        color = "\033[31m" if event.get("event") == "ANOMALY" else "\033[36m"
        line = f"{color}{line}\033[0m"
    print(line, file=output, flush=True)


def follow_events(
    after=None,
    before=None,
    anomalies_only=False,
    output=None,
    use_color=None,
    kqueue_factory=None,
    kevent_factory=None,
    stop_when=None,
    timeout=0.5,
):
    """Follow NDJSON logs using macOS vnode notifications.

    Existing files are tailed from EOF. Files created or replaced after startup
    are read from the beginning, which preserves lines written during rotation
    and daemon restart. ``kqueue_factory`` and ``stop_when`` are intentionally
    injectable so tests can exercise this loop without sleeping or macOS.
    """
    if kqueue_factory is None and (
        sys.platform != "darwin"
        or not hasattr(select, "kqueue")
        or not hasattr(select, "kevent")
    ):
        print("--follow requires macOS kqueue support", file=sys.stderr)
        return 2
    if not LOG_DIR.exists():
        print(f"No log directory found at {LOG_DIR}", file=sys.stderr)
        return 1

    output = output or sys.stdout
    if use_color is None:
        use_color = bool(getattr(output, "isatty", lambda: False)())
    kqueue_factory = kqueue_factory or select.kqueue
    kevent_factory = kevent_factory or select.kevent
    kq = kqueue_factory()
    directory_fd = os.open(LOG_DIR, os.O_RDONLY)
    readers = {}
    retired_identities = set()

    def register(fd):
        kq.control(
            [kevent_factory(
                fd,
                filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_ADD | select.KQ_EV_CLEAR,
                fflags=_follow_vnode_flags(),
            )],
            0,
        )

    def unregister(fd):
        try:
            kq.control([kevent_factory(
                fd,
                filter=select.KQ_FILTER_VNODE,
                flags=select.KQ_EV_DELETE,
            )], 0)
        except OSError:
            pass

    def sync_files(start_at_end):
        paths = set(LOG_DIR.glob("focus-*.ndjson"))
        identities = set()
        for path in paths:
            try:
                stat_result = os.stat(path)
                identities.add((stat_result.st_dev, stat_result.st_ino))
            except OSError:
                continue

        for path in sorted(paths):
            try:
                stat_result = os.stat(path)
                identity = (stat_result.st_dev, stat_result.st_ino)
            except OSError:
                continue
            if identity in retired_identities:
                continue
            reader_for_identity = next(
                (reader for reader in readers.values() if reader.identity == identity),
                None,
            )
            if reader_for_identity is not None:
                reader_for_identity.path = path
                continue
            try:
                reader = _FollowFile(path, start_at_end=start_at_end)
            except OSError:
                # Rotation can remove a path between stat and open; the
                # directory vnode event will cause another discovery pass.
                continue
            readers[reader.fd] = reader
            register(reader.fd)
            if not start_at_end:
                for event in reader.read_events(after=after, before=before):
                    if not anomalies_only or event.get("event") == "ANOMALY":
                        _emit_follow_event(event, output, use_color)

        for fd, reader in list(readers.items()):
            if reader.identity in identities:
                continue
            for event in reader.read_events(after=after, before=before):
                if not anomalies_only or event.get("event") == "ANOMALY":
                    _emit_follow_event(event, output, use_color)
            unregister(reader.fd)
            reader.close()
            retired_identities.add(reader.identity)
            del readers[fd]

    try:
        register(directory_fd)
        sync_files(start_at_end=True)
        while True:
            if stop_when and stop_when():
                break
            events = kq.control(None, 64, timeout)
            directory_changed = False
            file_replaced = False
            for notification in events:
                if notification.ident == directory_fd:
                    directory_changed = True
                    continue
                reader = readers.get(notification.ident)
                if reader is None:
                    continue
                for event in reader.read_events(after=after, before=before):
                    if not anomalies_only or event.get("event") == "ANOMALY":
                        _emit_follow_event(event, output, use_color)
                if getattr(notification, "fflags", 0) & (_kq_constant("NOTE_DELETE") | _kq_constant("NOTE_RENAME")):
                    reader_fd = reader.fd
                    unregister(reader_fd)
                    reader.close()
                    retired_identities.add(reader.identity)
                    del readers[reader_fd]
                    file_replaced = True

            if directory_changed or file_replaced:
                sync_files(start_at_end=False)
    except KeyboardInterrupt:
        return 0
    finally:
        for reader in readers.values():
            unregister(reader.fd)
            reader.close()
        unregister(directory_fd)
        os.close(directory_fd)
        close = getattr(kq, "close", None)
        if close:
            close()
    return 0


def print_header(title):
    """Print a section header."""
    print()
    print(f"{'=' * 60}")
    print(f"  {title}")
    print(f"{'=' * 60}")


def analyze_anomalies(events):
    """Show all anomaly events."""
    anomalies = [e for e in events if e.get("event") == "ANOMALY"]
    print_header(f"ANOMALIES ({len(anomalies)} total)")

    if not anomalies:
        print("  No anomalies detected.")
        return

    by_type = defaultdict(list)
    for a in anomalies:
        by_type[a.get("anomalyType", "UNKNOWN")].append(a)

    for atype, items in sorted(by_type.items()):
        print(f"\n  {atype} ({len(items)} occurrences)")
        print(f"  {'-' * 40}")
        for item in items[:20]:  # Show first 20 per type
            ts = item.get("timestamp", "?")
            detail = item.get("detail", "")
            trigger = item.get("triggerApp", {})
            app_name = trigger.get("name", "?")
            bundle_id = trigger.get("bundleID", "?")
            detected_by = item.get("detectedBy", "notification")
            print(f"    {ts}  {app_name} ({bundle_id})")
            print(f"      {detail}  [via {detected_by}]")
            snapshot = item.get("processSnapshot", "")
            if snapshot:
                lines = snapshot.strip().split("\n")
                print(f"      Process snapshot ({len(lines)} processes):")
                for ps_line in lines[:10]:
                    print(f"        {ps_line}")
                if len(lines) > 10:
                    print(f"        ... and {len(lines) - 10} more")
        if len(items) > 20:
            print(f"    ... and {len(items) - 20} more")


def analyze_focus_frequency(events):
    """Show which apps received focus most often."""
    activations = [e for e in events if e.get("event") in ("APP_ACTIVATED", "POLL_FOCUS_CHANGE")]
    print_header(f"FOCUS FREQUENCY ({len(activations)} activations)")

    if not activations:
        print("  No activation events.")
        return

    counter = Counter()
    for e in activations:
        name = e.get("name", "?")
        bid = e.get("bundleID", "?")
        counter[f"{name} ({bid})"] += 1

    for app, count in counter.most_common(20):
        bar = "#" * min(count, 50)
        print(f"  {count:5d}  {app}")
        print(f"         {bar}")


def analyze_rapid_switches(events):
    """Find clusters of rapid focus switching."""
    activations = [e for e in events if e.get("event") in ("APP_ACTIVATED", "POLL_FOCUS_CHANGE") and "_ts" in e]
    print_header("RAPID FOCUS SWITCH CLUSTERS")

    if len(activations) < 2:
        print("  Not enough data.")
        return

    # Find 5-second windows with 4+ switches
    clusters = []
    i = 0
    while i < len(activations):
        window = [activations[i]]
        j = i + 1
        while j < len(activations):
            if (activations[j]["_ts"] - activations[i]["_ts"]).total_seconds() <= 5.0:
                window.append(activations[j])
                j += 1
            else:
                break
        if len(window) >= 4:
            clusters.append(window)
            i = j  # skip past this cluster
        else:
            i += 1

    if not clusters:
        print("  No rapid switch clusters found (threshold: 4+ in 5s).")
        return

    print(f"  Found {len(clusters)} cluster(s):\n")
    for ci, cluster in enumerate(clusters[:10], 1):
        t0 = cluster[0]["_ts"]
        t1 = cluster[-1]["_ts"]
        dur = (t1 - t0).total_seconds()
        print(f"  Cluster {ci}: {len(cluster)} switches in {dur:.1f}s")
        print(f"  Start: {cluster[0].get('timestamp', '?')}")
        apps_in_cluster = []
        for e in cluster:
            apps_in_cluster.append(e.get("name", "?"))
        print(f"  Apps: {' -> '.join(apps_in_cluster)}")
        print()


def analyze_system_events(events):
    """Show sleep/wake and session events."""
    system_types = {
        "SYSTEM_WILL_SLEEP", "SYSTEM_DID_WAKE",
        "SCREENS_DID_SLEEP", "SCREENS_DID_WAKE",
        "SESSION_BECAME_ACTIVE", "SESSION_RESIGNED_ACTIVE",
        "DAEMON_START",
    }
    system_events = [e for e in events if e.get("event") in system_types]
    print_header(f"SYSTEM EVENTS ({len(system_events)} total)")

    if not system_events:
        print("  No system events.")
        return

    for e in system_events:
        ts = e.get("timestamp", "?")
        event = e.get("event", "?")
        print(f"  {ts}  {event}")


def analyze_poll_catches(events):
    """Show focus changes caught by polling but missed by notifications."""
    poll_changes = [e for e in events if e.get("event") == "POLL_FOCUS_CHANGE"]
    print_header(f"POLL-DETECTED FOCUS CHANGES ({len(poll_changes)} total)")

    if not poll_changes:
        print("  None — all focus changes were caught by notifications.")
        return

    print("  These focus changes were MISSED by notifications (caught by polling):\n")
    for e in poll_changes[:30]:
        ts = e.get("timestamp", "?")
        name = e.get("name", "?")
        bid = e.get("bundleID", "?")
        prev_pid = e.get("previousPID", "?")
        print(f"  {ts}  -> {name} ({bid})  [prev PID: {prev_pid}]")
    if len(poll_changes) > 30:
        print(f"  ... and {len(poll_changes) - 30} more")


def analyze_correlations(events):
    """Look for patterns: which apps often steal focus after wake/sleep."""
    print_header("WAKE/SLEEP FOCUS CORRELATION")

    wake_events = [e for e in events if e.get("event") == "SYSTEM_DID_WAKE" and "_ts" in e]
    activations = [e for e in events if e.get("event") in ("APP_ACTIVATED", "POLL_FOCUS_CHANGE") and "_ts" in e]

    if not wake_events or not activations:
        print("  Not enough data for correlation analysis.")
        return

    # Find first activation within 10s after each wake
    post_wake_apps = Counter()
    for we in wake_events:
        wake_ts = we["_ts"]
        for ae in activations:
            if "_ts" not in ae:
                continue
            delta = (ae["_ts"] - wake_ts).total_seconds()
            if 0 < delta <= 10:
                name = ae.get("name", "?")
                bid = ae.get("bundleID", "?")
                post_wake_apps[f"{name} ({bid})"] += 1
                break

    if post_wake_apps:
        print("  First app to steal focus after wake:\n")
        for app, count in post_wake_apps.most_common(10):
            print(f"  {count:5d}x  {app}")
    else:
        print("  No post-wake focus changes detected.")


def analyze_around(events, center_ts):
    """Show all events within ±30s of the given timestamp."""
    window = timedelta(seconds=30)
    center = parse_timestamp(center_ts)
    if not center:
        print(f"Could not parse timestamp: {center_ts}", file=sys.stderr)
        sys.exit(1)

    filtered = [e for e in events if "_ts" in e and abs((e["_ts"] - center).total_seconds()) <= window.total_seconds()]
    print_header(f"EVENTS AROUND {center_ts} (±30s, {len(filtered)} events)")

    if not filtered:
        print("  No events in this window.")
        return

    for e in filtered:
        ts = e.get("timestamp", "?")
        event = e.get("event", "?")
        name = e.get("name", "")
        bid = e.get("bundleID", "")
        detail = e.get("detail", "")
        line = f"  {ts}  {event}"
        if name:
            line += f"  {name}"
        if bid:
            line += f" ({bid})"
        if detail:
            line += f"  [{detail}]"
        print(line)


def summary(events):
    """Print a quick summary."""
    if not events:
        print("No events to analyze.")
        return

    ts_list = [e["_ts"] for e in events if "_ts" in e]
    if ts_list:
        print(f"\n  Time range: {min(ts_list)} to {max(ts_list)}")
        print(f"  Duration:   {max(ts_list) - min(ts_list)}")
    print(f"  Total events: {len(events)}")

    event_counts = Counter(e.get("event", "?") for e in events)
    print("  Event types:")
    for etype, cnt in event_counts.most_common():
        print(f"    {cnt:5d}  {etype}")


def main():
    parser = argparse.ArgumentParser(description="Analyze attention-thief-catcher logs")
    parser.add_argument("--anomalies", action="store_true", help="Show anomalies only")
    parser.add_argument("--last", type=str, help="Filter to last N time (e.g. 2h, 30m, 1d)")
    parser.add_argument("--around", type=str, help="Show events ±30s around ISO8601 timestamp")
    parser.add_argument("--follow", action="store_true", help="Follow new events using macOS kqueue")
    args = parser.parse_args()

    if args.follow and args.around:
        parser.error("--follow cannot be combined with --around")

    after = None
    before = None
    if args.last:
        delta = parse_duration(args.last)
        after = datetime.now(timezone.utc) - delta

    if args.follow:
        return follow_events(after=after, anomalies_only=args.anomalies)

    events = load_events(after=after, before=before)

    print(f"Loaded {len(events)} events from {LOG_DIR}")
    summary(events)

    if args.around:
        analyze_around(events, args.around)
        return

    if args.anomalies:
        analyze_anomalies(events)
        return

    # Full analysis
    analyze_anomalies(events)
    analyze_focus_frequency(events)
    analyze_rapid_switches(events)
    analyze_system_events(events)
    analyze_poll_catches(events)
    analyze_correlations(events)


if __name__ == "__main__":
    sys.exit(main() or 0)
