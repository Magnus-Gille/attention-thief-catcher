# Attention Thief Catcher — Project Status

**Last updated:** 2026-02-03

## What this project does
Background daemon that logs every macOS focus change to catch an intermittent
bug where the active window loses focus and the GUI becomes unresponsive.
Prime suspect: `com.lwouis.alt-tab-macos` (AltTab), especially after sleep/wake.

## What's been built (all complete)

### Sources/attention-thief-catcher.swift
Single-file Swift CLI daemon. Three subsystems on one RunLoop:
1. **Event Monitor** — NSWorkspace notifications for app activate/deactivate/launch/terminate, sleep/wake, screen lock/unlock, session events
2. **Polling Safety Net** — checks frontmostApplication every 3s, catches missed notifications
3. **Anomaly Detector** — flags RAPID_FOCUS, NON_REGULAR_ACTIVATION, UNKNOWN_BUNDLE, JUST_LAUNCHED_ACTIVATION; captures `ps` snapshot on anomaly

Log writer: NDJSON, fsync after every write, 50MB rotation, periodic snapshots every 5min.

### LaunchAgents/com.magnusgille.attention-thief-catcher.plist
launchd user agent: RunAtLoad, KeepAlive on crash, background priority, Aqua only.
Binary at ~/.local/bin/attention-thief-catcher.

### Scripts/install.sh
Compiles with `swiftc -O`, installs binary, loads agent via `launchctl bootstrap`.

### Scripts/uninstall.sh
Unloads agent, removes binary and plist, preserves logs.

### Scripts/analyze.py
Python 3 log analysis. Modes:
- `python3 Scripts/analyze.py` — full analysis
- `--anomalies` — anomalies only
- `--last 2h` — time window filter
- `--around "ISO8601"` — events ±30s around timestamp

## Build status
- Swift code compiles clean with `swiftc -O` (verified 2026-02-03)
- No dependencies beyond system frameworks (AppKit, Foundation)

## Deployment status
- **Deployed** — installed and running via launchd (2026-02-16)
- **Git repo initialized** — on `main` branch
- **Collecting data** — logs writing to `~/Library/Logs/attention-thief-catcher/`

## Next steps
1. Wait for the bug to reoccur, then `python3 Scripts/analyze.py --anomalies`
2. Use `--around` with the approximate timestamp to inspect surrounding events
