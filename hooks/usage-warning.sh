#!/usr/bin/env bash
# usage-warning.sh — push a Claude usage-limit warning into the agent's context
# so the coordinator never has to remember to poll ~/.claude/usage-snapshot.json.
#
# Wire it to PostToolUse (fires every agentic turn, including autonomous /loop
# and ScheduleWakeup wakes) and SessionStart (fires on resume). It stays silent
# until the worst Claude usage window crosses 90%, then injects a warning as
# additionalContext. It only reads the snapshot statusline-command.sh already
# writes — no API calls, no state. See README "Automatic usage-limit warning".
#
# Test with a fixture instead of the live snapshot via CLAUDE_USAGE_SNAPSHOT.

set -euo pipefail

snap="${CLAUDE_USAGE_SNAPSHOT:-${HOME}/.claude/usage-snapshot.json}"
[ -r "$snap" ] || exit 0

# Attribute the injected context to the event Claude actually sent.
payload=$(cat 2>/dev/null || true)
event=$(printf '%s' "$payload" | jq -r '.hook_event_name // empty' 2>/dev/null || true)
case "$event" in
  SessionStart|PostToolUse|PostToolUseFailure|PreToolUse|PostToolBatch|Stop) ;;
  *) event="PostToolUse" ;;
esac

msg=$(jq -r '
  def p(w): (w.used_percentage // 0);
  (if p(.five_hour) >= p(.seven_day)
     then {name:"5-hour", pct:p(.five_hour), reset:(.five_hour.resets_at // 0)}
     else {name:"weekly", pct:p(.seven_day), reset:(.seven_day.resets_at // 0)} end) as $w
  | ([($w.reset - now), 0] | max) as $left
  | ([$left + 60, 3600] | min) as $delay
  | if $w.pct >= 95 then
      "⛔ BUDGET STOP — Claude \($w.name) usage window at \($w.pct|floor)% used (resets in \(($left/60)|floor) min). Per CLAUDE.md Budget-aware pacing: stop starting new work; checkpoint state in one sentence; call ScheduleWakeup(delaySeconds=\($delay|floor)) with a self-contained resume prompt; tell the user the \($w.name) window tripped at \($w.pct|floor)%. Then enter the Auto-resume loop — do not start new heavy work."
    elif $w.pct >= 90 then
      "⚠️ Budget heads-up — Claude \($w.name) usage window at \($w.pct|floor)% used. Finish the current step and do not start a heavy new chunk; at 95% you must pause and arm a ScheduleWakeup (CLAUDE.md Budget-aware pacing). The snapshot can lag, so treat this as your runway."
    else empty end
' "$snap" 2>/dev/null || true)

[ -n "$msg" ] || exit 0

jq -cn --arg e "$event" --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
