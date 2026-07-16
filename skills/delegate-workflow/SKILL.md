---
name: delegate-workflow
description: Workflow-tier delegation — use when a delegation job decomposes into 3+ independent, non-overlapping opencode worker tasks (migrations, test backfills, multi-module features, overnight runs). For 1–2 tasks, or exploratory work where you want eyes on each diff as it lands, delegate directly per the coordinator doctrine instead.
---

# delegate-workflow — Workflow tier for opencode delegation

**Role contract:** you (the coordinator) do NOT write feature code and the Claude agents inside the Workflow do NOT write feature code — opencode workers do all coding. You keep Phase 0 (diagnose, decompose, gate-check, dispatch) and Phase 2 (final review, merge, commit, report). The Workflow in between is plumbing: thin wrapper agents that launch opencode workers, run gates, and return structured JSON, with the escalation ladder encoded as a retry loop instead of relying on your memory.

This skill layers on the coordinator doctrine (always in context via the global `CLAUDE.md`); every rule there — the delegation prompt contract, the model table, the QA bar, both budget signals — still applies. What changes is who executes the loop.

**Authorization:** the user installed this skill as their standing opt-in to Workflow orchestration for qualifying jobs. Activate it and launch on your own judgment — do not block on confirmation. The task table in Phase 0 step 4 is visibility, not a permission request.

## Phase 0 — inline, before any Workflow

1. **Probe the worker budget:** `python3 ~/.claude/scripts/opencode-go-usage.py`. Exit 2 = blocked — don't launch; handle per the doctrine (wait for `reset_in_sec` or do the typing yourself).
2. **Decompose** into 3–10 tasks `{id, description, files, model, risk, acceptance, prompt}`:
   - `prompt` follows the delegation prompt contract verbatim — self-contained, exact targets, pre-decided everything, do-not-touch list, verification built in. Workers see nothing else.
   - `model` from the doctrine's table (bulk → `deepseek-v4-flash`, standard spec → `deepseek-v4-pro`, hard → `kimi-k2.7-code`, repo-scale → `glm-5.2`).
   - `risk: "high"` if the task touches auth/security/payments, shared interfaces, or logic with no test coverage — high-risk tasks start at `kimi-k2.7-code` minimum and get 2-lens adversarial QA.
   - Tasks must be file-disjoint. Two tasks needing the same file = one task.
   - `long: true` for tasks likely to exceed ~8 minutes of worker time (big diffs, kimi/glm reasoning runs) — this switches the wrapper to the detached launch pattern.
3. **Verify the gates on the base tree:** run every gate command (build, typecheck, test, lint — detect from package.json/Makefile/CI) at the repo root and require green before launching. A gate that fails on the base tree poisons every QA cycle. No test command → say so loudly and ask whether to proceed. While here, size `concurrency.maxWorkers`: 6 for light gates; for heavy gates (full test suite, build) pass `min(6, max(2, floor(ncpu/2)))` using `sysctl -n hw.ncpu`.
4. **Show the task table** (id · description · files · model · risk · acceptance) in your message as you launch — the user must be able to see what was dispatched, but you don't wait for a yes. Installing this skill is their standing opt-in.
5. Arm the dead-man's-switch `ScheduleWakeup` per the doctrine — the Workflow is a background job in flight.

## Phase 1 — the Workflow

Read [`workflow-template.md`](workflow-template.md) now and author the Workflow from it, passing the values gathered in Phase 0 via `args`. The file holds the verified launch mechanics, the full script template, and its tuning notes — the template is the tested path; the notes mark what is tunable and what must stay.

## Phase 2 — after the Workflow returns (inline, you)

1. **Deferred tasks (budget block):** report the window + numbers, then enter the doctrine's auto-resume loop with `delaySeconds` from the probe's `reset_in_sec`. On the wake after reset, relaunch with `Workflow({scriptPath, resumeFromRunId})` — completed tasks replay from cache; only deferred ones run.
2. **Final review — the doctrine's QA loop, unreduced:** for every approved result, `cd` the worktree, read `git diff <baseBranch>...<branch>` yourself (every changed line traces to the task prompt), and run the verification command yourself. The Workflow's reviewers are a filter, not a substitute — you own the result.
3. **Merge sequentially,** one approved task at a time, from a clean main tree: `git merge --squash <branch>` → run EVERY gate → commit with your own message. A post-merge gate failure stops the line: revert, re-enter that task alone (one-task Workflow seeded with the failure as feedback, or fix it yourself), continue with the rest.
4. **Report:** task · worker model · attempts · QA verdict · files; then loudly: failed/tombstoned tasks, deferred tasks, anything you fixed yourself. Token accounting: the Workflow completion notification's `subagent_tokens` = Claude plumbing cost; the coding itself ran on Go tokens (unmetered — say so, don't guess a number). Then append the run's calibration data to `~/.claude/opencode-go-runlog.jsonl`, one JSON object per line: every row from the Workflow's returned `metrics` array, plus one `{ts, event:'block', window, reset_in_sec}` row per gateway block (from `blockInfo`/probe output). This log is the only path to real per-model drain numbers — after ~10 batches it answers whether blocks are common enough to justify anything smarter than the static tier caps.
5. **Cleanup sweep — only after the report:** `git worktree list` and `git branch --list 'delegate-workflow/*'`; remove every `<repoName>-dw-*` worktree and `delegate-workflow/*` branch, failed tasks included.

## Failure handling

| Failure | Response |
|---|---|
| Gate fails on base tree | Caught in Phase 0 — never launch against a broken gate |
| Worker hang (empty output ~2 min) | Wrapper kills + relaunches once, then `worker_failed` → ladder |
| Worker timeout (long-run, 4 waits) | `timeout` status → counts as failed attempt → ladder |
| Wrapper agent dies (null) | Same as failed attempt |
| `GoUsageLimitError` / probe exit 2 | Lanes freeze; deferred tasks reported; auto-resume loop + `resumeFromRunId` |
| Ladder exhausted | Task tombstones `{task, failed}` — you decide: implement it yourself (flag in report) or drop it with the user |
| Post-merge gate regression | Revert that squash, re-enter that task only, line continues |
