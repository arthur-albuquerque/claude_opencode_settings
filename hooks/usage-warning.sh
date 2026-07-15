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
# User override: if ~/.claude/usage-override holds a unix epoch in the future,
# the user has explicitly authorized continuing past 95% — the ⛔ stop
# directive is downgraded to a one-line reminder (keep a dead-man's-switch
# wakeup armed) and the ≥90% heads-up is suppressed. The file is written by
# the agent only on an explicit user request (see CLAUDE.md "User override")
# and is deleted here once expired, restoring the default stop behavior.
#
# Test with fixtures instead of live files via CLAUDE_USAGE_SNAPSHOT and
# CLAUDE_USAGE_OVERRIDE.

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

# Explicit user override: file holds the epoch it expires at (normally the
# tripped window's resets_at). Expired or malformed files are removed.
ovr_file="${CLAUDE_USAGE_OVERRIDE:-${HOME}/.claude/usage-override}"
ovr_exp=0
if [ -r "$ovr_file" ]; then
  ovr_exp=$(head -1 "$ovr_file" | tr -cd '0-9')
  ovr_exp=${ovr_exp:-0}
  if [ "$ovr_exp" -le "$(date +%s)" ]; then
    rm -f "$ovr_file"
    ovr_exp=0
  fi
fi

msg=$(jq -r --argjson ovr "$ovr_exp" '
  def p(w): (w.used_percentage // 0);
  (if p(.five_hour) >= p(.seven_day)
     then {name:"5-hour", pct:p(.five_hour), reset:(.five_hour.resets_at // 0)}
     else {name:"weekly", pct:p(.seven_day), reset:(.seven_day.resets_at // 0)} end) as $w
  | ([($w.reset - now), 0] | max) as $left
  | ([$left + 60, 3600] | min) as $delay
  | if ($ovr > now) then
      if $w.pct >= 95 then
        "🔓 BUDGET OVERRIDE ACTIVE — Claude \($w.name) window at \($w.pct|floor)% but the user explicitly authorized continuing (override expires in \((($ovr - now)/60)|floor) min). Keep working. Keep exactly one dead-man ScheduleWakeup armed (delaySeconds=\($delay|floor)) — the override silences this hook, not the hard limit; a hard trip still locks the session and only a pre-armed wakeup restarts it. Do not renew the override without a fresh explicit user request."
      else empty end
    elif $w.pct >= 95 then
      "⛔ BUDGET STOP — Claude \($w.name) usage window at \($w.pct|floor)% used (resets in \(($left/60)|floor) min). Per CLAUDE.md Budget-aware pacing: stop starting new work; checkpoint state in one sentence; call ScheduleWakeup(delaySeconds=\($delay|floor)) with a self-contained resume prompt; tell the user the \($w.name) window tripped at \($w.pct|floor)%. Then enter the Auto-resume loop — do not start new heavy work. (Default behavior — the user can lift it by explicitly asking to continue regardless of usage; see CLAUDE.md \"User override\".)"
    elif $w.pct >= 90 then
      "⚠️ Budget heads-up — Claude \($w.name) usage window at \($w.pct|floor)% used. Finish the current step and do not start a heavy new chunk; at 95% you must pause and arm a ScheduleWakeup (CLAUDE.md Budget-aware pacing). The snapshot can lag, so treat this as your runway."
    else empty end
' "$snap" 2>/dev/null || true)

[ -n "$msg" ] || exit 0

jq -cn --arg e "$event" --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
