# Self-Review: Big Picture Assessment

**Date:** 2026-02-16
**Reviewer:** Claude Opus 4.6 (self-critique)

---

## Strengths of the Draft

1. **Covers breadth well.** The assessment touches on platform risks, ethics, architecture, scalability, alternatives, and maintenance — a genuinely wide-angle view.

2. **Calibrated tone.** The draft correctly identifies that this is a personal diagnostic tool and avoids holding it to enterprise-software standards. Recommendations are proportionate to the project's scope.

3. **Specific technical observations.** The `synchronizeFile()` performance concern, the `ps`-during-anomaly-storm issue, and the unbounded `recentLaunches` dictionary are concrete, actionable findings.

4. **Honest about alternatives.** The assessment correctly argues that the current approach (passive monitoring) is the right one for the stated problem, and that alternatives (menu bar app, system extension) are over-engineered for this use case.

## Weaknesses and Blind Spots

### 1. Too generous about the surveillance concern
The draft waves away the surveillance risk with "it requires login credentials to install" and "it writes to a well-known location." These mitigations are weak. An abusive employer could install this during device provisioning, or a domestic abuser with access to the target's already-logged-in laptop could run `install.sh` in 10 seconds. The "well-known location" argument assumes the target would check `~/Library/Logs/` — most macOS users never look there. The draft should be more honest that this tool, with minimal modification (change the log path, rename the binary), becomes a credible surveillance tool.

### 2. Underestimates the process enumeration risk
The draft mentions that Apple could restrict `ps` access but treats this as speculative. In reality, macOS has been tightening process visibility for years. The `sysctl` `kern.procargs2` call that `ps` relies on has already been restricted for sandboxed apps. The trajectory is clear. The draft should recommend replacing `ps` with a direct `sysctl` call or `NSRunningApplication` enumeration to reduce future breakage risk.

### 3. Misses the "solved problem" scenario
The STATUS.md already identifies AltTab as the prime suspect. If the next analysis run confirms this, the tool has served its purpose. The draft discusses "project lifecycle" but does not squarely address: what happens after the bug is diagnosed? Is this tool worth open-sourcing if it is a one-time diagnostic? The answer may be yes (others have this problem too), but the draft should engage with this question more directly.

### 4. Does not consider energy impact
The tool runs three timer-based systems: notification observer, 3-second polling timer, and 5-minute snapshot timer. The polling timer fires 20 times per minute. Combined with `synchronizeFile()` on every write, this may prevent macOS from entering low-power states efficiently. The LaunchAgent sets `LowPriorityIO` and `Nice 10`, but does not use `ProcessType: Adaptive` which would give macOS more latitude to defer work. The energy impact may be negligible in absolute terms but should be acknowledged.

### 5. Glosses over the NDJSON format choice
The draft does not question whether NDJSON is the right log format. Alternatives:
- **os_log / Unified Logging**: Would integrate with Console.app and `log stream`, support structured predicates, and automatically handle log rotation and retention. However, it would make the custom analyzer harder to build.
- **SQLite**: Would enable SQL queries over events, support indexed lookups, and handle retention naturally. More complex to write to.
- **CSV**: Simpler to analyze with standard Unix tools but loses structure.

The draft mentions `os_log` in passing but does not properly evaluate the trade-offs. NDJSON is a defensible choice, but the draft should defend it explicitly.

### 6. Competitive analysis is shallow
The draft lists competitors but does not deeply evaluate them. For example:
- Does Hammerspoon actually provide equivalent anomaly detection out of the box, or would the user need to write Lua scripts from scratch?
- Are there specific GitHub projects doing the same thing? A search for "macOS focus monitor" or "macOS focus steal detector" would reveal the actual competitive landscape.
- The draft mentions "various GitHub scripts" without citing any.

### 7. Does not address data format stability
If the tool gains users, the NDJSON schema becomes an implicit contract. The current format has no version field. If the log format changes (e.g., adding new fields, changing field names), old `analyze.py` scripts would break on new logs and vice versa. For a personal tool this is trivial, but the draft should mention it as a concern for broader adoption.

### 8. Misses the "multiple instances" problem
What happens if the user runs `install.sh` twice? The script handles this (unloads existing agent first, line 20-24), but what if someone manually compiles and runs the binary while the LaunchAgent is also running? Two instances would both write to the log directory, potentially to different files, with no coordination. The tool has no instance lock mechanism.

## Overall Self-Assessment

The draft is **adequate but too comfortable**. It correctly identifies the project's strengths and gives proportionate recommendations, but it pulls punches on the surveillance concern, underestimates platform risk trajectory, and does not deeply enough question whether the project has a future beyond its initial diagnostic purpose. A stronger assessment would be more willing to say: "This may be a tool that should be used, then deleted, and that is perfectly fine."
