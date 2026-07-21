# Claude Code × OpenCode Go — coordinator/worker settings (skill edition)

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

## How this branch differs from `global`

This (`framework-as-skill`) is the repo's **default branch** and the recommended install: it is
packaged as the `opencode-coordinator` **Claude Code plugin**, so `/plugin marketplace add
arthur-albuquerque/claude_opencode_settings` resolves here.

On the [`global`](https://github.com/arthur-albuquerque/claude_opencode_settings/tree/global) branch
the **entire** framework lives in the global `~/.claude/CLAUDE.md`, so every Claude session — even
one where you never intend to delegate — is forced to load the coordinator/worker rules, the model
table, and the delegation contract. `global` is deliberately **not** packaged as a plugin (a second
plugin carrying the same doctrine would double-inject context if both were enabled); it installs by
copying files.

On this branch the whole framework lives in `skills/delegate/SKILL.md`, a **user-invoked skill**
(`disable-model-invocation: true`): you opt into it by typing `/delegate`, and it loads for that
session only. A plain, non-delegating session pays zero context load for it.

## What's in here

The repo root **is** the plugin. Everything below the first group installs automatically when the
plugin is enabled; the last two rows are the irreducible manual pieces a plugin cannot ship.

| File | Role in the plugin | Purpose |
|------|--------------------|---------|
| `.claude-plugin/plugin.json` | manifest | Plugin identity (`opencode-coordinator`); `.claude-plugin/marketplace.json` makes this repo installable as its own marketplace |
| `skills/delegate/SKILL.md` | skill | The opt-in coordinator/worker framework: delegation rules, model table, prompt contract, QA loop, worker budget. Invoke with `/delegate` |
| `bin/opencode-go-usage.py` | on `PATH` while enabled | OpenCode Go budget check (authoritative gateway blocked-state probe) |
| `statusline-command.sh` | **manual** → `~/.claude/statusline-command.sh` | Optional status line script showing context-window tokens and 5-hour/weekly usage percentages |
| `opencode.worker-agent.example.json` | **manual** → merge into `~/.config/opencode/opencode.json` | The `worker` agent definition that lets `opencode run` edit files non-interactively. Lives in opencode's config, outside Claude Code's reach |

## What the framework does (`delegate` skill — invoke with `/delegate`)

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
  reports blocked-state + reset time authoritatively — the only worker-budget signal.

## Setup

1. **Prerequisites:** [Claude Code](https://claude.com/claude-code), the
   [opencode CLI](https://opencode.ai) with an OpenCode Go subscription (run `/connect` inside
   opencode once so `~/.local/share/opencode/auth.json` holds your key), and Python 3.
2. **Install the plugin.** Inside Claude Code:

   ```text
   /plugin marketplace add arthur-albuquerque/claude_opencode_settings
   /plugin install opencode-coordinator@claude-opencode-settings
   ```

   (Or, from a local clone: `claude plugin marketplace add /path/to/claude_opencode_settings`,
   then the same install command.) This wires everything a plugin can carry:
   - the `delegate` skill — type `/delegate` to switch a session into coordinator/worker mode; it
     is `disable-model-invocation: true`, so it never activates unless you invoke it by name;
   - `opencode-go-usage.py` on the Bash `PATH`.

   Two pieces **cannot** ship in a plugin and stay manual: the status line (step 3, optional) and
   the opencode worker agent (step 4).

   <details>
   <summary>Manual install (no plugin)</summary>

   Copy `skills/delegate/SKILL.md` to `~/.claude/skills/delegate/SKILL.md`, and copy
   `bin/opencode-go-usage.py` to `~/.claude/scripts/opencode-go-usage.py`.
   </details>

3. *(Optional)* Copy `statusline-command.sh` to `~/.claude/statusline-command.sh` and wire it into
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

4. Merge the `agent.worker` block from `opencode.worker-agent.example.json` into your
   `~/.config/opencode/opencode.json`. Without it, `opencode run` auto-rejects file edits and
   delegation silently fails.
5. **Disable opencode's Claude Code compatibility.** OpenCode loads `~/.claude/CLAUDE.md` as a
   fallback instruction file by default. Because that file is written for Claude Code (the
   coordinator), letting opencode read it causes opencode sessions to inherit rules they should
   not execute, and breaks `opencode run` / direct opencode usage. Add this to your shell profile:

   ```bash
   echo 'export OPENCODE_DISABLE_CLAUDE_CODE=1' >> ~/.zshrc
   source ~/.zshrc
   ```

   There is no equivalent key in `opencode.json`; this is the only supported mechanism. If you
   want to keep `.claude/skills` available to opencode but only suppress the `CLAUDE.md` prompt
   fallback, use `OPENCODE_DISABLE_CLAUDE_CODE_PROMPT=1` instead.
6. Start a Claude Code session anywhere; type `/delegate` whenever you want to switch that session
   into coordinator/worker mode.

## Caveats

- The model table (names, pricing, request quotas) reflects OpenCode Go's catalog as of
  **July 2026**; re-rank when the catalog changes. It lives in `skills/delegate/SKILL.md`.
- Budget figures assume the $12/5h ($30/wk, $60/mo) Go plan — adjust the numbers in
  `skills/delegate/SKILL.md` (worker budget) and the script's docstring if yours differs.
- `opencode-go-usage.py` reports only the authoritative gateway blocked-state (there is no
  key-based percent-used API for OpenCode Go); it is the sole worker-budget signal.
- The `delegate` skill is user-invoked by design, so **you** are the one who has to remember it
  exists — that's the trade for it costing zero context load in sessions that don't need it.
