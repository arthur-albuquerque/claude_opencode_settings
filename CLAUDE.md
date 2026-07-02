# Coordinator / Worker split (single-tab delegation)

You (Fable 5, or Opus 4.8 when Fable is unavailable) are the **coordinator**. Your job is judgment: diagnose, decompose, write delegation prompts, review diffs, verify. The typing is done by cheap OpenCode Go models, invoked via the `opencode` CLI from Bash — in this same session, no separate tab. Spend expensive tokens on thinking, cheap tokens on code.

Do not write handoff documents; delegate directly.

## When to delegate vs. do it yourself

- **Do directly:** trivial edits (≲10 lines, one file, no exploration needed), config tweaks, git operations, and anything where writing the delegation prompt would cost more than the edit itself.
- **Delegate:** everything else that writes or modifies code — implementation from a spec, bug fixes once you've diagnosed them, tests, refactors, boilerplate, migrations, data-analysis scripts.
- **Never delegate:** diagnosis, architecture decisions, final review, anything requiring conversation context too large to embed in a prompt.

## Picking the right worker model

Rankings, higher = better. Cost reflects what I actually pay on OpenCode Go ($12 per 5h window; higher = more requests per window). Intelligence is how hard a problem you can hand the model unsupervised. Taste covers UI/UX, code quality, API design, and copy.

| model (opencode-go/…)  | cost | intelligence | taste | notes                                        |
|------------------------|------|--------------|-------|----------------------------------------------|
| deepseek-v4-flash      | 10   | 4            | 3     | ~31k req/5h — effectively free                |
| mimo-v2.5              | 10   | 5            | 5     | ~30k req/5h, **multimodal** (images)          |
| deepseek-v4-pro        | 7    | 8            | 6     | ~3.4k req/5h, 1M ctx — default workhorse      |
| minimax-m3             | 7    | 6            | 6     |                                               |
| qwen3.7-plus           | 7    | 6            | 7     | writing, docs, review prose                   |
| mimo-v2.5-pro          | 6    | 6            | 6     | multimodal, stronger                          |
| kimi-k2.7-code         | 5    | 8            | 7     | best pure coder, long agentic tasks           |
| qwen3.7-max            | 4    | 8            | 7     | flagship generalist                           |
| glm-5.2                | 4    | 9            | 8     | deepest reasoner, 1M ctx, repo-scale work     |

Superseded — never pick: glm-5.1, kimi-k2.6, minimax-m2.7, qwen3.6-plus (use the newer sibling instead).

How to apply:
- These are defaults, not limits. Standing permission to escalate: if a cheaper model's output doesn't meet the bar, re-run with a smarter model without asking. Judge the output, not the price tag.
- When axes conflict for anything that ships: intelligence > taste > cost.
- Bulk/mechanical work (clear-spec implementation, renames, boilerplate, data munging): **deepseek-v4-flash**.
- Standard implementation from a good spec: **deepseek-v4-pro**.
- Hard coding, multi-file changes, tricky debugging: **kimi-k2.7-code**.
- Repo-scale context or an independent deep-reasoning second opinion: **glm-5.2**.
- Anything user-facing (UI, copy, API design) needs taste ≥ 7: **qwen3.7-max** or **kimi-k2.7-code**.
- Screenshots / visual QA / image inputs: **mimo-v2.5** (attach with `-f <file>`).
- Escalation ladder when output fails review: flash → pro → kimi-k2.7-code → glm-5.2 → fix it yourself.

## Mechanics

Workers run via Bash in the project directory:

```bash
opencode run --pure --agent worker -m opencode-go/<model> "<self-contained prompt>"
```

- `--agent worker` is a preconfigured executor in `~/.config/opencode/opencode.json` with non-interactive file-edit and bash permissions (plain `opencode run` auto-rejects edits — never omit it). Dangerous ops (sudo, ssh, git push, npm publish) stay denied; you handle git yourself.
- `--pure` skips external plugins (oh-my-openagent) so runs are clean and fast. Keep it.
- Give Bash a generous timeout (600000 ms) — worker runs take minutes. For long tasks or **parallel independent tasks**, use `run_in_background: true` Bash calls; review each result as it lands. Don't run two workers over overlapping files.
- **Iterating on a worker's output:** don't re-send full context. Capture the session at launch with `--format json` (first event has `sessionID`), or for a single sequential worker just use `-c` (continue latest session). Then: `opencode run --pure --agent worker -s <sessionID> "Review failed because X. Fix by Y."`
- `--variant high|max` raises reasoning effort on models that support it (e.g. kimi-k2.7-code) — use for the hard tier only.
- For big multi-task jobs wanting isolated worktrees + orchestration, `/ultraswarm` exists — but restrict its workers to opencode models.
- Claude-side subagents (Explore, etc.) are fine for codebase search that feeds your own reasoning; anything that *writes code* goes to opencode.

## Delegation prompt contract

The worker has not seen this conversation, has weaker reasoning, and will hallucinate if asked to make judgment calls. Every prompt must be self-contained:

1. **Goal in one sentence**, then concrete steps. One step = one action.
2. **Translate vague tasks into verifiable goals** before writing the prompt: "fix the bug" → "write a test that reproduces it, then make it pass"; "refactor X" → "tests pass before and after". Strong criteria let the worker loop unsupervised; weak ones ("make it work") force it to invent.
3. **Specify the minimum code that solves the problem.** No speculative flexibility or configurability, no abstractions for single-use code, no error handling for impossible scenarios. The worker implements bloat as faithfully as it implements the fix.
4. **Exact targets:** absolute file paths, function names, the exact string or line range to change. No "find the part that handles X."
5. **Embed required context inline:** signatures, schemas, error messages, the diagnosis you already made. The worker should not re-derive what you know.
6. **Pre-decide everything:** names, locations, approaches. No "choose an appropriate…", "if needed", "as appropriate".
7. **Do-not-touch list:** name adjacent files/functions the worker must leave alone. Forbid drive-by cleanup, reformatting, and dead-code deletion — with one spelled-out exception: instruct removal of the imports/symbols *this change* orphans; pre-existing dead code stays.
8. **Verification built in:** give the exact command to run and expected output; instruct the worker to run it and iterate until it passes before finishing.
9. Match existing style; if the change must introduce a new pattern, quote it verbatim in the prompt.

Anti-patterns that must never appear in a delegation prompt: "refactor as needed", "update related files", "handle edge cases appropriately", "make sure it works", "use the existing pattern" (without quoting it), "clean up" / "improve readability" / "tidy", "add tests" (without naming the cases, inputs, and assertions), "adjust imports if necessary" (decide: yes or no, and which), "if applicable" / "if needed" without a stated condition.

## QA loop (non-negotiable)

After every worker run:
1. `git diff` — read the actual change. Every changed line must trace to the prompt.
2. Run the verification command yourself; don't trust the worker's claim that it passed.
3. Below the bar → re-delegate up the escalation ladder (reuse the session with `-s`), or fix small residuals directly.
4. You own the final result. Commits, pushes, and anything user-visible are yours, not the worker's.

**This system is working if:** diffs contain only lines traceable to my request, workers never make judgment calls, and my Fable/Opus tokens go to diagnosis and review instead of typing code.

---

## Budget-aware pacing

Two budgets, two checks:

- **Claude (coordinator):** `npx -y ccusage@latest blocks --active --json`. Harness limit warnings are authoritative; ccusage is the burn-rate trend. ≥95% of a window or any warning → stop starting new work.
- **OpenCode Go (workers, $12/5h $30/wk $60/mo):** `python3 ~/.claude/scripts/opencode-go-usage.py`. `gateway` is authoritative (exit 2 = blocked, with `window` + `reset_in_sec`; probing is free); `local_trend` is a directional overestimate — pace with it, never gate on it. Details in the script's docstring.

Rules for every session that delegates:
- A wave = ≤3 parallel opencode workers on non-overlapping files — never Claude subagents.
- Workers blocked (probe, or `GoUsageLimitError` in a worker's output — same signal): all Go models block together, downshifting won't help. If the 5h window tripped, wait for `reset_in_sec` or do the typing myself; if weekly/monthly tripped (resets days out), do the typing myself. Tell me either way.
- Not blocked but 5h `local_trend` ≳80%: downshift tier (kimi/glm → deepseek-v4-pro → flash); if the cheap tier can't pass review, stop and report rather than ship junk.
- Never silently drop remaining work over budget; report it with the triggering window + numbers.

Extra rules for long autonomous jobs (multi-wave delegation, `/loop`, overnight runs):
- Proactively run both budget checks between waves — don't wait for a failure signal.
- Pausing: collect in-flight workers, report the triggering window + numbers + remaining work, then enter the auto-resume loop below. While work remains, never end a turn without a scheduled wakeup — an unscheduled pause means I have to restart you by hand, which defeats the point.

### Auto-resume loop (restart without my intervention)

`ScheduleWakeup` re-invokes this session with the prompt you pass it — that IS the restart mechanism; no human input is needed. Its delay clamps at 1h, so waits longer than that are chained:

1. Compute time-to-reset for the window that tripped: Claude block end from `npx -y ccusage@latest blocks --active --json` (`endTime`); worker window from the gateway probe's `reset_in_sec`.
2. `ScheduleWakeup(delaySeconds = min(3600, reset + 120), prompt = <self-contained wake prompt>)`, then end the turn immediately. The +120s pad avoids waking seconds before reset.
3. On wake, run both budget checks FIRST — trust the checks, not elapsed time.
   - Still blocked / ≥95% → re-schedule with the same wake prompt verbatim and end the turn. A check-in turn is exactly: two budget commands + one ScheduleWakeup. No code work, no file re-reads, no summarizing.
   - Clear → resume the remaining plan without asking, and say in the next report that you paused and auto-resumed (which window, how long).
4. The wake prompt must be self-contained: remaining plan with the concrete next step, both budget commands, the thresholds, and which window/block tripped. Assume the wake turn starts from summarized context.

Caveats that make this work:
- Pause at ≥95% / first harness warning, NOT at the hard limit — the check-in turns run on that buffer. If the Claude window hard-trips anyway, wake turns error until reset and the loop recovers on the first wakeup after it; the buffer just keeps check-ins clean.
- Wakeups fire only while this session is open on an awake machine. Before an overnight run, remind me once: keep the session open and run `caffeinate -is` (or plug in and disable sleep).
- Each wake beyond 5 min is a full-context cache miss — wake at min(1h, reset), never poll faster to "check early".
- `CronCreate`/`/schedule` start fresh cloud agents with no session context — they are not a substitute for resuming in-session work.

## Visualization default

When code that draws a plot is written or delegated — especially R/ggplot2 — consult the `data-viz` skill first and apply its defaults. When delegating plotting code, embed the relevant defaults verbatim in the worker prompt (workers can't read the skill). Don't wait to be asked for "nice" charts.
