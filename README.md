# Claude Code × OpenCode Go — coordinator/worker settings

Global Claude Code configuration for people who run **Claude Code** (Fable 5 / Opus) alongside an
**[OpenCode Go](https://opencode.ai)** subscription. It turns Claude into a *coordinator* that spends
its expensive tokens on judgment — diagnosis, task decomposition, code review, verification — while
delegating the actual typing of code to cheap OpenCode Go models invoked via the `opencode` CLI from
the same session.

The goal: long, productive Claude sessions that don't burn through usage limits, because the bulk
token spend (writing code) happens on a flat-rate $12/5h worker plan instead of on Claude.

## What's in here

| File | Installs to | Purpose |
|------|-------------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | The whole system prompt: delegation rules, model table, budget pacing, auto-resume |
| `scripts/opencode-go-usage.py` | `~/.claude/scripts/opencode-go-usage.py` | OpenCode Go budget check (authoritative gateway blocked-state probe) |
| `opencode.worker-agent.example.json` | merge into `~/.config/opencode/opencode.json` | The `worker` agent definition that lets `opencode run` edit files non-interactively |

## Features

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
- **Budget-aware pacing.** Two budgets, two checks: `ccusage` for the Claude window,
  `opencode-go-usage.py` for the worker plan. The script probes the Go gateway with a 1-token
  request (blocked requests are rejected before billing, so probing is free) and reports
  blocked-state + reset time authoritatively — the only budget signal (there is no key-based
  percent-used API, so the doctrine runs at full tier until the gateway blocks).
  Rules cover wave sizing and never silently dropping work.
- **Auto-resume loop.** When a long autonomous job pauses near a usage limit, the session
  schedules its own wakeups (chained hourly `ScheduleWakeup` calls, since resets can be hours
  out), re-checks both budgets on each wake with a minimal two-command turn, and resumes the
  remaining plan the moment a window clears — no human restart needed.
- **Visualization default.** Plot-drawing code (especially R/ggplot2) is routed through a
  data-viz skill's defaults, with the relevant rules embedded verbatim in worker prompts.

## Setup

1. **Prerequisites:** [Claude Code](https://claude.com/claude-code), the
   [opencode CLI](https://opencode.ai) with an OpenCode Go subscription (run `/connect` inside
   opencode once so `~/.local/share/opencode/auth.json` holds your key), Node (for
   `npx ccusage`), and Python 3.
2. Copy `CLAUDE.md` to `~/.claude/CLAUDE.md` (or append to yours).
3. Copy `scripts/opencode-go-usage.py` to `~/.claude/scripts/`.
4. Merge the `agent.worker` block from `opencode.worker-agent.example.json` into your
   `~/.config/opencode/opencode.json`. Without it, `opencode run` auto-rejects file edits and
   delegation silently fails.
5. Start a Claude Code session anywhere — the global `CLAUDE.md` applies to every project.

## Caveats

- The model table (names, pricing, request quotas) reflects OpenCode Go's catalog as of
  **July 2026**; re-rank when the catalog changes.
- Budget figures assume the $12/5h ($30/wk, $60/mo) Go plan — adjust the numbers in `CLAUDE.md`
  and the script's docstring if yours differs.
- The auto-resume loop only works while the Claude Code session stays open on an awake machine
  (`caffeinate -is` for overnight runs on macOS).
- `opencode-go-usage.py` reports only the authoritative gateway blocked-state (there is no
  key-based percent-used API for OpenCode Go); it is the sole budget signal.
