# Roadmap Debate — Summary

**Date:** 2026-02-16
**Participants:** Claude Opus 4.6 (drafter/defender) vs Codex gpt-5.3-codex (adversarial reviewer)
**Rounds:** 2
**Snapshot:** commit `8de9d56` (HEAD of main)
**Total critique points:** 23 (7 caught by self-review = 30%)

---

## Final Agreed Positions

### P1: Replace `/bin/ps` with `NSRunningApplication` — ACCEPT (revised scope)

**Agreed approach:** Hybrid — structured `NSRunningApplication` snapshots as default, `/bin/ps` retained for anomaly-only enrichment. Requires:
- Analyzer updates for mixed-format log parsing (old string vs new structured)
- README documentation update
- Schema migration handling for the 30-day mixed-format window

**Key correction:** Original "Low complexity, no downside" revised to "Medium complexity, real trade-offs." Security framing was overstated — the actual motivation is cleaner data format, not attack surface reduction.

**Priority:** 4th (deferred until schema migration plan is concrete)

### P2: Add `--follow` live-tail mode — ACCEPT (revised implementation)

**Agreed approach:** Implement with `select.kqueue` (not polling). Separate code path from batch mode. Handle log rotation internally. Optional `--stream` stdin mode for power users.

**Key correction:** Complexity estimate raised from 80-100 to 120-150 lines. `kqueue` accepted as the right choice for a macOS-only tool — portability dismissal was invalid.

**Priority:** 3rd

### P3: Add `Package.swift` — ACCEPT (scope expanded to full SPM migration)

**Agreed approach:** Migrate the build to SPM. Package.swift becomes canonical build metadata. `install.sh` calls `swift build -c release` instead of raw `swiftc`.

**Key correction:** Original "IDE-only, keep swiftc" revised to "full migration" after Codex demonstrated that dual build paths create unavoidable drift. One open question: verify AppKit linking works via SPM's `import` without explicit `-framework` flag.

**Priority:** 1st (lowest risk, enables all future Swift changes)

### P4: Add status/health-check — ACCEPT (implementation changed)

**Agreed approach:** Ship `Scripts/status.sh` as shell first-aid (zero Python dependency). Checks: agent loaded, PID alive, log freshness (sleep-aware), disk usage, recent restarts. Optionally add `analyze.py --status` later after refactoring analyzer startup.

**Key correction:** Original "put it in the analyzer" abandoned after Codex identified the bootstrap paradox: analyzer exits when logs are missing, which is exactly when status is needed most.

**Unresolved:** Sleep-aware staleness suppression can create false negatives (daemon died before logging wake). Accepted as low-risk edge case for a diagnostic tool.

**Priority:** 2nd

### P5: Accessibility API window-level tracking — BACKLOG (gated prototype)

**Agreed approach:** Not "defer indefinitely" but a time-boxed, opt-in prototype with strict constraints:
- No window titles (only window-change boolean events)
- Opt-in flag required
- Prototype goal: determine diagnostic value before committing
- Promotion gate: must demonstrate scenarios where app-level tracking is insufficient

**Key correction:** Original blanket deferral was too categorical. Both sides agree onboarding friction and privacy concerns are real, but a scoped experiment is worthwhile.

**Priority:** 5th (after P1-P4 are stable)

---

## Agreed Priority Ordering

| Priority | Proposal | Effort | Validation gate needed |
|----------|----------|--------|----------------------|
| 1 | P3: SPM migration | Low | Verify AppKit links via SPM; install.sh produces identical binary |
| 2 | P4: Status script | Medium | Works when logs are missing; sleep-aware freshness |
| 3 | P2: --follow mode | Medium-high | kqueue rotation handling; separate code path from batch |
| 4 | P1: NSRunningApplication | Medium | Schema migration plan; mixed-format analyzer support |
| 5 | P5: AX prototype | High (gated) | Must prove diagnostic value app-level can't provide |

**Codex verdict on ordering:** "Defensible with caveats." P3 and P1 need concrete validation criteria before execution.

---

## Concessions Accepted by Both Sides

| Point | Original position | Revised position |
|-------|------------------|-----------------|
| P1 security framing | "Removes attack surface" | Overstated; `/bin/ps` is not a shell invocation |
| P1 complexity | Low (~30 lines Swift) | Medium (Swift + Python + migration + docs) |
| P2 kqueue | Rejected on portability | Right choice for macOS-only tool |
| P3 build strategy | IDE-only Package.swift | Full SPM migration |
| P4 implementation | `analyze.py --status` | Shell first-aid script |
| P5 deferral | Indefinite | Time-boxed gated prototype |
| Priority ordering | P4, P2, P1, P3, P5 | P3, P4, P2, P1, P5 |

## Defenses Accepted by Codex

| Defense | Codex verdict |
|---------|--------------|
| libproc/sysctl is worse than either current approach | Reasonable for project scope |
| Self-contained --follow better UX than tail -F pipe | Defensible; --stream as optional addition |
| AX permission friction is a real adoption barrier | Valid even for minimal scope |
| Disk usage in status output is acceptable | Low-cost informational context |

## Unresolved Disagreements

1. **Testing/migration validation gates:** Claude says testing is a "parallel track, not a blocker." Codex says validation criteria are a prerequisite for P1 and P3. This is the single most important remaining gap.
2. **Sleep-aware staleness suppression:** Codex notes daemon death before wake logging creates false negatives. Claude accepts as low-risk edge case. Neither side proposes a concrete solution beyond acknowledging the limitation.
3. **P2-P3 dependency claim:** Claude asserted P2 benefits from P3 (Package.swift enables IDE support for future work). Codex correctly notes P2 is Python-side work and the dependency is weak.

---

## Additional Issues Surfaced

- **Periodic `PROCESS_SNAPSHOT` events are underutilized** in the analyzer — no dedicated analysis section exists. Worth adding as a standalone improvement.
- **Analyzer `parse_timestamp()` is fragile** (manual string surgery at `Scripts/analyze.py:25-44`). Technical debt worth addressing but orthogonal to these proposals.

---

## Debate Files

| File | Description |
|------|-------------|
| `roadmap-claude-draft.md` | Claude's original assessment of five proposals |
| `roadmap-claude-self-review.md` | Claude's self-critique (10 points) |
| `roadmap-codex-critique.md` | Codex Round 1 critique |
| `roadmap-claude-response-1.md` | Claude's response with concessions and defenses |
| `roadmap-codex-rebuttal-1.md` | Codex Round 2 final rebuttal |
| `roadmap-critique-log.json` | Machine-readable log of all 23 critique points |
| `roadmap-summary.md` | This file |

---

## Costs

| Invocation | Wall-clock time | Model version |
|------------|-----------------|---------------|
| Codex R1   | ~3m             | gpt-5.3-codex |
| Codex R2   | ~2m             | gpt-5.3-codex |
