# Adversarial Design Reviews

This directory contains structured adversarial reviews of the project. Each review pits two AI models against each other in a multi-round debate to stress-test decisions, surface blind spots, and produce actionable findings.

## Why adversarial review?

Self-review catches obvious issues but misses blind spots. By having one model draft an assessment and another critique it adversarially (then respond, then rebut), the process surfaces issues that neither would find alone. The self-review catch rate column below shows what percentage of the final critique points were already identified during self-review — the rest were only found through adversarial pressure.

## Reviews

| Date | Topic | Rounds | Key outcome | Critique points | Self-review catch rate |
|------|-------|--------|-------------|----------------|-----------------------|
| 2026-02-16 | [Security](security-summary.md) | 2 | Fix log permissions (0700/0600), add symlink check, redirect stdout/stderr from /tmp | 11 | 4/11 (36%) |
| 2026-02-16 | [Usability](usability-summary.md) | 2 | Display process snapshots in analyzer output, fix silent LogWriter failure, add install prerequisites | 24 | 9/24 (38%) |
| 2026-02-16 | [Big picture](bigpicture-summary.md) | 2 | Reframe README: tool narrows suspects, doesn't definitively catch them; fix App Nap risk | 16 | 5/16 (31%) |

**Start with the summaries** — they contain the final agreed findings, action items, and unresolved disagreements. The full debate chain is available if you want to see how conclusions were reached.

## How to read a debate

Each review produces these files (using `security` as an example):

| File | What it is |
|------|-----------|
| `security-summary.md` | **Start here.** Final findings, action items, and what changed during the debate. |
| `security-critique-log.json` | Machine-readable log of every critique point with classification, severity, and resolution. |
| `security-claude-draft.md` | Initial assessment written by Claude. |
| `security-claude-self-review.md` | Claude's self-critique before adversarial review begins. |
| `security-codex-critique.md` | Round 1: Adversarial critique of the draft. |
| `security-claude-response-1.md` | Round 1: Response with concessions, partial concessions, and defenses. |
| `security-codex-rebuttal-1.md` | Round 2: Final rebuttal — acknowledges valid defenses, presses remaining points. |

The debate follows a fixed protocol: draft, self-review, critique, response, rebuttal. Most debates settle in 2 rounds. Additional rounds are added only if genuinely new issues emerge.

## Snapshot

All three reviews were conducted against commit [`8f1ac93`](../../../commit/8f1ac936d06b7dc6a93ccd5c54b25d41ea4f3baa), before the fixes were applied. The findings from these debates directly produced the changes in the subsequent commit.

## Process details

- **Participants:** Claude Opus 4.6 (drafter/defender) vs adversarial reviewer
- **Protocol:** Structured debate with explicit concessions, defenses, and a machine-readable critique log
- **Independence note:** The adversarial reviewer role was performed by Claude adopting an adversarial stance. In ideal conditions, a separate model (e.g., Codex) provides true independence, but the structured protocol (explicit concessions, defense requirements, evidence grounding) still produces useful results with a single model.
