# Roadmap Proposals — Claude's Draft Assessment

**Snapshot:** commit `8de9d56` (HEAD of main, 2026-02-16)
**Scope:** Five proposals for the next evolution of attention-thief-catcher

---

## Proposal 1: Replace `/bin/ps` with `NSRunningApplication` enumeration

### Current state
`processSnapshot()` at `Sources/attention-thief-catcher.swift:114-129` shells out to `/bin/ps -U $USER -eo pid,ppid,%cpu,%mem,comm`, capturing a text blob stored as a string field in NDJSON logs.

### Assessment: ACCEPT with modification

**Arguments for:**
- Eliminates Process() shell-out — removes an attack surface (even though args are static, the pattern is fragile)
- Produces structured JSON arrays instead of raw text — the analyzer can parse them without regex
- Native API, no subprocess overhead
- Aligns with the security hardening direction from the prior debate

**Arguments against:**
- `NSRunningApplication` does not expose `%CPU`, `%MEM`, or `ppid`. These metrics could theoretically help identify a runaway process causing focus theft.
- `NSRunningApplication` only shows apps (things with bundle IDs or at least activation policies), not background daemons/helpers. A rogue XPC service or helper tool causing focus theft wouldn't appear.

**My position:** Replace `/bin/ps` as the *default* snapshot mechanism but preserve `%CPU/%MEM` data through a hybrid approach. Specifically:
1. Primary snapshot: `NSWorkspace.shared.runningApplications` → structured JSON array
2. On anomaly only: also capture `/bin/ps` output as a supplementary field (anomalies already trigger snapshots, and they're rare enough that the subprocess cost doesn't matter)

This gives structured data for normal analysis while preserving diagnostic depth for anomalies.

**Complexity:** Low. ~30 lines of Swift changed. No new dependencies.

**Priority:** HIGH — it's a clean improvement with no downside.

---

## Proposal 2: Add `--follow` live-tail mode to analyzer

### Current state
The analyzer (`Scripts/analyze.py`) only processes historical data. Users must remember the approximate timestamp and run the analyzer after the fact.

### Assessment: ACCEPT

**Arguments for:**
- The current workflow (notice theft → remember time → run analyzer later) has friction. Real-time visibility eliminates the "remember the time" step entirely — you just keep a terminal open.
- Particularly useful during debugging sessions when you're actively trying to reproduce focus theft.
- Colorized output with immediate anomaly flagging would make anomalies impossible to miss.

**Arguments against:**
- Adds complexity to the analyzer. The current code is clean and stateless.
- Python file-watching options: `watchdog` adds a dependency, polling is wasteful, `kqueue` via `select.kqueue` is macOS-only (fine for this project but platform-specific).
- The daemon could instead log to stdout in a verbose mode, letting users `tail -f` the NDJSON directly. But raw NDJSON is much harder to read than formatted output.

**My position:** Implement with simple file polling (no dependencies). The approach:
1. `open()` the latest log file, `seek()` to end
2. Poll every 0.5s for new lines (cheaper than you'd think — it's a single `read()` call)
3. When a new log file appears (rotation), switch to it
4. Format and colorize output, flag anomalies inline

This keeps the zero-dependency promise. `kqueue` would be nicer but `select.kqueue` is less portable to future platforms and the polling overhead is negligible for a diagnostic tool.

**Complexity:** Medium. ~80-100 lines of new Python code.

**Priority:** HIGH — directly improves the core user workflow.

---

## Proposal 3: Add `Package.swift` for IDE support

### Current state
No `Package.swift` exists. The build uses `swiftc -O -o ... -framework AppKit` in `install.sh`.

### Assessment: ACCEPT with caveats

**Arguments for:**
- Without Package.swift, SourceKit-LSP can't index the project. No autocomplete, no jump-to-definition, no inline error checking. Anyone editing the Swift code is flying blind.
- A minimal Package.swift with zero dependencies is trivial to add and maintain.

**Arguments against:**
- Creates two build paths: `swiftc` (install.sh) and `swift build` (Package.swift). If someone adds SPM dependencies in Package.swift, install.sh won't know about them.
- Could confuse contributors into thinking `swift build` is the canonical build command.

**My position:** Add a minimal Package.swift but:
1. Include a comment at the top: `// This Package.swift exists for IDE support (SourceKit-LSP). The canonical build is Scripts/install.sh.`
2. Do NOT migrate the build to SPM — the single `swiftc` command is simpler and the project has no Swift dependencies.
3. Keep the Package.swift as minimal as possible: just the executable target pointing to `Sources/`.

**Complexity:** Very low. One new file, ~15 lines.

**Priority:** MEDIUM — only benefits developers editing the Swift code, not end users. But the cost is near-zero.

---

## Proposal 4: Add `Scripts/status.sh` health-check script

### Current state
Verifying daemon health requires manual `launchctl print` and log file inspection. No automated health check exists.

### Assessment: ACCEPT

**Arguments for:**
- "Is it running?" is the most common question after installation. Currently requires arcane launchctl knowledge.
- Log freshness checking catches silent failures — if the daemon crashed and launchd didn't restart it, or if it's alive but stuck, stale logs reveal the problem.
- Disk usage monitoring prevents surprise "disk full" scenarios from long-running daemons.

**Arguments against:**
- Could be a subcommand of the analyzer (`analyze.py --status`) instead of a separate script. This would keep the number of user-facing scripts small.
- Shell script vs Python: shell is natural for launchctl/system checks, but the log parsing (freshness, restart detection) would duplicate Python logic in the analyzer.

**My position:** Implement as `analyze.py --status` rather than a separate shell script. Reasons:
1. Single entry point for all analysis — users learn one tool
2. The log freshness check and restart detection require parsing NDJSON, which the analyzer already does
3. The launchctl check can be done via `subprocess.run()` in Python — it's one command
4. Shell-only checks (is it loaded? PID? uptime?) can be the first thing `--status` prints before loading any logs

**Freshness threshold:** A log entry more than 10 minutes old is "stale" (2x the 5-minute snapshot interval). This allows for one missed snapshot before alarming.

**Complexity:** Medium. ~60-80 lines of Python.

**Priority:** HIGH — directly addresses a real usability gap identified in the prior usability debate.

---

## Proposal 5: Add Accessibility API window-level tracking

### Current state
Monitoring is app-level only via NSWorkspace. Cannot distinguish "which window" or "was it a dialog."

### Assessment: DEFER

**Arguments for:**
- Would solve the specific case where focus theft happens *within* an app (e.g., a dialog pops up in the already-frontmost app, stealing keyboard focus from your document window).
- Window titles could help identify the specific trigger ("Software Update" dialog, "Allow notifications?" prompt, etc.).

**Arguments against (and these are strong):**
1. **Onboarding friction is severe.** Accessibility permission requires navigating System Settings > Privacy & Security > Accessibility, finding the app in the list, toggling it on, and potentially restarting the daemon. This is a multi-step manual process with no programmatic shortcut. For a diagnostic tool that should "just work," this is a significant barrier.
2. **Privacy implications.** Window titles contain document names, URLs, email subjects, message previews. The current tool explicitly stores only app names and bundle IDs — adding window titles is a qualitative leap in sensitivity. The Privacy section of the README would need significant expansion.
3. **Complexity explosion.** AXUIElement is a C API with manual memory management (CFRelease), no documentation for edge cases, and notorious for crashing when apps don't implement accessibility properly. A production-quality implementation would need defensive coding, timeout handling, and graceful degradation.
4. **Scope creep.** The tool's stated purpose is to "narrow suspects" at the app level. Window-level tracking moves toward "full window manager monitor" territory.
5. **Diminishing returns.** In practice, knowing "Safari stole focus" is usually sufficient — the user can then investigate which Safari feature is misbehaving. The window-level granularity rarely changes the diagnosis.

**My position:** Defer indefinitely. The cost (accessibility permission, privacy concerns, implementation complexity) far outweighs the benefit for the stated use case. If a future user demonstrates a concrete scenario where app-level tracking is insufficient, reconsider as an opt-in `--window-tracking` flag — but don't build it speculatively.

**Complexity:** Very high. 200+ lines of Swift, significant testing burden, documentation overhead.

**Priority:** LOW — defer.

---

## Priority Ordering

If we can only do 2-3:

| Priority | Proposal | Effort | Impact |
|----------|----------|--------|--------|
| 1 | P4: Status check (`--status`) | Medium | High — fills the biggest usability gap |
| 2 | P2: `--follow` mode | Medium | High — transforms the debugging workflow |
| 3 | P1: NSRunningApplication | Low | Medium — clean improvement, low risk |
| 4 | P3: Package.swift | Very low | Low-medium — only helps developers |
| 5 | P5: Accessibility API | Very high | Low — defer |

**Recommended first batch:** P4 + P2 + P1 (all three are achievable in a single session and each delivers independent value).

P3 can be added anytime as a 5-minute task. P5 should wait for a concrete user need.
