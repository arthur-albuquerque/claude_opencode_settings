# Claude Code × OpenCode Go — coordinator/worker settings (skill edition)

> In short, this setup turns Claude Code into a budget-aware coordinator that delegates coding work
> to cheap OpenCode Go workers, verifies every worker result before shipping it, and monitors live
> usage across both services so it pauses before a budget window is exhausted and automatically
> resumes once it resets.
>
> The main goal is to let Claude run long coding sessions by itself with as little human
> intervention as possible.

Global Claude Code configuration for people who run **Claude Code** (Fable 5 / Opus) alongside an
**[OpenCode Go](https://opencode.ai)** subscription. It turns Claude into a *coordinator* that spends
its expensive tokens on judgment — diagnosis, task decomposition, code review, verification — while
delegating the actual typing of code to cheap OpenCode Go models invoked via the `opencode` CLI from
the same session.

The goal: long, productive Claude sessions that don't burn through usage limits, because the bulk
token spend (writing code) happens on a flat-rate $12/5h worker plan instead of on Claude.

## How this branch differs from `main`

On the [`main`](https://github.com/arthur-albuquerque/claude_opencode_settings/tree/main) branch the
**entire** framework lives in the global `~/.claude/CLAUDE.md`, so every Claude session — even one
where you never intend to delegate — is forced to load the coordinator/worker rules, the model
table, and the delegation contract.

This branch **splits the framework by scope** so nothing is forced on you that a session doesn't
need:

| Concern | Scope | Where it lives |
|---------|-------|----------------|
| **Claude-usage-limit pacing** + dead-man's-switch + auto-resume loop | Applies to **every** session (the usage-warning hook fires regardless) | `CLAUDE.md` — stays always-on |
| **Coordinator/worker delegation** — the split, model table, prompt contract, QA loop, OpenCode worker budget, viz default | Only matters when you actually delegate | `skills/delegate/SKILL.md` — a **user-invoked skill** you activate on demand |

The budget pacing has to stay always-on: the `usage-warning.sh` hook injects a warning on every
session, so the response protocol (pause → arm `ScheduleWakeup` → auto-resume) must always be in
context. The delegation framework does *not* — you opt into it by typing `delegate`, and it loads
for that session only. A plain, non-delegating session pays zero context load for it.

The `delegate` skill is set `disable-model-invocation: true`, so it costs nothing until you invoke
it by name and the model never fires it on its own.

## What's in here

| File | Installs to | Purpose |
|------|-------------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | Always-on budget pacing only: the Claude usage-limit signal, dead-man's switch, and auto-resume loop |
| `skills/delegate/SKILL.md` | `~/.claude/skills/delegate/SKILL.md` | The opt-in coordinator/worker framework: delegation rules, model table, prompt contract, QA loop, worker budget |
| `statusline-command.sh` | `~/.claude/statusline-command.sh` | Claude Code status line script that persists `~/.claude/usage-snapshot.json` |
| `hooks/usage-warning.sh` | `~/.claude/hooks/usage-warning.sh` | Hook that auto-injects a budget warning into the agent's context at ≥90% / ≥95% of a Claude usage window |
| `scripts/opencode-go-usage.py` | `~/.claude/scripts/opencode-go-usage.py` | OpenCode Go budget check (authoritative gateway blocked-state probe) |
| `opencode.worker-agent.example.json` | merge into `~/.config/opencode/opencode.json` | The `worker` agent definition that lets `opencode run` edit files non-interactively |

## What the framework does

### Always-on (`CLAUDE.md`)

- **Budget-aware pacing.** The Claude-window signal is the `hooks/usage-warning.sh` hook (a required
  install): it reads `~/.claude/usage-snapshot.json` — a machine-readable snapshot written by
  `statusline-command.sh` on every status-line render using the harness's own accounting — and
  *pushes* the warning straight into the agent's context every tool-using turn once a window crosses
  90% (heads-up) / 95% (stop directive). The agent never polls; the warning comes to it, so the
  pause no longer depends on the agent remembering to check.
- **Dead-man's switch.** A proactively-armed `ScheduleWakeup` backstops the one case the hook can't
  catch — a hard trip mid-turn on a lagging snapshot.
- **Auto-resume loop.** When a long autonomous job pauses near a usage limit, the session schedules
  its own wakeups (chained hourly `ScheduleWakeup` calls, since resets can be hours out), re-checks
  the tripped window on each wake with a minimal turn, and resumes the remaining plan the moment the
  window clears — no human restart needed.

### Opt-in (`delegate` skill — invoke with `delegate`)

- **Coordinator/worker split.** Clear rules for what Claude does directly (trivial edits, config,
  git), what it delegates (anything that writes or modifies code), and what it must never delegate
  (diagnosis, architecture, final review).
- **Worker model rankings.** A cost/intelligence/taste table of OpenCode Go models with per-task
  defaults (bulk work → flash, standard specs → deepseek-v4-pro, hard coding → kimi-k2.7-code,
  repo-scale reasoning → glm-5.2) and a standing escalation ladder when output fails review.
- **Delegation prompt contract.** Nine rules that make worker prompts self-contained and
  judgment-free (exact file paths, pre-decided names/approaches, embedded context, built-in
  verification commands, do-not-touch lists), plus a list of banned vague phrases ("refactor as
  needed", "handle edge cases appropriately", …) that force weak models to hallucinate.
- **Non-negotiable QA loop.** After every worker run: read the actual `git diff`, re-run the
  verification command yourself, re-delegate up the ladder or fix residuals directly. The
  coordinator owns commits and everything user-visible.
- **OpenCode Go worker budget.** Checked with `opencode-go-usage.py`, which probes the Go gateway
  with a 1-token request (blocked requests are rejected before billing, so probing is free) and
  reports blocked-state + reset time authoritatively — the only worker-budget signal. On a worker
  block it hands off to the always-on auto-resume loop in `CLAUDE.md`.

## Setup

1. **Prerequisites:** [Claude Code](https://claude.com/claude-code), the
   [opencode CLI](https://opencode.ai) with an OpenCode Go subscription (run `/connect` inside
   opencode once so `~/.local/share/opencode/auth.json` holds your key), Python 3, and `jq`.
2. Copy `CLAUDE.md` to `~/.claude/CLAUDE.md` (or append to yours). This installs only the always-on
   budget pacing.
3. **Install the `delegate` skill.** Copy the whole folder:

   ```bash
   mkdir -p ~/.claude/skills/delegate
   cp skills/delegate/SKILL.md ~/.claude/skills/delegate/SKILL.md
   ```

   Then in any Claude Code session, type `delegate` to load the coordinator/worker framework for
   that session. Because it is `disable-model-invocation: true`, it never activates unless you invoke
   it by name.
4. Copy `statusline-command.sh` to `~/.claude/statusline-command.sh` and wire it into Claude Code.
   The easiest way is to run this inside Claude Code (it will update your `~/.claude/settings.json`):

   ```text
   /statusline use the existing executable script at ~/.claude/statusline-command.sh as the status-line command; it reads JSON from stdin and prints the context-window token count, 5-hour usage percentage with time remaining, and weekly usage percentage with reset time
   ```

   Or add it manually to `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "~/.claude/statusline-command.sh"
     }
   }
   ```

   The script runs after each assistant message and writes `~/.claude/usage-snapshot.json`, which
   `CLAUDE.md` reads as the authoritative Claude-window budget signal.
5. **Install the usage-warning hook — this is the Claude-window budget signal, not an add-on.**
   Copy `hooks/usage-warning.sh` to `~/.claude/hooks/usage-warning.sh`, `chmod +x` it, then wire it
   into `~/.claude/settings.json` on `PostToolUse` (fires every agentic turn, including autonomous
   `/loop` and `ScheduleWakeup` wakes) and `SessionStart` (fires on resume). If those events already
   have hooks, **append** this entry to their `hooks` array rather than replacing it:

   ```json
   {
     "hooks": {
       "PostToolUse": [
         { "matcher": "*", "hooks": [
           { "type": "command", "command": "~/.claude/hooks/usage-warning.sh", "timeout": 5 }
         ]}
       ],
       "SessionStart": [
         { "matcher": "*", "hooks": [
           { "type": "command", "command": "~/.claude/hooks/usage-warning.sh", "timeout": 5 }
         ]}
       ]
     }
   }
   ```

   The hook is silent below 90%; at ≥90% it injects a heads-up and at ≥95% a stop directive that
   quotes the pause procedure. It reads only the snapshot (no API calls). Test it before wiring:
   `printf '{"hook_event_name":"PostToolUse"}' | CLAUDE_USAGE_SNAPSHOT=<fixture.json> ~/.claude/hooks/usage-warning.sh`.
6. Copy `scripts/opencode-go-usage.py` to `~/.claude/scripts/`.
7. Merge the `agent.worker` block from `opencode.worker-agent.example.json` into your
   `~/.config/opencode/opencode.json`. Without it, `opencode run` auto-rejects file edits and
   delegation silently fails.
8. **Disable opencode's Claude Code compatibility.** OpenCode loads `~/.claude/CLAUDE.md` as a
   fallback instruction file by default. Because that file is written for Claude Code (budget pacing
   that drives `ScheduleWakeup` and other Claude-Code-only behavior), letting opencode read it causes
   opencode sessions to inherit rules they should not execute, and breaks `opencode run` / direct
   opencode usage. Add this to your shell profile:

   ```bash
   echo 'export OPENCODE_DISABLE_CLAUDE_CODE=1' >> ~/.zshrc
   source ~/.zshrc
   ```

   There is no equivalent key in `opencode.json`; this is the only supported mechanism. If you
   want to keep `.claude/skills` available to opencode but only suppress the `CLAUDE.md` prompt
   fallback, use `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` instead.
9. Start a Claude Code session anywhere — the global `CLAUDE.md` budget pacing applies to every
   project automatically; type `delegate` whenever you want to switch that session into
   coordinator/worker mode.

## Caveats

- The model table (names, pricing, request quotas) reflects OpenCode Go's catalog as of
  **July 2026**; re-rank when the catalog changes. It now lives in `skills/delegate/SKILL.md`.
- Budget figures assume the $12/5h ($30/wk, $60/mo) Go plan — adjust the numbers in
  `skills/delegate/SKILL.md` (worker budget) and the script's docstring if yours differs.
- The auto-resume loop only works while the Claude Code session stays open on an awake machine
  (`caffeinate -is` for overnight runs on macOS).
- The Claude-window signal is `usage-warning.sh` pushing the warning into context; it reads
  `usage-snapshot.json`, which `statusline-command.sh` writes only when the status line renders and
  the hook only fires on tool-using turns, so a single big turn can hard-trip before any warning —
  the dead-man's-switch `ScheduleWakeup` is the backstop for that. `opencode-go-usage.py` reports
  only the authoritative gateway blocked-state (there is no key-based percent-used API for OpenCode
  Go); it is the sole worker-budget signal.
- The `delegate` skill is user-invoked by design, so **you** are the one who has to remember it
  exists — that's the trade for it costing zero context load in sessions that don't need it.
