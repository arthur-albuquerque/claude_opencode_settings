# Claude Code × OpenCode Go — coordinator/worker settings

> In short, this setup turns Claude Code into a coordinator that delegates coding work to cheap
> OpenCode Go workers and verifies every worker result before shipping it.
>
> The main goal is to spend expensive Claude tokens on judgment and cheap Go tokens on typing.

Global Claude Code configuration for people who run **Claude Code** (Fable 5 / Opus) alongside an
**[OpenCode Go](https://opencode.ai)** subscription. It turns Claude into a *coordinator* that spends
its expensive tokens on judgment — diagnosis, task decomposition, code review, verification — while
delegating the actual typing of code to cheap OpenCode Go models invoked via the `opencode` CLI from
the same session.

The goal: long, productive Claude sessions that don't burn through usage limits, because the bulk
token spend (writing code) happens on a flat-rate $12/5h worker plan instead of on Claude.

## How this branch differs from `global` and `framework-as-skill`

This is the `global-workflow` branch: the `global` architecture — the **entire** framework lives in
the global `~/.claude/CLAUDE.md`, always in context, nothing to invoke — **plus a workflow tier**
for multi-task jobs. A model-invocable skill, `skills/delegate-workflow/SKILL.md`, requires the
coordinator to route every batch of **3+ independent, non-overlapping tasks** through a deterministic
ultracode Workflow: cost-weighted worker concurrency (cheap models fan wide, expensive models stay
narrow), the escalation ladder encoded as a retry loop,
per-task QA by cheap Claude agents, and budget-interrupted runs that resume from cache
(`resumeFromRunId`). The coordinator keeps decomposition and final review, and launches
autonomously — installing the skill is your standing opt-in; the agent shows you the dispatched
task table for visibility rather than asking permission.

The skill lives outside `CLAUDE.md` because that's the only placement that works: Claude Code's
Workflow tool requires explicit opt-in, which a skill invocation can carry but global-instructions
prose cannot. `CLAUDE.md` holds a one-bullet pointer to the skill; the machinery loads only when a
qualifying job appears.

| Concern | `global` | `global-workflow` (this branch) | `framework-as-skill` |
|---------|----------|--------------------------------|----------------------|
| **Coordinator/worker delegation** — the split, model table, prompt contract, QA loop, worker budget | In `CLAUDE.md` — always loaded | In `CLAUDE.md` — always loaded | In `skills/delegate/SKILL.md`, **user-invoked** (`disable-model-invocation: true`) |
| **Workflow tier** — multi-task orchestration via ultracode Workflows | — | `skills/delegate-workflow/SKILL.md`, **model-invocable** (agent invokes autonomously) | — |

Pick `global` for the simplest install with direct delegation only. Pick **this branch** if you
also run batch-shaped jobs where deterministic retries and budget-resumable runs pay for
themselves. Pick `framework-as-skill` if you want plain, non-delegating sessions to pay
**zero** context load for the coordinator/worker rules and to opt into them on demand.

`framework-as-skill` is also packaged as a **Claude Code plugin** (`opencode-coordinator`) and is
the repo's **default branch**, so the plugin installs directly from GitHub:

```text
/plugin marketplace add arthur-albuquerque/claude_opencode_settings
/plugin install opencode-coordinator@claude-opencode-settings
```

This `global-workflow` branch deliberately stays plugin-free — a second plugin carrying the same
doctrine would double-inject context if both were ever enabled. Install this branch by copying
files (Setup below), or use the plugin from `framework-as-skill` instead.

## What's in here

| File | Installs to | Purpose |
|------|-------------|---------|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` | The whole system prompt: delegation rules, model table, worker budget |
| `skills/delegate-workflow/` | `~/.claude/skills/delegate-workflow/` | Workflow tier: orchestrates 3+ independent tasks through an ultracode Workflow (cost-weighted concurrency, ladder retries, per-task QA, budget resume) |
| `statusline-command.sh` | `~/.claude/statusline-command.sh` | Optional status line script showing context-window tokens and 5-hour/weekly usage percentages |
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
- **Workflow tier for multi-task jobs.** For 3+ independent, non-overlapping tasks, the
  model-invocable `delegate-workflow` skill hands orchestration to a deterministic ultracode
  Workflow: thin haiku-pinned wrapper agents launch the opencode workers in isolated git worktrees
  under a cost-weighted concurrency budget — each in-flight worker holds a weight inverse to its
  model's cost, so cheap models fan wide (~8 flash) while expensive ones stay narrow (~2 glm) at
  the same spend rate — the escalation ladder runs as a retry loop with opencode session reuse
  (`-s`) on feedback attempts, cheap reviewer agents do first-pass QA, and a mid-run budget block
  freezes all launches; the run resumes later from cache (`resumeFromRunId`) instead
  of losing completed work. The coordinator still decomposes up front and reviews/merges at the
  end, and invokes the tier autonomously whenever a job qualifies — installing the skill is the
  standing authorization; the dispatched task table is reported, not proposed. The skill's
  wrapper prompts encode empirically verified harness mechanics (no background-and-wait inside
  workflow agents; detached `nohup` launch + `$SECONDS`-bounded waits for runs past the 10-minute
  foreground Bash cap; no `timeout` binary on macOS).
- **Worker-budget awareness.** The worker plan is checked with `opencode-go-usage.py`, which
  probes the Go gateway with a 1-token request (blocked requests are rejected before billing, so
  probing is free) and reports blocked-state + reset time authoritatively — the only budget signal
  (there is no key-based percent-used API, so the doctrine runs at full tier until the gateway
  blocks). Rules cover wave sizing and never silently dropping work.

## Setup

1. **Prerequisites:** [Claude Code](https://claude.com/claude-code), the
   [opencode CLI](https://opencode.ai) with an OpenCode Go subscription (run `/connect` inside
   opencode once so `~/.local/share/opencode/auth.json` holds your key), and Python 3.
2. Copy `CLAUDE.md` to `~/.claude/CLAUDE.md` (or append to yours).
3. Copy the workflow-tier skill: `cp -R skills/delegate-workflow ~/.claude/skills/`.
4. *(Optional)* Copy `statusline-command.sh` to `~/.claude/statusline-command.sh` and wire it into
   Claude Code. The easiest way is to run this inside Claude Code (it will update your
   `~/.claude/settings.json`):

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

5. Copy `scripts/opencode-go-usage.py` to `~/.claude/scripts/`.
6. Merge the `agent.worker` block from `opencode.worker-agent.example.json` into your
   `~/.config/opencode/opencode.json`. Without it, `opencode run` auto-rejects file edits and
   delegation silently fails.
7. **Disable opencode's Claude Code compatibility.** OpenCode loads `~/.claude/CLAUDE.md` as a
   fallback instruction file by default. Because that file is written for Claude Code (the
   coordinator), letting opencode read it causes opencode sessions to inherit coordinator rules
   they should not execute, and breaks `opencode run` / direct opencode usage. Add this to your
   shell profile:

   ```bash
   echo 'export OPENCODE_DISABLE_CLAUDE_CODE=1' >> ~/.zshrc
   source ~/.zshrc
   ```

   There is no equivalent key in `opencode.json`; this is the only supported mechanism. If you
   want to keep `.claude/skills` available to opencode but only suppress the `CLAUDE.md` prompt
   fallback, use `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` instead.
8. Start a Claude Code session anywhere — the global `CLAUDE.md` applies to every project.

## Caveats

- The model table (names, pricing, request quotas) reflects OpenCode Go's catalog as of
  **July 2026**; re-rank when the catalog changes.
- Budget figures assume the $12/5h ($30/wk, $60/mo) Go plan — adjust the numbers in `CLAUDE.md`
  and the script's docstring if yours differs.
- `opencode-go-usage.py` reports only the authoritative gateway blocked-state (there is no
  key-based percent-used API for OpenCode Go); it is the sole worker-budget signal.
