# Big Picture Critique: attention-thief-catcher

**Date:** 2026-02-16
**Reviewer:** Codex (adversarial strategic reviewer)

---

## Strengths Worth Acknowledging

Before tearing into this, credit where it is due:

1. **The problem is real and underserved.** Focus theft on macOS is a known pain point with no first-party diagnostic tool. Apple's own Console.app and `log stream` can surface WindowServer events but require expert-level query construction. This tool correctly identifies a gap.

2. **The architecture is honest.** A single-file daemon with no dependencies is the right call for a diagnostic tool. No SwiftPM, no Xcode project, no CocoaPods — just `swiftc` and go. The draft correctly identifies this as a feature.

3. **The dual-detection approach is clever.** NSWorkspace notifications plus 3-second polling (Sources/attention-thief-catcher.swift:312-345) provides defense-in-depth against missed notifications. This is better than most hobby scripts that rely on one or the other.

4. **The anomaly detector adds real value.** RAPID_FOCUS, JUST_LAUNCHED_ACTIVATION, and NON_REGULAR_ACTIVATION (lines 119-167) are well-chosen heuristics that go beyond simple logging.

Now the problems.

---

## 1. The Fundamental Approach: Monitoring vs. Action

The draft says "passive monitoring with anomaly detection is the right first step" and I agree — for the diagnostic phase. But the draft fails to reckon with a harder question: **this tool exists because macOS does not expose focus-change reasons.**

When `didActivateApplicationNotification` fires, you get WHICH app took focus, but never WHY. Was it `activateIgnoringOtherApps:`? Was it an Accessibility API call? Was it the window server responding to a mouse click in another window? The notification does not tell you. The tool's logs show a sequence of activations but cannot distinguish user-initiated focus changes from stolen ones.

This is a critical blindness. The draft's anomaly heuristics are proxies — RAPID_FOCUS detects thrashing, JUST_LAUNCHED_ACTIVATION detects aggressive new apps — but they have significant false positive rates. Consider: a user Cmd-Tabbing quickly between apps triggers RAPID_FOCUS. A user opening an app from Spotlight triggers JUST_LAUNCHED_ACTIVATION. The tool cannot tell the difference between the user changing focus and an app stealing it.

**The draft should have been more honest about this fundamental limitation.** It is not just that "monitoring identifies the culprit but cannot fix it" — monitoring cannot even definitively identify the culprit. It can only narrow the suspects.

## 2. Apple Platform Risks: The Draft Understates the Danger

### 2a. Process enumeration is not just "at risk" — it is actively dying

The draft correctly identifies `/bin/ps` (line 81) as a risk but treats this as speculative future concern. Let me be more direct: Apple has been restricting process visibility since macOS Mojave (2018). The trajectory:

- macOS 10.14+: Sandboxed apps lost `sysctl` KERN_PROC access to other processes
- macOS 12+: `proc_info` calls restricted for sandboxed apps
- macOS 13+: `EndpointSecurity` framework required for comprehensive process monitoring

The tool is NOT sandboxed, so it currently escapes these restrictions. But Apple's direction is clear: non-sandboxed, non-notarized binaries running as LaunchAgents are the exact profile Apple is trying to eliminate from the platform. The tool compiles from source and installs to `~/.local/bin` — this pattern bypasses Gatekeeper entirely, which Apple views as a security problem, not a feature.

**Concrete risk:** A future macOS update could require LaunchAgents to be signed with a Developer ID, or could restrict `NSWorkspace` notification delivery to signed binaries. Apple has precedent for this kind of restriction with Background Items management in macOS Ventura.

### 2b. The plist's `KeepAlive` pattern is fragile

`LaunchAgents/com.magnusgille.attention-thief-catcher.plist` uses `KeepAlive > SuccessfulExit: false` (lines 14-18). This means launchd will restart the daemon if it crashes (non-zero exit). However:

- If the binary is removed or path changes, launchd will repeatedly try to launch it and fail, consuming resources
- There is no `ThrottleInterval` set, so launchd uses its default (10 seconds) but could still cause rapid restart loops
- There is no `ExitTimeOut` — if the daemon hangs instead of crashing, launchd will not kill it

### 2c. Background App Refresh and App Nap

The draft does not mention **App Nap**, which macOS applies to background processes with low priority. The plist sets `Nice: 10` and `ProcessType: Background` — both of which signal to macOS that this process is deprioritizable. macOS could throttle the daemon's timers during App Nap, causing the 3-second poll to fire at much lower frequency. This directly undermines the "safety net" role of polling.

The tool should set `ProcessType: Interactive` or at minimum `Adaptive` to prevent App Nap from degrading monitoring accuracy.

## 3. Surveillance Potential: The Draft Pulls Its Punches

The draft's treatment of surveillance risk is inadequate. It lists mitigations that are effectively meaningless:

- "Requires login credentials to install" — in enterprise contexts, IT deploys LaunchAgents to all machines via MDM. No user consent needed.
- "Writes to a well-known location" — change one string in `LogWriter.init()` (line 15) and logs go to any directory.
- "Not particularly stealthy" — rename the binary, change the plist label, and it blends in with other LaunchAgents.

Here is what the tool actually logs:
- Every application the user opens, with exact timestamps (lines 224-249)
- When the user puts the computer to sleep and wakes it (lines 251-281) — this is presence detection
- Every 5 minutes, a full `ps` snapshot (lines 358-376) — this reveals what the user is running at all times
- PIDs, executable paths, and bundle IDs — this fingerprints the user's software stack

**This is a behavioral monitoring toolkit.** The fact that it was built for a benign purpose does not change what it is capable of. And under MIT license, anyone can fork it, modify it, and deploy it without attribution.

The README should include:
1. An explicit statement that this tool is designed for self-use debugging
2. A note that deploying it on someone else's machine without their knowledge may violate local laws
3. Consideration of whether to add a visual indicator (menu bar icon, notification) that monitoring is active

## 4. Architecture: Single Daemon is Right, But the Log Format is Wrong

### 4a. NDJSON is defensible but suboptimal

The draft barely evaluates the NDJSON choice. Here is the real trade-off:

**NDJSON advantages:** Human-readable, append-only, no corruption risk from crashes (each line is independent), easy to process with `jq`, Python, etc.

**NDJSON disadvantages:**
- No indexing: `analyze.py` reads ALL events into memory (line 65-100). With months of logs, this means loading hundreds of megabytes into a Python list.
- No schema: Fields vary by event type. The analyzer uses `.get()` with defaults everywhere, which is fragile.
- No compression: JSON is verbose. The process snapshots (multi-KB text blobs) embedded as JSON string values are particularly wasteful.
- Timezone handling is fragile: `parse_timestamp()` in analyze.py (lines 25-44) has multiple fallback formats and strips timezone info, which means log events from different timezones could sort incorrectly.

**Better alternative for this use case: SQLite.** A single `events.db` file with a `CREATE TABLE events (id INTEGER PRIMARY KEY, timestamp TEXT, event TEXT, data JSON)` would provide:
- Indexed queries by time and event type
- Built-in retention (`DELETE FROM events WHERE timestamp < ...`)
- No full-file-scan for analysis
- Atomic writes (no partial lines from crashes)
- Automatic `VACUUM` for space reclamation

The draft mentions SQLite in passing ("More complex to write to") — but it is not more complex. Swift's `sqlite3` C library is available without any dependencies. The write code would be ~30 lines.

### 4b. The analyzer is a separate tool in a different language

The daemon is Swift, the analyzer is Python. This is fine for a personal tool but creates a bifurcated maintenance burden. A user must have both `swiftc` and `python3` installed. If the log format changes in the Swift code, the Python analyzer must be updated separately, with no compile-time validation that they agree on field names.

## 5. Competitive Landscape: More Crowded Than the Draft Suggests

The draft's competitive analysis is thin. Here is what it misses:

1. **Hammerspoon** is not just "heavier" — it is a fundamentally different approach. Hammerspoon's `hs.application.watcher` provides the same `didActivateApplicationNotification` events as this tool, AND it can take action (show alerts, block activation, log to file). A Hammerspoon script equivalent to this tool's core monitoring would be ~20 lines of Lua.

2. **OverSight by Objective-See** monitors process activation specifically for security purposes. While focused on camera/microphone access, its architecture (user-level daemon + menu bar UI + notification system) is exactly what this project would evolve into.

3. **Lingon** is a commercial tool for managing LaunchAgents that includes process monitoring. Not a direct competitor, but shows there is market awareness of the problem space.

4. **Built-in macOS tools**: `log stream --predicate 'subsystem == "com.apple.windowserver"'` with appropriate predicates can show focus change events from WindowServer. This is harder to use but requires zero installation.

The tool's differentiation is its anomaly detection heuristics. Everything else (logging focus changes, recording app info, process snapshots) is achievable with existing tools. If the project wants open-source success, it should lean hard into the anomaly detection as its unique value proposition.

## 6. Edge Cases the Tool Cannot Handle

### 6a. Spaces and Mission Control
When the user switches Spaces (virtual desktops), the frontmost application may change. `NSWorkspace.didActivateApplicationNotification` fires for this change, but there is no way to determine that it was triggered by a Space switch vs. focus theft. The tool logs these as identical events.

### 6b. Stage Manager
Stage Manager (macOS Ventura+) introduces a new focus paradigm where "stages" of apps are grouped. Activating a stage changes the frontmost app. This will generate RAPID_FOCUS anomalies for perfectly normal user behavior.

### 6c. Multiple displays
A user clicking on a window on a secondary display triggers an activation event. The tool cannot distinguish "user clicked on another screen" from "app stole focus." For users with 2+ monitors, the tool's anomaly detection will have a high false-positive rate.

### 6d. Full-screen transitions
Entering/exiting full-screen mode in an app can trigger deactivation and reactivation events. Exiting full-screen Safari to return to a Finder window triggers `APP_ACTIVATED` for Finder — which is user-initiated but looks identical to focus theft.

### 6e. Dialogs and sheets
Modal dialogs from background apps (e.g., "App X wants to make changes") steal focus by design. The tool would flag these as anomalies, but they are expected macOS behavior.

**The draft acknowledges some of these (Spaces, Stage Manager, full-screen) but treats them as "nice to have" context. They are actually fundamental limitations of the approach.** The tool cannot distinguish user-initiated focus changes from involuntary ones. This is not a minor caveat — it is the tool's central weakness.

## 7. Open Source Viability

The project is NOT positioned for open-source success in its current form, for these reasons:

1. **No version number or release system** — users cannot pin to a known-good state
2. **No issue templates or contributing guide** — discourages community participation
3. **No CI** — contributors cannot verify their changes compile
4. **Platform-specific** — macOS-only tools have a small audience by definition
5. **The problem is intermittent** — most potential users will never encounter focus theft severe enough to justify installing a daemon
6. **No example output** — the README describes the tool well but does not SHOW it working

The realistic trajectory: the tool collects 5-20 GitHub stars from people who stumble on it via search, identifies the author's specific bug, and then enters indefinite maintenance mode. This is fine. Not every project needs to be a community effort.

## 8. Maintenance Burden: Honestly Low, But Not Zero

The draft says "essentially zero" maintenance for a personal tool. This understates the cost of:
- **macOS version testing**: Each annual macOS release could break `NSWorkspace` behavior, `ps` output format, or launchd semantics. Verifying the tool still works after each upgrade takes time.
- **Log directory management**: Without retention, the user must manually clean up logs.
- **Analyzer bit-rot**: Python is a moving target. The analyzer uses no dependencies today, but Python version changes (e.g., datetime handling changes between 3.10 and 3.12) could cause subtle breakage.

## 9. The Most Important Question the Draft Does Not Ask

**Should this project exist beyond its initial diagnostic purpose?**

The STATUS.md says the prime suspect is AltTab. The tool is deployed and collecting data. The realistic outcome is:
1. Confirm AltTab is the culprit
2. Adjust AltTab's settings or uninstall it
3. Run the tool for another week to verify the fix
4. Uninstall the tool

Everything else — open-source positioning, community features, CI, menu bar UI — is premature optimization for a problem that may already be solved. The draft hints at this ("project lifecycle") but does not confront it directly.

**My recommendation:** Solve the immediate bug. Write a blog post about the debugging process. Archive the repo. If others express interest, then invest in the open-source infrastructure. Until then, the tool is a diagnostic instrument, not a product, and should be treated as such.

---

## Summary of Critiques

| # | Issue | Severity | Draft Coverage |
|---|-------|----------|----------------|
| 1 | Cannot distinguish user-initiated vs. stolen focus changes | High | Acknowledged but understated |
| 2 | Process enumeration dying on macOS | High | Mentioned but treated as speculative |
| 3 | Surveillance potential inadequately addressed | High | Mentioned but mitigations are weak |
| 4 | App Nap could degrade poll frequency | Medium | Not mentioned |
| 5 | NDJSON inferior to SQLite for this use case | Medium | Barely evaluated |
| 6 | Edge cases (Spaces, Stage Manager, multi-monitor) are fundamental limitations | Medium | Listed but dismissed as "nice to have" |
| 7 | No log retention policy creates unbounded growth | Medium | Correctly identified |
| 8 | Project lifecycle question dodged | Medium | Hinted at but not answered |
| 9 | Competitive landscape understated | Low | Partially covered |
| 10 | Analyzer in separate language with no schema contract | Low | Not mentioned |
