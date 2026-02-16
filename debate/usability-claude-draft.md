# Usability Assessment: attention-thief-catcher

**Assessor:** Claude Opus 4.6
**Date:** 2026-02-16
**Scope:** End-to-end usability for an open source user discovering, installing, using, and contributing to this project.

---

## 1. First Impressions for a New GitHub User

**Positive:** The repository name is descriptive and memorable. A developer landing on this repo from a search query like "macOS app stealing focus" would immediately understand the purpose. The README opens with "The Problem" section that is relatable -- nearly every macOS power user has experienced mysterious focus theft.

**Concern:** There is no visual badge bar (build status, macOS version compatibility, license badge, Swift version). Modern open source projects use these to signal maturity and trustworthiness at a glance. A user evaluating whether to trust a daemon running on their machine would benefit from visible signals of code quality.

**Concern:** No screenshots, GIF, or sample output. The README describes what the analyzer produces but doesn't show it. For a diagnostic tool, showing sample output is critical -- users need to understand what they'll get before investing time in installation.

## 2. README Clarity and Completeness

**Strengths:**
- Clear problem/solution framing
- Concise anomaly detection table
- Good explanation of the three-subsystem architecture
- Log format examples with actual JSON
- Clean separation of Install / Uninstall / Analyze sections

**Gaps:**
- **No macOS version requirement specified.** The README says "macOS" but doesn't specify minimum version. NSWorkspace APIs used (e.g., `screensDidSleepNotification`) have been available since macOS 10.6, but the Swift concurrency model and compilation requirements may impose higher minimums. A user on macOS 11 vs 14 would want to know.
- **No Accessibility permission note.** While this daemon does not use the Accessibility API directly (it uses NSWorkspace notifications, which don't require special permissions), this is not stated. Users familiar with macOS security may hesitate, wondering whether they need to grant Accessibility or Full Disk Access permissions. A brief "No special permissions required" note would reduce friction.
- **No mention of resource consumption.** The README doesn't tell users what to expect in terms of CPU, memory, or disk usage. The daemon is nicely configured (Nice=10, LowPriorityIO=true) but this isn't communicated to the user.
- **No troubleshooting section.** What should a user do if the daemon doesn't start? If logs aren't appearing? If `swiftc` is not found?
- **No FAQ.** Common questions like "Does this work on Apple Silicon?" or "Will this slow down my Mac?" are unaddressed.

## 3. Installation Experience

### Compilation from Source

**Positive:** The install script is straightforward -- 46 lines of well-structured bash. It compiles, installs, registers, and verifies in one step.

**Concern: No prerequisite check.** The script runs `swiftc` on line 16 without first checking if it's available. On a stock macOS without Xcode or Command Line Tools, this fails with a cryptic error. Worse, macOS may trigger a system dialog offering to install Command Line Tools, which is confusing in the context of a running script.

```bash
# install.sh:16
swiftc -O -o "$BINARY_PATH" "$SWIFT_SRC" -framework AppKit
```

If `swiftc` is not found, the `set -euo pipefail` will cause an immediate exit, but the error message is whatever the shell produces ("command not found"), not a helpful explanation.

**Concern: No Homebrew option.** The vast majority of macOS developer tools can be installed via `brew install`. Requiring `git clone` + `./Scripts/install.sh` is a higher barrier. Even a Homebrew formula in the repo (without tap submission) would signal intent and familiarity with the ecosystem.

**Concern: Binary installed to `~/.local/bin/`.** This is a reasonable convention (XDG-adjacent), but it's not standard on macOS. Most macOS tools install to `/usr/local/bin/` or are managed by Homebrew. If `~/.local/bin` is not in the user's `$PATH`, the binary is "hidden" (though it doesn't need to be in PATH since launchd uses the absolute path).

### LaunchAgent Registration

**Positive:** The plist uses modern `launchctl bootstrap/bootout` commands rather than the deprecated `load/unload`. The `sed` expansion of `~` to the actual home directory (install.sh:28) is a necessary workaround since launchd doesn't expand tilde.

**Positive:** `KeepAlive` with `SuccessfulExit = false` means the daemon restarts on crashes but not on clean exit. `LimitLoadToSessionType = Aqua` correctly limits it to GUI sessions.

**Concern: No verification of compilation success before proceeding.** While `set -e` catches failures, the script doesn't provide a clear error message if compilation fails (e.g., due to missing SDK or Swift version mismatch). The user sees a swiftc error dump and the script exits.

## 4. Uninstallation Experience

**Positive:** Clean, well-structured uninstall script. It checks for existence before removing, handles the case where the agent isn't loaded, and preserves logs by default with a clear message about how to remove them.

**Minor concern:** The uninstall script doesn't offer a `--purge` flag to also remove logs. Users who want a complete clean removal need two steps.

## 5. Day-to-Day Usage

**Positive:** This is genuinely "set and forget" once installed. The LaunchAgent handles auto-start and crash recovery. The daemon has no UI, no menu bar icon, no notifications -- it just silently logs.

**Concern: No way to check daemon health.** A user who installed it weeks ago has no easy way to verify it's still running and logging correctly. They would need to know to run `launchctl print gui/$(id -u)/com.magnusgille.attention-thief-catcher.plist` or check for recent files in the log directory. A simple `./Scripts/status.sh` would be a significant quality-of-life improvement.

**Concern: Log rotation is file-count-unbounded.** The daemon rotates at 50 MB per file (attention-thief-catcher.swift:11) but never deletes old files. Over weeks or months of use, logs accumulate without bound. There's no retention policy, no maximum total size, and no cron job or built-in cleanup. For a "set and forget" tool, this is a meaningful gap -- users may discover gigabytes of logs months later.

**Concern: No user-facing notifications.** When an anomaly is detected, it's silently logged. There's no macOS notification, no menu bar indicator, nothing. Users must actively run the analyzer to discover that anomalies were found. For many users, the entire point of the tool is to be alerted when focus theft happens, not to do post-hoc forensics.

## 6. Log Analysis Experience

### Python Script UX

**Positive:** The analyzer is well-designed with multiple modes (full, anomalies-only, time-filtered, around-timestamp). The `--around` flag is particularly useful for investigating specific incidents. The output is structured with clear headers and visual histograms.

**Concern: Output is terminal-only.** There's no option to export to JSON, CSV, or HTML. Users who want to share findings, graph trends, or integrate with other tools must parse the text output themselves.

**Concern: No interactive mode.** For a diagnostic tool, being able to drill down interactively (e.g., "show me more detail about this anomaly" or "what happened 10 seconds before this event") would be valuable.

**Concern: The `--last` flag uses naive datetime.** In analyze.py:340, `datetime.now()` returns a naive (timezone-unaware) datetime, but the log timestamps parsed in `parse_timestamp()` (lines 25-44) strip timezone information. This works only if the system timezone hasn't changed between logging and analysis. For users who travel or change timezones, this could produce confusing results.

**Concern: No guidance on interpreting results.** The analyzer shows data but doesn't explain what to do with it. A new user seeing "UNKNOWN_BUNDLE: com.foo.bar" doesn't know whether that's normal or concerning. Brief inline help or a companion interpretation guide would improve usability.

## 7. Error Handling and User Feedback

**Concern: Silent failures in the daemon.** The `LogWriter.write()` method (attention-thief-catcher.swift:38-53) silently drops events if `fileHandle` is nil. The only error logging is for JSON serialization failures (line 51), which are unlikely. If the log directory becomes unwritable (disk full, permissions changed), the daemon continues running but silently stops logging -- the worst possible failure mode for a monitoring tool.

**Concern: The daemon has no health check mechanism.** No heartbeat events, no periodic "I'm still alive" log entries beyond the 5-minute process snapshots. If a user checks logs and sees the last entry was hours ago, they can't distinguish "nothing happened" from "daemon died silently."

**Positive:** The `processSnapshot()` function (line 79-94) has reasonable error handling, returning an error string rather than crashing.

## 8. Cross-Version macOS Compatibility

**Concern: No minimum macOS version specified anywhere** -- not in the README, not in the Swift source (no `@available` annotations), not in build flags. The code uses `NSWorkspace` APIs that are broadly available, but compilation with `swiftc` depends on the installed SDK version. A user on an older macOS might get unexpected compiler errors.

**Concern: No Apple Silicon vs Intel mention.** While `swiftc` on Apple Silicon produces arm64 binaries by default, this is worth mentioning for users who might want to verify architecture.

**Concern: The plist uses `LimitLoadToSessionType: Aqua`**, which is correct for GUI sessions but should be documented. Users running headless macOS servers would find the daemon doesn't start and wouldn't know why.

## 9. Contribution Experience

**Single-file architecture:**
- **Pro:** Very low barrier to understanding the entire codebase. A contributor can read one 387-line file and understand everything.
- **Con:** No separation of concerns means changes to logging affect anomaly detection in the same file. No protocol/interface boundaries means the code is tightly coupled.
- **Con:** No Package.swift, no Xcode project, no SPM support. Contributors can't use Xcode's IDE features (autocomplete, debugging, breakpoints) without creating their own project wrapper.

**No tests:** Zero test coverage. No test target, no test framework, no examples of how to test. For contributors, this means:
- No confidence that their changes don't break existing behavior
- No examples of expected behavior to learn from
- No CI to catch regressions

**No CI/CD:** No GitHub Actions, no automated builds, no linting. Contributors submit PRs into a void with no automated feedback.

**No CONTRIBUTING.md:** No guidance on code style, PR process, or development setup.

**No issue templates or PR templates:** First-time contributors get no structure.

## 10. Discoverability of Features

**Concern: The `--around` flag in analyze.py is a powerful forensic tool but is only documented in the script's docstring (line 9) and the README.** A user who only reads the README's quick examples might miss its utility for investigating specific incidents.

**Concern: The polling safety net (3-second fallback check) is a clever reliability mechanism but is barely explained.** The README mentions it in one bullet point. Users might not understand why some events show `POLL_FOCUS_CHANGE` vs `APP_ACTIVATED`.

## 11. Missing Features Open Source Users Would Expect

1. **Homebrew installation** -- the de facto standard for macOS CLI tools
2. **`--version` flag** -- no versioning at all (no tags, no version string)
3. **Configuration file** -- no way to customize thresholds (RAPID_FOCUS count, poll interval, snapshot interval, log rotation size)
4. **macOS notifications** for anomalies -- at minimum, a `--notify` flag
5. **Log cleanup/retention** -- automatic deletion of old logs
6. **Status command** -- `attention-thief-catcher --status` or a status script
7. **Export formats** -- JSON/CSV output from the analyzer
8. **Allowlist/blocklist** -- ability to ignore known-benign apps (e.g., Spotlight, system apps)
9. **Structured release process** -- GitHub releases, changelogs, semantic versioning

## 12. Documentation Gaps

1. No architecture diagram or visual explanation
2. No "Interpreting Results" guide
3. No troubleshooting section
4. No security/privacy discussion (what data is collected, where it's stored, who can access it)
5. No performance characteristics documentation
6. No explanation of when/why to use this tool vs alternatives (if any exist)
7. No development setup guide for contributors

---

## Overall Assessment

**Usability Score: 6/10**

The project solves a genuine, well-articulated problem with a clean, minimal implementation. Installation and uninstallation are single-command operations. The daemon is truly hands-off once running. The log analyzer provides meaningful forensic capability.

However, the tool falls short of modern open source expectations in several key areas: no Homebrew support, no health monitoring, no user notifications for detected anomalies, unbounded log growth, no tests or CI, no versioning, and no configuration options. The "set and forget" promise is partially undermined by the need to actively check logs and the lack of log retention management.

For its target audience (a macOS developer investigating their own focus-theft mystery), it's functional and useful. For broader open source adoption, significant polish is needed.
