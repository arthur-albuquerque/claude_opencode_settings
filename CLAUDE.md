# Budget-aware pacing (Claude usage limit)

This applies to **every session**, interactive or autonomous. It governs only your **Claude usage limit**.

## The signal — the hook pushes it to you; don't poll

`hooks/usage-warning.sh` (wired to `PostToolUse` + `SessionStart` — automatic when this ships as the `opencode-coordinator` plugin, a required manual install otherwise) reads `~/.claude/usage-snapshot.json` — the harness's own live limit percentages, rewritten by `~/.claude/statusline-command.sh` on every statusline render — and **injects the warning straight into your context**: a heads-up at ≥90%, a stop directive at ≥95%, silent below that. This is the one Claude-window signal. You do not run a budget command and you do not poll the snapshot on a schedule — the warning comes to you; when it lands, act on it. It is authoritative: the same accounting behind the harness's `<system-reminder>` limit warning.

The snapshot is the hook's data source, not something you watch. Read it directly only to grab the exact `.five_hour.resets_at` / `.seven_day.resets_at` (unix epoch) you need when arming a wakeup: `jq . ~/.claude/usage-snapshot.json`. (`.context_pct` there is the context window, not a usage limit — ignore it for budget.)

## The rule

The moment the hook injects its ≥95% stop directive (or a harness `<system-reminder>` limit warning appears):
1. Stop starting new work; checkpoint state in one sentence.
2. Enter the Auto-resume loop below, arming the wakeup off the tripped window's `.resets_at` (read it from the snapshot).
3. Tell me which window tripped and its percentage, and announce the wakeup (rule below).

This is the default; an explicit user override lifts it (next section).

The ≥90% heads-up is your runway: finish the current step, don't start a heavy new chunk, don't pause yet.

## User override — "continue regardless of usage"

The 95% stop is the **default**, not a hard wall. If I **explicitly** say to keep working despite the usage limit ("continue regardless of usage", "ignore the budget stop", "override the limit", or equivalent), that is authorization to continue **this session's** current task. Then:

1. Activate the override so the hook stops injecting stop directives — write the **tripped window's** reset epoch to this session's **per-session** flag file:
   `jq -r '.five_hour.resets_at' ~/.claude/usage-snapshot.json > ~/.claude/usage-override-$CLAUDE_CODE_SESSION_ID` (use `.seven_day.resets_at` if the weekly window tripped). The filename is keyed to `$CLAUDE_CODE_SESSION_ID` on purpose: usage limits are per-account, so every session trips 95% at once, but this file lifts the stop for **this session only** — other sessions stay stopped. While the file holds a future epoch, the hook downgrades this session's ⛔ stop to a one-line 🔓 reminder and suppresses its ≥90% heads-up.
2. Keep working — but keep exactly one dead-man's-switch `ScheduleWakeup` armed the entire time. The override silences the **hook**, not the **hard limit**: a hard trip can still lock the session mid-turn, and only a pre-armed wakeup restarts it.
3. Tell me the override is active and when it expires, in the same turn you activate it.
4. **Delete the flag the moment the authorized task is done** — `rm -f ~/.claude/usage-override-$CLAUDE_CODE_SESSION_ID`. The override is scoped to the specific task I authorized, not the whole window: as soon as you finish it, remove the flag so the default stop protects any *further* work in this session. Two backstops cover the file if you forget: the hook deletes it automatically once its epoch passes (at the latest, at window reset), and it dies with the machine's `~/.claude` regardless.
5. Never renew or re-create the flag without a fresh explicit request from me. One authorization covers one task in one window; when it expires or the task ends, the default rule is back.
6. Explicit means explicit: a generic "keep going" about the task, impatience, or an old authorization from a previous task/window is **not** a budget override. When in doubt, follow the default rule.
7. If I say to stop overriding, `rm -f ~/.claude/usage-override-$CLAUDE_CODE_SESSION_ID` and return to the default rule immediately. (A deliberate *all-sessions* switch is possible by writing the suffix-less `~/.claude/usage-override`, but only create that on an explicit request to override every session at once.)

## Dead-man's switch

A hard trip mid-turn locks the session, and only a `ScheduleWakeup` armed *beforehand* can restart it. So keep exactly one armed:

- **Arm** a `ScheduleWakeup` whenever a background job is in flight OR a multi-step plan has real work left. Skip routine short turns.
- **Its delay tracks the reset clock, never a fixed interval.** Each time you arm or refresh it, read the snapshot fresh and set `delaySeconds = min(3600, nearest .resets_at − now + 60)`. That way a hard trip wakes ~1 min after the true reset instead of up to an hour late on an arbitrary timer.
- Its prompt must be self-contained: remaining plan, concrete next step, budget check to run on wake.
- **Refresh** it as work advances; **drop** it when the work is done.

Leaving one armed is safe — a wakeup that outlives its task just ends the turn (loop step 3).

## Announce every wakeup — never pause silently

An armed wakeup is invisible to me: if you arm one and end the turn without saying so, the session just looks dead. So every time you **arm, refresh, or stop** a `ScheduleWakeup` — budget pause, dead-man's switch, `/loop` pacing, anything — the final user-visible message of that turn MUST state, in plain language:

1. that a wakeup is armed and the session will pause and resume itself (or, on stop, that automatic resumes have ended);
2. the **exact local fire time** and roughly how far away it is;
3. **why** the wakeup exists;
4. what you will do when it fires.

The `hooks/announce-wakeup.sh` hook (wired to `PostToolUse` with matcher `ScheduleWakeup`) computes the exact fire time and injects this requirement right after the tool call — relay what it reports; never end the turn with only tool output.

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
