# Big Picture Assessment: attention-thief-catcher

**Date:** 2026-02-16
**Reviewer:** Claude Opus 4.6

---

## 1. Project Scope and Ambition

This project tackles a specific, real, and genuinely frustrating macOS problem: intermittent focus theft. The README clearly frames this as a diagnostic tool for a specific bug the author is experiencing. This is the right scope for the tool — it does not try to prevent focus theft (which would require deep system integration), but instead creates an audit trail to identify the culprit.

**Assessment: The approach is sound.** Passive monitoring with anomaly detection is the right first step. You cannot fix what you cannot measure. The tool occupies a sensible niche between "stare at Activity Monitor" and "install a full endpoint monitoring solution."

However, there is a philosophical tension: once the culprit is identified (STATUS.md already names `com.lwouis.alt-tab-macos` as the prime suspect), what is the tool's purpose? It becomes either (a) a permanent watchdog, (b) a general-purpose diagnostic, or (c) done. The project should clarify its intended lifecycle.

## 2. Architectural Longevity and Apple Platform Risks

### Current approach
The daemon uses `NSWorkspace` notifications and `NSRunningApplication` APIs — these are stable, public AppKit APIs that have existed since macOS 10.3+. The polling fallback (`frontmostApplication`) is similarly stable. This is the most durable way to monitor focus changes on macOS.

### TCC (Transparency, Consent, and Control) concerns
This is the biggest platform risk. Currently the tool:
- Runs as a LaunchAgent (user-level, not system-level) — good
- Uses `NSWorkspace` APIs that do not currently require TCC entitlements — good
- Calls `/bin/ps` to capture process snapshots — this works today but is increasingly suspicious from macOS's perspective
- Does NOT use Accessibility APIs — good, avoids the TCC "Accessibility" permission prompt

**Risk vector 1: Process enumeration.** Apple has been progressively restricting process enumeration. In recent macOS versions, sandboxed apps cannot see other apps' processes. This tool is not sandboxed (compiled with bare `swiftc`), so it works today. But Apple could extend these restrictions to non-sandboxed binaries. The `ps` call (line 81-93 of `attention-thief-catcher.swift`) is particularly vulnerable since it shells out.

**Risk vector 2: Notarization.** Distributing this binary to others would require notarization for it to run without Gatekeeper warnings. Currently this is a compile-from-source tool, so it sidesteps this, but it limits adoption.

**Risk vector 3: Future AppKit changes.** Apple could deprecate or gate-keep `NSWorkspace.didActivateApplicationNotification` behind an entitlement. This is unlikely in the near term but not impossible in a 3-5 year horizon.

### macOS features that could break or complicate monitoring
- **Stage Manager** (macOS Ventura+): Changes focus semantics. The current tool does not track Stage Manager stage transitions, which could explain focus changes that look anomalous but are user-initiated.
- **Multiple monitors**: The tool does not distinguish which display the activation happened on.
- **Spaces**: Virtual desktops cause focus changes that may be user-initiated. The tool does not track Space transitions.
- **Full-screen apps**: Entering/exiting full-screen triggers focus events that are not "theft."

## 3. Legal and Ethical Considerations

### MIT License
The MIT license is appropriate for a personal utility. It is simple, permissive, and widely understood. No issues here.

### Surveillance misuse potential
This is a real concern. The tool logs:
- Every app activation with timestamp, PID, executable path, bundle ID
- Periodic process snapshots (full `ps` output every 5 minutes)
- Sleep/wake cycles (effectively tracks when the user is at their computer)

This is precisely the kind of data an employer or domestic abuser could use for surveillance. The tool could be installed silently via the `install.sh` script and would run invisibly in the background.

**Mitigations:**
- It runs as a user-level LaunchAgent, so it requires the user's login credentials to install
- It writes to a well-known location (`~/Library/Logs/attention-thief-catcher/`)
- It is not particularly stealthy — `ps` would show it, `launchctl list` would show it

**Recommendation:** The README should include a disclaimer about intended use. This is not a legal obligation under MIT, but it is responsible practice for open-source tools that collect user activity data.

### Process information logging
Logging PIDs, executable paths, and `ps` output may raise data protection concerns in enterprise environments (GDPR, etc.). For a personal tool, this is a non-issue. For broader adoption, it warrants consideration.

## 4. Community and Ecosystem Positioning

### Competitive landscape
There are existing tools in this space:
- **Console.app / Unified Logging**: Apple's built-in log viewer can show window server events, but requires deep knowledge to query and is not focused on application-level focus changes.
- **Hammerspoon**: Lua-scripted macOS automation tool that can monitor focus changes. More powerful but much heavier.
- **AltTab** (ironically the suspected culprit): Window management tools often have built-in event logging.
- **dtrace / Instruments**: Powerful but require SIP modifications or developer tools.
- **Focus monitoring scripts**: Various GitHub scripts exist using AppleScript or Python, but they are typically poll-only without the anomaly detection layer.

The tool fills a genuine gap: lightweight, purpose-built, zero-dependency focus monitoring with built-in anomaly detection and analysis. Hammerspoon is the closest competitor, but attention-thief-catcher is far more focused (pun intended).

### Open-source positioning
The project has a clear README, a clean single-file architecture, MIT license, and a specific problem statement. These are positive signals. What it lacks:
- No screenshots or example output in the README
- No contributing guide
- No issue templates
- No CI/CD
- No version number or release tags
- The name "attention-thief-catcher" is descriptive but long, and has a playful tone that may not resonate with all users

## 5. Technical Debt and Code Quality

### Single-file architecture
387 lines in a single Swift file. For this project's scope, this is a feature, not a bug. The single-file approach:
- Enables trivial compilation (`swiftc -O file.swift`)
- Makes the entire codebase greppable at a glance
- Avoids build system complexity (no SwiftPM, no Xcode project)
- Is easy to audit for security review

When should this become a multi-file project? If the anomaly detection gains configurable rules, or if the logging system needs to support multiple output formats, or if the project adds a menu bar UI — then it should split. Not before.

### No tests
For a personal diagnostic tool, no tests are acceptable. The code is straightforward enough that the primary "test" is: does it compile and does it log? However, the `AnomalyDetector` logic (lines 98-178) is pure enough to unit test, and would benefit from it if the heuristics become more complex.

### No CI
Similarly acceptable for a personal tool. If this aims for broader adoption, GitHub Actions with `swiftc` compilation would be trivial to add.

### synchronizeFile() on every write (line 45)
This calls `fsync()` after every single log entry. For a daemon that logs every focus change, this could mean dozens of fsyncs per minute during active use. This is technically correct for ensuring no data loss, but may contribute to disk wear on SSDs and unnecessary I/O. The `LowPriorityIO` plist setting mitigates this somewhat.

## 6. Scalability and Performance

### Log growth
At typical use, a focus change every few seconds during active use, logs would grow roughly:
- ~200 bytes per event
- ~1 event per 3-10 seconds during active use (polling + notifications)
- ~300 KB/hour during active use
- ~2-3 MB/day for a typical workday
- ~50-75 MB/month

With 50 MB file rotation, this is manageable. However, there is **no log retention policy**. Old log files accumulate forever. After 6 months of use, the log directory could contain 1+ GB of data. The `analyze.py` script reads ALL log files (line 72), which means analysis gets slower over time.

**Recommendation:** Add a retention policy (e.g., delete files older than 30 days) and consider a `--file` flag on the analyzer to target specific log files.

### Process snapshots
The periodic `ps` snapshot every 5 minutes (line 359) captures the entire process tree. This is smart for anomaly correlation but adds bulk. Each snapshot is probably 5-10 KB of text embedded in a JSON field. Over a day, this is ~150 KB, which is modest.

However, the anomaly-triggered snapshots (lines 159-165) capture `ps` output for EVERY anomaly. During a `RAPID_FOCUS` storm (which by definition involves 6+ events in 5 seconds), this means multiple full `ps` invocations in rapid succession. This could become a performance concern during the exact moments the tool is most needed.

### Memory
The `AnomalyDetector` keeps `knownBundles` (Set<String>) and `recentLaunches` (Dictionary) in memory indefinitely. The `recentFocusTimes` array is pruned to a 5-second window. For typical use, memory is negligible. The `recentLaunches` dictionary never cleans up entries for terminated apps, but this is a minor leak at most.

## 7. The Problem Itself: Is Monitoring the Right Solution?

Focus-stealing on macOS is fundamentally a problem with how the window server handles activation requests. The root causes are:
1. Apps calling `NSApplication.activate()` or `[NSApp activateIgnoringOtherApps:YES]`
2. Apps using Accessibility APIs to manipulate focus
3. macOS itself changing focus after sleep/wake/screen unlock
4. Window managers (like AltTab) that hook into the focus system

**Monitoring identifies the culprit but cannot fix it.** Once you know that AltTab is stealing focus, your options are:
- Configure AltTab differently
- Uninstall AltTab
- File a bug report with the app developer
- On recent macOS, there is no user-level way to prevent an app from calling `activateIgnoringOtherApps:`

For this specific use case (diagnosing one known bug), monitoring is the right approach. For a broader "protect my focus" tool, you would need:
- A system extension or Accessibility-based tool that intercepts and blocks activation requests
- Integration with macOS Focus modes (Do Not Disturb)
- An "allow list" approach where only whitelisted apps can steal focus

These are all dramatically more complex and fragile than passive monitoring.

## 8. Alternative Approaches

### Menu bar app
A menu bar app would provide:
- Visual indication that monitoring is active
- Quick access to recent events and anomalies
- Settings UI for configuring thresholds
- Easier installation (drag to Applications)

Trade-offs: Much more complex code, requires SwiftUI or AppKit UI code, needs notarization for distribution, and fundamentally changes the tool from a diagnostic to a product.

**Verdict:** Not appropriate for the current scope, but a logical evolution if the tool gains users.

### System Extension / Endpoint Security
A system extension could intercept focus changes at a deeper level. macOS's Endpoint Security framework could theoretically monitor process activation.

**Verdict:** Massively over-engineered for this use case. Requires Apple Developer Program membership, kernel-level signing, and user approval in System Settings. Reserved for enterprise security tools.

### Accessibility API approach
Using the Accessibility API (`AXObserverAddNotification` for `kAXFocusedWindowChangedNotification`), you could get window-level focus changes rather than app-level.

**Verdict:** More granular but requires the user to grant Accessibility permission. The current approach correctly avoids this friction.

### AppleScript / osascript polling
A simpler approach would be a shell script that polls `tell application "System Events" to get the name of the first process whose frontmost is true`.

**Verdict:** This is what many people do first. attention-thief-catcher is a proper evolution of this approach, with event-driven monitoring instead of poll-only, structured logging, and anomaly detection.

## 9. Name and Marketing

**"attention-thief-catcher"** is:
- Descriptive and memorable
- A bit whimsical (which is fine for a personal tool)
- Too long for easy typing (32 characters)
- Could be confused with browser attention/ad-blocking tools
- The hyphenated form works well for a CLI binary name

The README is effective: it clearly states the problem, the solution, and how to use it. The "What It Monitors" and "Anomaly Detection" sections are well-structured.

**Missing from README:**
- Example output (what does a focus-theft event actually look like in the logs?)
- How to verify the daemon is running
- Troubleshooting section
- Any visual element (screenshot, terminal output example)

## 10. Maintenance Burden

For a personal tool, the maintenance burden is essentially zero:
- No dependencies to update
- System frameworks are backward-compatible
- No build system to maintain
- No users to support (unless it gains adoption)

The main maintenance trigger would be a macOS update that breaks `NSWorkspace` notification delivery or restricts `ps` output. This would manifest as: the tool appears to run but logs fewer or no events.

**Recommendation:** Add a watchdog check — if no events are logged for N minutes while the system is active, log a `NO_EVENTS_WARNING` anomaly. This would catch silent failures.

## 11. Summary of Key Recommendations

| Priority | Recommendation | Effort |
|----------|---------------|--------|
| High | Add log retention policy (delete old files) | Low |
| High | Clarify project lifecycle in README (diagnostic vs. permanent tool) | Low |
| Medium | Limit `ps` snapshots during anomaly storms (one per 5s window, not per event) | Low |
| Medium | Add a "silent failure" watchdog | Low |
| Medium | Add example output to README | Low |
| Low | Add responsible use disclaimer | Low |
| Low | Track Space/Stage Manager transitions for context | Medium |
| Low | Consider `os_log` instead of custom log writer | Medium |
| Low | Add `--file` flag to analyzer for targeted analysis | Low |
