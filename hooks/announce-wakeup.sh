#!/usr/bin/env bash
# announce-wakeup.sh — force the agent to tell the user about every ScheduleWakeup.
#
# Why it exists: an armed wakeup is invisible to the user. In real sessions the
# agent would pause on a budget stop, arm its auto-resume wakeup, and end the
# turn silently — to the user the session just looked dead until they asked.
# This hook fires on PostToolUse with matcher "ScheduleWakeup", computes the
# exact wall-clock fire time from the tool input, and injects a directive that
# the agent's final user-visible message MUST announce the wakeup: fire time,
# reason, and what happens on wake. Stopping a wakeup loop must be announced too.
#
# It reads only the hook payload on stdin — no snapshot, no API calls, no state.
# Test: printf '{"tool_name":"ScheduleWakeup","tool_input":{"delaySeconds":750,"reason":"waiting for usage window reset"}}' | hooks/announce-wakeup.sh

set -euo pipefail

payload=$(cat 2>/dev/null || true)
[ -n "$payload" ] || exit 0

tool=$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null || true)
[ "$tool" = "ScheduleWakeup" ] || exit 0

stop=$(printf '%s' "$payload" | jq -r '.tool_input.stop // false' 2>/dev/null || echo false)

if [ "$stop" = "true" ]; then
  msg="📢 WAKEUP LOOP STOPPED — you just cancelled the scheduled wakeup. REQUIRED: your final user-visible message this turn must say plainly that the wakeup loop has ended and no further automatic resumes will fire. Never end the turn silently."
else
  delay=$(printf '%s' "$payload" | jq -r '.tool_input.delaySeconds // empty' 2>/dev/null || true)
  delay=${delay%%.*}
  case "$delay" in ''|*[!0-9]*) delay=3600 ;; esac
  # Mirror the runtime's clamp so the announced time matches what actually fires.
  [ "$delay" -lt 60 ] && delay=60
  [ "$delay" -gt 3600 ] && delay=3600

  reason=$(printf '%s' "$payload" | jq -r '.tool_input.reason // "none given"' 2>/dev/null || echo "none given")
  fire=$(( $(date +%s) + delay ))
  # macOS date -r, then GNU date -d.
  fire_at=$(date -r "$fire" '+%H:%M:%S' 2>/dev/null || date -d "@$fire" '+%H:%M:%S' 2>/dev/null || echo "unknown")
  mins=$(( (delay + 30) / 60 ))

  msg="📢 WAKEUP ARMED — fires at ${fire_at} local time (~${mins} min from now). Reason recorded: ${reason}. REQUIRED: your final user-visible message this turn MUST state, in plain language: (1) that a wakeup is armed and the session will pause and resume itself, (2) the exact fire time ${fire_at} and roughly how far away that is, (3) why the wakeup exists, and (4) what you will do when it fires. The user cannot see tool calls — a turn that arms or refreshes a wakeup and ends without announcing it looks like a dead session. Never end such a turn silently or with only tool output."
fi

jq -cn --arg m "$msg" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $m}}'
