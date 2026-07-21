#!/usr/bin/env bash
# Claude Code status line script

input=$(cat)

# --- Context window tokens + percentage ---
used=$(echo "$input" | jq -r '.context_window.total_input_tokens // 0')
pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

fmt=$(awk -v n="$used" 'BEGIN{
  if (n>=1000000) printf "%.1fM", n/1000000
  else if (n>=1000) printf "%.0fk", n/1000
  else printf "%d", n
}')

if [ -n "$pct" ]; then
  ctx=$(printf '\033[1;38;2;217;119;87m%s\033[0m (%.0f%%)' "$fmt" "$pct")
else
  ctx=$(printf '\033[1;38;2;217;119;87m%s\033[0m' "$fmt")
fi

# --- 5-hour limit ---
five_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
five_resets=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')

five_str=""
if [ -n "$five_pct" ] && [ -n "$five_resets" ]; then
  now=$(date +%s)
  secs_left=$(( five_resets - now ))
  if [ "$secs_left" -lt 0 ]; then secs_left=0; fi
  h_left=$(( secs_left / 3600 ))
  m_left=$(( (secs_left % 3600) / 60 ))
  five_str=$(printf "Usage 5h: \033[1;38;2;217;119;87m%.0f%% used\033[0m · %d:%02dh left" "$five_pct" "$h_left" "$m_left")
fi

# --- Weekly limit ---
week_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
week_resets=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')

week_str=""
if [ -n "$week_pct" ] && [ -n "$week_resets" ]; then
  reset_day=$(date -r "$week_resets" "+%A")
  reset_time=$(date -r "$week_resets" "+%-H:%M")
  week_str=$(printf "Weekly: \033[1;38;2;217;119;87m%.0f%% used\033[0m · resets %s %s" "$week_pct" "$reset_day" "$reset_time")
fi

# --- Assemble output ---
out="$ctx"
if [ -n "$five_str" ]; then
  out="$out · $five_str"
fi
if [ -n "$week_str" ]; then
  out="$out · $week_str"
fi

printf '%s' "$out"
