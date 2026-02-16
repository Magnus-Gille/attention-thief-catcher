# Roadmap Proposals — Claude Self-Review

Before submitting to adversarial review, I'm critiquing my own draft to establish a baseline.

---

## Self-critique points

### SC-01: P1 hybrid approach may be over-engineered
I proposed keeping `/bin/ps` for anomaly-only snapshots while replacing the default with NSRunningApplication. But this means maintaining *two* snapshot mechanisms. If the goal is simplification, a hybrid is the opposite. Counter-argument: anomalies are rare and the diagnostic value of %CPU/%MEM during anomalies is real. But I haven't provided evidence that anyone has actually *used* this data to diagnose focus theft.

### SC-02: P2 polling interval choice is hand-wavy
I said "poll every 0.5s" without justifying why. What's the CPU cost? Is 0.5s responsive enough? Too responsive? I also dismissed `kqueue` without seriously engaging with the argument — `select.kqueue` is perfectly fine for a macOS-only tool.

### SC-03: P3 build path divergence risk is real but understated
I acknowledged two build paths but dismissed the risk too quickly. In practice: if someone opens the project in Xcode, Xcode will use `swift build`. If the Package.swift specifies different Swift language settings, optimization flags, or doesn't include `-framework AppKit`, the Xcode build will fail confusingly. I should address how to keep them in sync.

### SC-04: P4 subcommand vs separate script — I may be wrong
I argued for `analyze.py --status` over `status.sh`, but there's a strong counter: status checking is fundamentally a *system administration* task (is the daemon running? what's the PID?), while the analyzer is a *data analysis* tool. Mixing them may violate single-responsibility. Also, someone troubleshooting "why isn't it working" shouldn't need Python — a shell script with zero dependencies is more robust for first-aid.

### SC-05: P5 dismissal may be too categorical
I said "defer indefinitely" but the Accessibility API could also be used *without* window titles — just tracking "focused window changed within the same app" as a boolean event. This would sidestep the privacy concern while still providing diagnostic value. I didn't explore this middle ground.

### SC-06: Priority ordering lacks user evidence
My priority ordering is based on my assessment of user needs, not actual user feedback. The project has no issue tracker, no usage telemetry, and no user surveys. I'm guessing at what matters most.

### SC-07: Complexity estimates are gut feelings
"~80-100 lines" and "~60-80 lines" are not backed by any analysis. I didn't sketch the implementation or count the functions needed.

### SC-08: I didn't consider interactions between proposals
If P1 changes the snapshot format and P2 adds --follow mode, the --follow formatter needs to handle the new structured snapshot format. If P4 adds --status and P2 adds --follow, the argparse structure changes. These interactions aren't discussed.

### SC-09: Missing: what about testing?
None of the proposals discuss how they'd be tested. The project has no test suite. Should adding tests be a prerequisite or parallel track? This is arguably more important than any of the five proposals.

### SC-10: Missing: what about the analyzer's timestamp parsing fragility?
The `parse_timestamp()` function at `Scripts/analyze.py:25-44` is doing manual string surgery on timezone offsets. Any change to the daemon's timestamp format would break it silently. This technical debt isn't addressed by any proposal.

---

## Summary

I'm most uncertain about:
1. Whether the P1 hybrid approach is justified or over-engineered (SC-01)
2. Whether P4 belongs in the analyzer or as a standalone script (SC-04)
3. Whether P5 deserves a middle-ground approach rather than blanket deferral (SC-05)
4. Whether testing infrastructure should be proposal #0 (SC-09)
