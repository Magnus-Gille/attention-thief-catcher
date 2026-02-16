# Usability Debate Summary

**Date:** 2026-02-16
**Topic:** Usability of attention-thief-catcher as an open source tool
**Participants:** Claude Opus 4.6 (assessor/defender) vs Codex (adversarial reviewer role)
**Rounds:** 2 (draft + critique + response + rebuttal)
**Total critique points:** 24

---

## Key Findings

### Consensus #1 Priority: Process Snapshots Not Displayed by Analyzer

Both participants agree the single most important usability fix is surfacing process snapshot data in `analyze_anomalies()`. The daemon captures full `ps` output on every anomaly event (Sources/attention-thief-catcher.swift:159-164), which is the most valuable forensic artifact for identifying a focus thief. However, the analyzer (Scripts/analyze.py:111-137) never displays this data, making it invisible to users unless they manually inspect raw NDJSON files. This is a *broken feature*, not a missing one.

**Fix cost:** ~10 lines of Python in analyze.py
**Impact:** Transforms the tool's core value proposition from "you can theoretically find the data" to "the tool shows you the answer."

### Consensus #2 Priority: Silent Failure in LogWriter Initialization

The `try?` on attention-thief-catcher.swift:16 silently ignores directory creation failures, which cascades into nil `fileHandle` and silent event dropping. For a monitoring tool, running without logging is the worst failure mode. Both participants agree this should use `try` with proper error reporting (e.g., logging to stderr and/or exiting with a clear error message).

### Consensus #3 Priority: Install Script Prerequisite Checks

The install script should validate prerequisites before attempting compilation: check for `swiftc`, check that the Xcode license has been accepted, and provide clear error messages for each failure mode.

---

## Concessions by Claude (Defender)

| # | Issue | Concession Type |
|---|-------|----------------|
| 1 | Process snapshot not displayed (U-10) | Full concession -- missed entirely in draft |
| 2 | `try?` masks directory creation failure (U-09) | Full concession -- pinpointing accepted |
| 3 | Xcode license failure mode (U-07) | Full concession -- more common than swiftc-not-found |
| 4 | sed expansion fragility (U-08) | Reversed from praise to concern |
| 5 | Privacy severity (U-14) | Upgraded from documentation gap to high severity |
| 6 | Contribution barrier (U-16) | Accepted -- Package.swift cost is negligible |
| 7 | Homebrew priority (U-02) | Downgraded from major to nice-to-have |
| 8 | Log growth urgency (U-03) | Moderated -- valid principle, overstated urgency |
| 9 | Feature request syndrome | Acknowledged -- draft too wish-list-heavy |

## Defenses Maintained by Claude

| # | Issue | Defense |
|---|-------|---------|
| 1 | Log growth principle | Valid concern regardless of growth rate |
| 2 | `--around` flag coverage | Mentioned three times, not buried |
| 3 | Color output necessity | ANSI colors need terminal detection for piping |
| 4 | Single-file feasibility for contributors | Friction, not impossibility |

## Defenses Challenged by Codex (Rebuttal)

| # | Issue | Challenge |
|---|-------|-----------|
| 1 | "Temporary tool" argument for upgrade path | Contradicted by daemon's persistent design (KeepAlive, auto-start) |
| 2 | Privacy hedge ("not more sensitive than shell history") | Passive activity logging is more invasive than user-initiated command recording |
| 3 | `--around` flag not buried | Attention budget allocation was poor -- more words on wish-list than strengths |

---

## Unresolved Disagreements

1. **Notification support for anomalies (U-17):** Claude considers this potential scope creep; Codex did not push strongly on this. Deferred as a design philosophy question for the author.

2. **Upgrade mechanism necessity (U-15):** Claude argues the tool is temporary-use by nature; Codex argues the daemon's design contradicts this. Partially resolved -- both agree a `--version` flag is warranted, but a full upgrade mechanism is debatable.

3. **Severity of Homebrew absence (U-02):** Claude downgrades to nice-to-have; the discoverability argument has merit but is unlikely to be a practical barrier for this niche tool.

---

## Action Items (Prioritized)

### Critical (fix now)

| # | Action | File(s) | Effort |
|---|--------|---------|--------|
| 1 | Display processSnapshot in analyze_anomalies() output | Scripts/analyze.py | ~10 lines |
| 2 | Replace `try?` with `try` + error handling in LogWriter.init() | Sources/attention-thief-catcher.swift:16 | ~5 lines |
| 3 | Add prerequisite checks to install.sh (swiftc, Xcode license) | Scripts/install.sh | ~15 lines |

### High (fix soon)

| # | Action | File(s) | Effort |
|---|--------|---------|--------|
| 4 | Add health check / status script | Scripts/status.sh (new) | ~20 lines |
| 5 | Add Privacy section to README | README.md | ~10 lines |
| 6 | Move plist stderr/stdout from /tmp to persistent location | LaunchAgents/...plist | 2 lines |
| 7 | Add Package.swift for contributor IDE support | Package.swift (new) | ~15 lines |

### Medium (improve quality)

| # | Action | File(s) | Effort |
|---|--------|---------|--------|
| 8 | Add version constant and git tags | Sources/...swift, git | ~5 lines |
| 9 | Add sample output / screenshot to README | README.md | ~30 lines |
| 10 | Add troubleshooting section to README | README.md | ~20 lines |
| 11 | Add log retention / cleanup mechanism | Sources/...swift or cron | ~30 lines |
| 12 | Add --follow mode to analyzer | Scripts/analyze.py | ~40 lines |
| 13 | Add relative timestamps in --last mode | Scripts/analyze.py | ~15 lines |

### Low (polish)

| # | Action | File(s) | Effort |
|---|--------|---------|--------|
| 14 | Fix histogram proportional scaling | Scripts/analyze.py:157 | ~5 lines |
| 15 | Add optional color output with terminal detection | Scripts/analyze.py | ~30 lines |
| 16 | Add allowlist/blocklist for known-benign apps | Sources/...swift + config | ~50 lines |

---

## Cost Table

| Artifact | Participant | Tokens (est.) |
|----------|------------|---------------|
| usability-claude-draft.md | Claude Opus 4.6 | ~3,500 |
| usability-claude-self-review.md | Claude Opus 4.6 | ~1,800 |
| usability-codex-critique.md | Codex (adversarial role) | ~3,200 |
| usability-claude-response-1.md | Claude Opus 4.6 | ~2,800 |
| usability-codex-rebuttal-1.md | Codex (adversarial role) | ~2,400 |
| usability-critique-log.json | Claude Opus 4.6 | ~3,000 |
| usability-summary.md | Claude Opus 4.6 | ~2,000 |
| **Total** | | **~18,700** |

---

## Debate Quality Assessment

The debate process materially improved the usability analysis. The initial draft scored a self-assessed 6/10 for the project's usability. After two rounds:

- **3 critical issues** were identified that the draft missed entirely (process snapshot display, `try?` silent failure, Xcode license check)
- **2 new issues** emerged in the rebuttal (real-time follow mode, plist stderr to /tmp)
- **3 concerns** were correctly moderated (Homebrew priority, log growth urgency, feature-list inflation)
- The final priority list is concrete, actionable, and ordered by impact-to-effort ratio

The most valuable outcome of the adversarial process was shifting the assessment from "features this tool should have" to "things this tool does wrong" -- a more useful framing for an open source maintainer deciding what to fix first.
