#!/bin/bash
# Stop hook: monitor context usage and warn the user.
# Runs after every Claude response — must be FAST.
# Always exits 0 (hooks must never show errors in Claude Code).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/platform.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tokens.sh"

HOOK_INPUT=$(cat)

CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
config_load "$CWD"

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
if [[ "$TOKENS" -ge "$URGENT" ]] 2>/dev/null; then
  MSG="Context at ~${PCT}% (${TOKENS} tokens). Exit now for partial compaction."
  NOTIFY_ENABLED=$(config_get '.notifications.enabled')
  NOTIFY_WARN=$(config_get '.notifications.on_warning')
  if [[ "$NOTIFY_ENABLED" == "true" ]] && [[ "$NOTIFY_WARN" == "true" ]]; then
    platform_notify "Claude Auto-Compact" "Context at ${PCT}% — exit now for partial compaction"
  fi
elif [[ "$TOKENS" -ge "$WARN" ]] 2>/dev/null; then
  MSG="Context at ~${PCT}%"
fi

if [[ -n "$MSG" ]]; then
  jq -n --arg msg "$MSG" '{"systemMessage": $msg}'
fi

exit 0
