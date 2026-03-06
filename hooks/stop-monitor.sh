#!/bin/bash
# Stop hook: monitor context usage and warn the user.
# Runs after every Claude response — must be FAST.
# Always exits 0 (hooks must never show errors in Claude Code).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/platform.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tokens.sh"

HOOK_INPUT=$(cat)

# Parse all fields from hook input in a single jq call
read -r CWD SESSION_ID < <(
  echo "$HOOK_INPUT" | jq -r '[(.cwd // ""), (.session_id // "")] | @tsv' 2>/dev/null
)

config_load "$CWD"
config_validate 2>/dev/null || true

TRANSCRIPT_PATH=$(tokens_resolve_transcript "$HOOK_INPUT") || exit 0

TOKENS=$(tokens_get_latest "$TRANSCRIPT_PATH")

if [[ -z "$TOKENS" ]] || [[ "$TOKENS" -eq 0 ]] 2>/dev/null; then
  exit 0
fi

WINDOW=$(config_get '.context_window_tokens')
URGENT=$(config_threshold urgent)
WARN=$(config_threshold warn)
PCT=$((TOKENS * 100 / WINDOW))

MSG=""

# Show compaction stats once per session (on first response after resume)
if [[ -n "$SESSION_ID" ]]; then
  STATS_MARKER="/tmp/auto-compact-stats-${SESSION_ID}"
  if tokens_has_summary_record "$TRANSCRIPT_PATH" && [[ ! -f "$STATS_MARKER" ]]; then
    touch "$STATS_MARKER" 2>/dev/null
    SUMMARY_LEN=$(tokens_summary_length "$TRANSCRIPT_PATH")
    TOTAL_TURNS=$(tokens_count_user_turns "$TRANSCRIPT_PATH")
    POST_TURNS=$(tokens_count_post_summary_turns "$TRANSCRIPT_PATH")
    SUMMARIZED=$((TOTAL_TURNS - POST_TURNS))
    MSG="Resumed compacted session: ${SUMMARIZED} turns summarized (${SUMMARY_LEN} chars), ${POST_TURNS} turns kept verbatim."
  fi
fi

# Context usage warnings (append to stats message if present)
if [[ "$TOKENS" -ge "$URGENT" ]] 2>/dev/null; then
  RESUME_CMD="claude --resume ${SESSION_ID}"
  if [[ -n "$MSG" ]]; then
    MSG="$MSG | Context at ~${PCT}%. Exit and resume: ${RESUME_CMD}"
  else
    MSG="Context at ~${PCT}% (${TOKENS} tokens). Exit and resume: ${RESUME_CMD}"
  fi
  NOTIFY_ENABLED=$(config_get '.notifications.enabled')
  NOTIFY_WARN=$(config_get '.notifications.on_warning')
  if [[ "$NOTIFY_ENABLED" == "true" ]] && [[ "$NOTIFY_WARN" == "true" ]]; then
    platform_notify "Claude Auto-Compact" "Context at ${PCT}% — exit now for partial compaction"
  fi
elif [[ "$TOKENS" -ge "$WARN" ]] 2>/dev/null; then
  if [[ -n "$MSG" ]]; then
    MSG="$MSG | Context at ~${PCT}%"
  else
    MSG="Context at ~${PCT}%"
  fi
fi

if [[ -n "$MSG" ]]; then
  jq -n --arg msg "$MSG" '{"systemMessage": $msg}'
fi

exit 0
