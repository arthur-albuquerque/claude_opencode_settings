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
# User override — "continue regardless of usage":
#   Usage limits are per-account, so all of a machine's sessions cross 95% at
#   once. To let the user lift the stop in ONE session without unblocking the
#   others, the override flag is PER-SESSION: a file
#       ~/.claude/usage-override-<session_id>
#   whose contents is the unix epoch the override expires at (normally the
#   tripped window's resets_at). <session_id> is the firing session's id, taken
#   from the hook's stdin payload (== $CLAUDE_CODE_SESSION_ID). While that file
#   holds a future epoch, this session's ⛔ stop is downgraded to a one-line 🔓
#   reminder and its ≥90% heads-up is suppressed; other sessions are unaffected.
#   A suffix-less ~/.claude/usage-override is also honored as a deliberate
#   "all sessions" manual switch. Expired files are deleted on sight, so the
#   default stop behavior returns on its own (at the latest, at window reset).
#   The agent writes/removes these files only on an explicit user request and
#   removes the session file as soon as the authorized task finishes (see
#   CLAUDE.md "User override").
#
# Test with fixtures via CLAUDE_USAGE_SNAPSHOT (snapshot json),
# CLAUDE_OVERRIDE_DIR (dir holding the override files), and
# CLAUDE_CODE_SESSION_ID (the session id). CLAUDE_USAGE_OVERRIDE, if set,
# forces a single explicit override-file path and skips session resolution.

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

# Resolve the override expiry for THIS session. Candidate files, first match
# wins: the per-session file for the stdin session_id, the per-session file for
# $CLAUDE_CODE_SESSION_ID (belt-and-suspenders — normally the same id), then the
# suffix-less "all sessions" file. Expired candidates are deleted, not honored.
ovr_dir="${CLAUDE_OVERRIDE_DIR:-${HOME}/.claude}"
sid_stdin=$(printf '%s' "$payload" | jq -r '.session_id // empty' 2>/dev/null || true)
now_epoch=$(date +%s)

if [ -n "${CLAUDE_USAGE_OVERRIDE:-}" ]; then
  candidates="$CLAUDE_USAGE_OVERRIDE"
else
  candidates=""
  for sid in "$sid_stdin" "${CLAUDE_CODE_SESSION_ID:-}"; do
    [ -n "$sid" ] && candidates="$candidates ${ovr_dir}/usage-override-${sid}"
  done
  candidates="$candidates ${ovr_dir}/usage-override"
fi

ovr_exp=0
for f in $candidates; do
  [ -r "$f" ] || continue
  exp=$(head -1 "$f" 2>/dev/null | tr -cd '0-9')
  exp=${exp:-0}
  if [ "$exp" -le "$now_epoch" ]; then
    rm -f "$f"
    continue
  fi
  [ "$exp" -gt "$ovr_exp" ] && ovr_exp=$exp
done

msg=$(jq -r --argjson ovr "$ovr_exp" '
  def p(w): (w.used_percentage // 0);
  (if p(.five_hour) >= p(.seven_day)
     then {name:"5-hour", pct:p(.five_hour), reset:(.five_hour.resets_at // 0)}
     else {name:"weekly", pct:p(.seven_day), reset:(.seven_day.resets_at // 0)} end) as $w
  | ([($w.reset - now), 0] | max) as $left
  | ([$left + 60, 3600] | min) as $delay
  | if ($ovr > now) then
      if $w.pct >= 95 then
        "🔓 BUDGET OVERRIDE ACTIVE (this session only) — Claude \($w.name) window at \($w.pct|floor)% but the user explicitly authorized continuing (override expires in \((($ovr - now)/60)|floor) min). Keep working. Keep exactly one dead-man ScheduleWakeup armed (delaySeconds=\($delay|floor)) — the override silences this hook, not the hard limit; a hard trip still locks the session and only a pre-armed wakeup restarts it. Delete the override flag (rm -f ~/.claude/usage-override-$CLAUDE_CODE_SESSION_ID) the moment you finish the authorized task. Do not renew it without a fresh explicit user request."
      else empty end
    elif $w.pct >= 95 then
      "⛔ BUDGET STOP — Claude \($w.name) usage window at \($w.pct|floor)% used (resets in \(($left/60)|floor) min). Per CLAUDE.md Budget-aware pacing: stop starting new work; checkpoint state in one sentence; call ScheduleWakeup(delaySeconds=\($delay|floor)) with a self-contained resume prompt; tell the user the \($w.name) window tripped at \($w.pct|floor)%. Then enter the Auto-resume loop — do not start new heavy work. (Default behavior — the user can lift it for THIS session by explicitly asking to continue regardless of usage; see CLAUDE.md \"User override\".)"
    elif $w.pct >= 90 then
      "⚠️ Budget heads-up — Claude \($w.name) usage window at \($w.pct|floor)% used. Finish the current step and do not start a heavy new chunk; at 95% you must pause and arm a ScheduleWakeup (CLAUDE.md Budget-aware pacing). The snapshot can lag, so treat this as your runway."
    else empty end
' "$snap" 2>/dev/null || true)

[ -n "$msg" ] || exit 0

jq -cn --arg e "$event" --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: $e, additionalContext: $m}}'
