#!/usr/bin/env bash
# inject-budget-doctrine.sh — SessionStart hook that loads CLAUDE.md (the
# always-on budget-pacing doctrine) into the agent's context.
#
# Why it exists: a plugin's root CLAUDE.md is NOT loaded as project context by
# Claude Code, so when this repo is installed as a plugin, this hook is how the
# doctrine reaches the agent. Manual (non-plugin) installs copy CLAUDE.md to
# ~/.claude/CLAUDE.md instead and never wire this hook.

set -euo pipefail

# Skip when the user already installed the doctrine manually — avoid injecting
# the same text twice.
# (matches the `# …(Claude usage limit)` heading here and main's `## Budget-aware pacing`)
grep -qs '# Budget-aware pacing' "${HOME}/.claude/CLAUDE.md" && exit 0

doctrine="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}/CLAUDE.md"
[ -r "$doctrine" ] || exit 0

jq -cn --rawfile m "$doctrine" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $m}}'
