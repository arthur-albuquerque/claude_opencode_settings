# Budget-aware pacing (Claude usage limit)

This applies to **every session**, interactive or autonomous. It governs only your **Claude usage limit**.

## The signal — the hook pushes it to you; don't poll

`hooks/usage-warning.sh` (wired to `PostToolUse` + `SessionStart` — automatic when this ships as the `opencode-coordinator` plugin, a required manual install otherwise) reads `~/.claude/usage-snapshot.json` — the harness's own live limit percentages, rewritten by `~/.claude/statusline-command.sh` on every statusline render — and **injects the warning straight into your context**: a heads-up at ≥90%, a stop directive at ≥95%, silent below that. This is the one Claude-window signal. You do not run a budget command and you do not poll the snapshot on a schedule — the warning comes to you; when it lands, act on it. It is authoritative: the same accounting behind the harness's `<system-reminder>` limit warning.

The snapshot is the hook's data source, not something you watch. Read it directly only to grab the exact `.five_hour.resets_at` / `.seven_day.resets_at` (unix epoch) you need when arming a wakeup: `jq . ~/.claude/usage-snapshot.json`. (`.context_pct` there is the context window, not a usage limit — ignore it for budget.)

## The rule

The moment the hook injects its ≥95% stop directive (or a harness `<system-reminder>` limit warning appears):
1. Stop starting new work; checkpoint state in one sentence.
2. Enter the Auto-resume loop below, arming the wakeup off the tripped window's `.resets_at` (read it from the snapshot).
3. Tell me which window tripped and its percentage.

The ≥90% heads-up is your runway: finish the current step, don't start a heavy new chunk, don't pause yet.

## Dead-man's switch

A hard trip mid-turn locks the session, and only a `ScheduleWakeup` armed *beforehand* can restart it. So keep exactly one armed:

- **Arm** a `ScheduleWakeup` whenever a background job is in flight OR a multi-step plan has real work left. Skip routine short turns.
- **Its delay tracks the reset clock, never a fixed interval.** Each time you arm or refresh it, read the snapshot fresh and set `delaySeconds = min(3600, nearest .resets_at − now + 60)`. That way a hard trip wakes ~1 min after the true reset instead of up to an hour late on an arbitrary timer.
- Its prompt must be self-contained: remaining plan, concrete next step, budget check to run on wake.
- **Refresh** it as work advances; **drop** it when the work is done.

Leaving one armed is safe — a wakeup that outlives its task just ends the turn (loop step 3).

## Auto-resume loop (restart without my intervention)

`ScheduleWakeup` re-invokes this session with the prompt you pass it — that IS the restart mechanism; no human input is needed. Its delay clamps at 1h, so waits longer than that are chained:

1. Compute time-to-reset for the window that tripped: `~/.claude/usage-snapshot.json` (`.five_hour.resets_at` or `.seven_day.resets_at`, unix epoch — subtract `date +%s`).
2. `ScheduleWakeup(delaySeconds = min(3600, reset + 60), prompt = <self-contained wake prompt>)`, then end the turn immediately. The +60s pad lands the wake just after the reset — the snapshot epoch and `date +%s` share one clock, so no larger skew margin is needed, and an early wake is harmless (the loop just re-checks and re-arms).
3. On wake, run the budget check for the tripped window FIRST — trust the check, not elapsed time.
   - No work left (a standing dead-man's-switch wakeup that outlived its task) → end the turn; don't nag.
   - Still blocked (the tripped window's snapshot `used_percentage` is still ≥95 / its `resets_at` is still in the future) → re-schedule with the same wake prompt verbatim and end the turn. A check-in turn is exactly: the budget command + one ScheduleWakeup. No code work, no file re-reads, no summarizing.
   - Clear → resume the remaining plan without asking, and say in the next report that you paused and auto-resumed (which window, how long).
4. The wake prompt must be self-contained: remaining plan with the concrete next step, the budget command for the tripped window, the thresholds, and which window tripped. Assume the wake turn starts from summarized context.

Caveats that make this work:
- In an autonomous `/loop`, a budget block overrides the loop's cadence: compute the next wakeup's `delaySeconds` from the tripped window's `resets_at` (this loop), never from the loop's normal interval — then resume the loop's task on the first wake after the window clears.
- The 5-hour window is rolling, so `resets_at` drifts as old usage ages out. Recompute the delay from a fresh snapshot read at every arm, refresh, and wake — never reuse a stored value.
- Pause when the **hook injects its ≥95% stop directive, or the first harness warning** — NOT at the hard limit — so the check-in turns run on that buffer. The hook makes the pause actionable, but it reads a snapshot that can lag and fires only on tool turns; if the Claude window hard-trips anyway (stale read, a pure-text turn, or a warning that never arrived), wake turns error until reset and the loop recovers on the first wakeup after it — **but only if one was already armed.** That is why the standing dead-man's-switch wakeup (above) is the real backstop; without it, a hard trip can only be restarted by hand.
- Wakeups fire only while this session is open on an awake machine. Before an overnight run, remind me once: keep the session open and run `caffeinate -is` (or plug in and disable sleep).
- Each wake beyond 5 min is a full-context cache miss — wake at min(1h, reset), never poll faster to "check early".
- `CronCreate`/`/schedule` start fresh cloud agents with no session context — they are not a substitute for resuming in-session work.
