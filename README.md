# Attention Thief Catcher

A lightweight macOS daemon that logs every app focus change to help you narrow down the culprit when your active window mysteriously loses focus.

## The Problem

Something on your Mac keeps stealing window focus. You're typing, and suddenly your keystrokes go nowhere — the frontmost app changed without you doing anything. It happens intermittently, often after sleep/wake cycles, and you can never catch what caused it.

## The Solution

Attention Thief Catcher runs silently in the background, recording every focus change with millisecond timestamps. When the bug strikes, you have a complete forensic trail to narrow down the suspect.

**How to use it:** Note the approximate time when focus was stolen, then run `python3 Scripts/analyze.py --around "2026-02-16T12:00:00"` to see every event within 30 seconds of that moment. Cross-reference with what you were doing to identify the offender.

> **Note:** This tool records *what* took focus but not *why*. It narrows suspects rather than definitively proving guilt — the anomaly heuristics have false positives (e.g. Cmd-Tab power users will trigger `RAPID_FOCUS`). Human interpretation of the logs is essential.

### What it monitors

- **App activation/deactivation** via NSWorkspace notifications
- **App launch/termination** events
- **System sleep/wake** and screen lock/unlock cycles
- **Session active/resign** events
- **Polling safety net** — checks the frontmost app every 3 seconds to catch changes that notifications miss

### Anomaly detection

The daemon automatically flags suspicious behavior:

| Anomaly | Trigger |
|---------|---------|
| `RAPID_FOCUS` | 6+ focus switches in a 5-second window |
| `NON_REGULAR_ACTIVATION` | App with accessory/prohibited activation policy gains focus |
| `UNKNOWN_BUNDLE` | A never-before-seen bundle ID gets focus |
| `JUST_LAUNCHED_ACTIVATION` | App steals focus within 2 seconds of launching |

When an anomaly is detected, a full `ps` snapshot is captured alongside it.

## Real-World Example

On 2026-02-25, this tool caught **Logitech G HUB Agent** (`com.logi.ghub.agent`) stealing focus 47 times in 4 minutes after a system wake — 43% of all focus activations in that period:

```
============================================================
  FOCUS FREQUENCY (112 activations)
============================================================
     47  Logitech G HUB Agent (com.logi.ghub.agent)
         ###############################################
     23  loginwindow (com.apple.loginwindow)
         #######################
     21  Ghostty (com.mitchellh.ghostty)
         #####################
      9  Battle.net (net.battle.app)
         #########
      7  Microsoft Word (com.microsoft.Word)
         #######
```

The rapid-switch clusters made the culprit obvious — G HUB Agent appeared in every single one of the 14 clusters:

```
  Cluster 2: 7 switches in 4.3s
  Apps: Ghostty -> Logitech G HUB Agent -> Ghostty -> Logitech G HUB Agent
        -> Ghostty -> Logitech G HUB Agent -> Ghostty
```

G HUB runs as an "accessory" app (background helper that should never take focus) but re-initializes Logitech devices on wake, activating itself with each device detection event. A [bug report has been filed](https://forums.macrumors.com/threads/logitech-g-hub-keeps-on-trying-to-get-focus-in-macos-tahoe.2469649/) with Logitech.

## Requirements

- macOS (uses AppKit/NSWorkspace)
- Swift compiler (`swiftc`, included with Xcode or Xcode Command Line Tools)
- Python 3 (for the log analyzer, included with macOS)

## Install

```bash
./Scripts/install.sh
```

This compiles the Swift binary, installs it to `~/.local/bin/`, registers a LaunchAgent, and starts the daemon. It will auto-start on every login and restart if it crashes.

Logs are written to `~/Library/Logs/attention-thief-catcher/`.

## Uninstall

```bash
./Scripts/uninstall.sh
```

Stops the daemon, removes the binary and LaunchAgent. Logs are preserved for analysis.

## Analyzing Logs

```bash
# Full analysis report
python3 Scripts/analyze.py

# Anomalies only
python3 Scripts/analyze.py --anomalies

# Last 2 hours
python3 Scripts/analyze.py --last 2h

# Events around a specific timestamp (±30s)
python3 Scripts/analyze.py --around "2026-02-16T12:00:00"
```

The analyzer generates:
- **Anomaly report** — all flagged events grouped by type
- **Focus frequency histogram** — which apps received focus most often
- **Rapid switch clusters** — 5-second windows with 4+ focus changes
- **System event timeline** — sleep/wake/session events
- **Poll-detected changes** — focus changes missed by notifications (caught by polling)
- **Wake correlation** — which apps steal focus after system wake

## How It Works

Single-file Swift daemon (`Sources/attention-thief-catcher.swift`) running three subsystems on one RunLoop:

1. **Event Monitor** — subscribes to NSWorkspace notifications for focus, lifecycle, and power events
2. **Polling Safety Net** — checks `frontmostApplication` every 3 seconds as a fallback
3. **Anomaly Detector** — applies heuristics to flag suspicious focus changes

Logs are NDJSON (one JSON object per line), fsynced after every write, with 50 MB file rotation and periodic process snapshots every 5 minutes.

## Log Format

Each line is a JSON object with at minimum an `event` and `timestamp` field:

```json
{"event":"APP_ACTIVATED","timestamp":"2026-02-16T10:52:15.123Z","name":"Safari","bundleID":"com.apple.Safari","pid":647,"path":"/System/...","activationPolicy":"regular"}
```

Anomaly events include additional fields:

```json
{"event":"ANOMALY","timestamp":"...","anomalyType":"RAPID_FOCUS","detail":"6 focus switches in 5s window","triggerApp":{...},"processSnapshot":"PID PPID %CPU %MEM COMM\n..."}
```

## Privacy

This tool collects the following data and stores it locally on your machine:

- **App names, bundle IDs, executable paths, and PIDs** for every focus change
- **Process snapshots** (your user's running processes) on anomalies and every 5 minutes
- **System events** (sleep/wake, screen lock/unlock, session changes)

All data is stored in `~/Library/Logs/attention-thief-catcher/` with restrictive permissions (directory: 0700, files: 0600). Log files older than 30 days are automatically purged. No data is transmitted anywhere.

To delete all collected data: `rm -rf ~/Library/Logs/attention-thief-catcher/`

## Known Limitations

- **Cannot determine causality** — the tool records that app X took focus, but not whether it was user-initiated (Cmd-Tab, click) or stolen programmatically
- **Spaces / Stage Manager / multi-monitor** — switching between Spaces or Stage Manager groups triggers focus events that may appear as false-positive anomalies
- **Anomaly heuristics have false positives** — `RAPID_FOCUS` fires on Cmd-Tab power users, `JUST_LAUNCHED_ACTIVATION` fires on normal app launches from Spotlight/Dock

## Responsible Use

This tool is designed for diagnosing focus-theft issues on your own machine. Deploying monitoring software on machines you do not own or without user consent may violate applicable laws.

## Design Reviews

The [`debate/`](debate/INDEX.md) directory contains structured adversarial reviews (security, usability, big picture) that were conducted before the initial hardening pass. Each review includes the full debate chain and a summary of findings. See [`debate/INDEX.md`](debate/INDEX.md) for details.

## Known Focus Stealers

Apps reported to steal focus on macOS:

| App | Bundle ID | Notes |
|-----|-----------|-------|
| **Logitech G HUB Agent** | `com.logi.ghub.agent` | Re-initializes devices on wake, activates itself repeatedly. [Confirmed by this tool.](#real-world-example) |
| **HP Alerts** | — | Background helper that grabs focus to show printer status. |
| **Carrot Weather** | — | Reported to steal focus during notification updates. |
| **SecurityAgent** | `com.apple.SecurityAgent` | macOS system process, reported to grab focus after macOS 26.1. |

If you catch another focus stealer, please [open an issue](../../issues) so we can add it to this list.

## Community

Many macOS users experience focus-stealing bugs but have no way to identify the culprit. These are the discussions where people are looking for help:

- [Logitech G Hub keeps on trying to get focus in macOS Tahoe](https://forums.macrumors.com/threads/logitech-g-hub-keeps-on-trying-to-get-focus-in-macos-tahoe.2469649/) — MacRumors
- [Active window loses focus](https://forums.macrumors.com/threads/active-window-loses-focus.2321723/) — MacRumors
- [Something is stealing application focus](https://discussions.apple.com/thread/255541717) — Apple Community
- [macOS process stealing window focus](https://gist.github.com/holgr/59f8df7f81aa2b74d67e0ab95e2fd28a) — GitHub Gist, someone building a similar tool
- [Mac apps stealing window/keyboard/mouse focus](https://vi-control.net/community/threads/mac-apps-stealing-window-keyboard-mouse-focus-how-to-stop-it-upgrade-to-sequoia.158515/) — VI-Control
- [Issues with Input Focus after macOS 26.1](https://discussions.apple.com/thread/256192312) — Apple Community

## License

[MIT](LICENSE)
