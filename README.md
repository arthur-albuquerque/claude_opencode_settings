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

This (`framework-as-skill`) is the repo's **default branch** and the recommended install: it is
packaged as the `opencode-coordinator` **Claude Code plugin**, so `/plugin marketplace add
arthur-albuquerque/claude_opencode_settings` resolves here.

On the [`main`](https://github.com/arthur-albuquerque/claude_opencode_settings/tree/main) branch the
**entire** framework lives in the global `~/.claude/CLAUDE.md`, so every Claude session — even one
where you never intend to delegate — is forced to load the coordinator/worker rules, the model
table, and the delegation contract. `main` is deliberately **not** packaged as a plugin (a second
plugin carrying the same hooks and doctrine would double-inject warnings and context if both were
enabled); it installs by copying files.

This branch **splits the framework by scope** so nothing is forced on you that a session doesn't
need:

| Concern | Scope | Where it lives |
|---------|-------|----------------|
| **Claude-usage-limit pacing** + dead-man's-switch + auto-resume loop | Applies to **every** session (the usage-warning hook fires regardless) | `CLAUDE.md` — stays always-on |
| **Coordinator/worker delegation** — the split, model table, prompt contract, QA loop, OpenCode worker budget, viz default | Only matters when you actually delegate | `skills/delegate/SKILL.md` — a **user-invoked skill** you activate on demand |

The budget pacing has to stay always-on: the `usage-warning.sh` hook injects a warning on every
session, so the response protocol (pause → arm `ScheduleWakeup` → auto-resume) must always be in
context. The delegation framework does *not* — you opt into it by typing `/delegate`, and it loads
for that session only. A plain, non-delegating session pays zero context load for it.

The `delegate` skill is set `disable-model-invocation: true`, so it costs nothing until you invoke
it by name and the model never fires it on its own.

On this branch the repo is also packaged as a **Claude Code plugin** (`opencode-coordinator`), so
the hooks, the skill, the worker-budget script, and the always-on doctrine all install with one
`/plugin` command instead of hand-copying files — see Setup.

## What's in here

The repo root **is** the plugin. Everything below the first group installs automatically when the
plugin is enabled; the last two rows are the irreducible manual pieces a plugin cannot ship.

| File | Role in the plugin | Purpose |
|------|--------------------|---------|
| `.claude-plugin/plugin.json` | manifest | Plugin identity (`opencode-coordinator`); `.claude-plugin/marketplace.json` makes this repo installable as its own marketplace |
| `CLAUDE.md` | injected by hook | Always-on budget pacing: the Claude usage-limit signal, dead-man's switch, auto-resume loop. Plugins don't load a root `CLAUDE.md`, so `hooks/inject-budget-doctrine.sh` pushes it into context at `SessionStart` |
| `skills/delegate/SKILL.md` | skill | The opt-in coordinator/worker framework: delegation rules, model table, prompt contract, QA loop, worker budget. Invoke with `/delegate` |
| `hooks/hooks.json` | hook wiring | Wires `usage-warning.sh` to `PostToolUse` + `SessionStart` and `inject-budget-doctrine.sh` to `SessionStart` — no `settings.json` editing |
| `hooks/usage-warning.sh` | hook | Auto-injects a budget warning into the agent's context at ≥90% / ≥95% of a Claude usage window |
| `bin/opencode-go-usage.py` | on `PATH` while enabled | OpenCode Go budget check (authoritative gateway blocked-state probe) |
| `statusline-command.sh` | **manual** → `~/.claude/statusline-command.sh` | Status line script that persists `~/.claude/usage-snapshot.json`. A plugin cannot set the main `statusLine`, and the status line is the only surface that receives live `rate_limits` data — this install cannot be skipped |
| `opencode.worker-agent.example.json` | **manual** → merge into `~/.config/opencode/opencode.json` | The `worker` agent definition that lets `opencode run` edit files non-interactively. Lives in opencode's config, outside Claude Code's reach |

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
  its own wakeups timed to the tripped window's exact reset time (`resets_at` from the snapshot,
  +60s pad — chained hourly only when the reset is more than 1h out), re-checks the tripped window
  on each wake with a minimal turn, and resumes the remaining plan the moment the window clears —
  no human restart needed, and no useful time lost to fixed-interval polling.

### Opt-in (`delegate` skill — invoke with `/delegate`)

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
2. **Install the plugin.** Inside Claude Code:

   ```text
   /plugin marketplace add arthur-albuquerque/claude_opencode_settings
   /plugin install opencode-coordinator@claude-opencode-settings
   ```

   (Or, from a local clone: `claude plugin marketplace add /path/to/claude_opencode_settings`,
   then the same install command.) This wires everything a plugin can carry:
   - the `usage-warning.sh` hook on `PostToolUse` + `SessionStart` — no `settings.json` editing;
   - the always-on budget doctrine (`CLAUDE.md`), injected into context at `SessionStart` by
     `inject-budget-doctrine.sh` (it skips itself if your `~/.claude/CLAUDE.md` already contains a
     "Budget-aware pacing" section, so you won't get it twice);
   - the `delegate` skill — type `/delegate` to switch a session into coordinator/worker mode; it
     is `disable-model-invocation: true`, so it never activates unless you invoke it by name;
   - `opencode-go-usage.py` on the Bash `PATH`.

   Two pieces **cannot** ship in a plugin and stay manual: the status line (step 3) and the
   opencode worker agent (step 4).

   <details>
   <summary>Manual install (no plugin)</summary>

   Copy `CLAUDE.md` to `~/.claude/CLAUDE.md` (or append to yours); copy `skills/delegate/SKILL.md`
   to `~/.claude/skills/delegate/SKILL.md`; copy `hooks/usage-warning.sh` to
   `~/.claude/hooks/usage-warning.sh`, `chmod +x` it, and wire it into `~/.claude/settings.json`
   on `PostToolUse` + `SessionStart` (append to those events' `hooks` arrays if they exist):

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

   Finally copy `bin/opencode-go-usage.py` to `~/.claude/scripts/opencode-go-usage.py`. Skip
   `hooks/hooks.json` and `hooks/inject-budget-doctrine.sh` — those are plugin plumbing.
   </details>

3. Copy `statusline-command.sh` to `~/.claude/statusline-command.sh` and wire it into Claude Code.
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

   The script runs after each assistant message and writes `~/.claude/usage-snapshot.json`, the
   snapshot the usage-warning hook reads. Without this step the hook stays silent and the whole
   Claude-window budget signal is dead — it is not optional.

   The hook itself is silent below 90%; at ≥90% it injects a heads-up and at ≥95% a stop directive
   that quotes the pause procedure. It reads only the snapshot (no API calls). Test it any time:
   `printf '{"hook_event_name":"PostToolUse"}' | CLAUDE_USAGE_SNAPSHOT=<fixture.json> hooks/usage-warning.sh`.
4. Merge the `agent.worker` block from `opencode.worker-agent.example.json` into your
   `~/.config/opencode/opencode.json`. Without it, `opencode run` auto-rejects file edits and
   delegation silently fails.
5. **Disable opencode's Claude Code compatibility.** OpenCode loads `~/.claude/CLAUDE.md` as a
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
6. Start a Claude Code session anywhere — the budget-pacing doctrine loads in every session
   (injected by the plugin at `SessionStart`, or from `~/.claude/CLAUDE.md` on manual installs);
   type `/delegate` whenever you want to switch that session into coordinator/worker mode.

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
