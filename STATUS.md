# Attention Thief Catcher — Project Status

**Last updated:** 2026-02-25

## Investigation resolved

**Focus thief identified:** Logitech G HUB Agent (`com.logi.ghub.agent`)

On 2026-02-25, the daemon captured G HUB Agent stealing focus 47 times in 4 minutes after a system wake — 43% of all activations. 14 rapid-switch clusters, G HUB Agent present in every one. The agent runs with `activationPolicy: accessory` (background helper that should never take focus) but re-initializes Logitech devices on wake and activates itself with each device detection event. G HUB version 2025.9.807502, peripheral: G PRO X SUPERLIGHT 2.

A bug report has been filed with Logitech via support.logi.com.

**Original suspect:** AltTab (`com.lwouis.alt-tab-macos`) — cleared.

## What this project does
Background daemon that logs every macOS focus change to diagnose intermittent
bugs where the active window loses focus.

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
1. Share the tool with the community — many people are asking "how do I find what's stealing focus?" with no good answer
2. Keep the daemon running to catch other potential focus stealers
