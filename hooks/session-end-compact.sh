#!/bin/bash
# SessionEnd hook: run decant partial compaction if context was high.
# Runs when user exits Claude. Must not block terminal.
# Always exits 0 (hooks must never show errors in Claude Code).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/platform.sh"
source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tokens.sh"

HOOK_INPUT=$(cat)

# Skip /clear exits
REASON=$(echo "$HOOK_INPUT" | jq -r '.reason // empty' 2>/dev/null)
if [[ "$REASON" == "clear" ]]; then
  exit 0
fi

CWD=$(echo "$HOOK_INPUT" | jq -r '.cwd // empty' 2>/dev/null)
config_load "$CWD"

# Check decant is installed
DECANT_BIN=$(config_decant_bin)
if [[ ! -x "$DECANT_BIN" ]]; then
  exit 0
fi

TRANSCRIPT_PATH=$(tokens_resolve_transcript "$HOOK_INPUT") || exit 0

# Guard: already compacted by decant
if tokens_has_summary_record "$TRANSCRIPT_PATH"; then
  exit 0
fi

# Guard: too few turns
MIN_TURNS=$(config_get '.compaction.min_turns')
USER_TURNS=$(tokens_count_user_turns "$TRANSCRIPT_PATH")
if [[ "$USER_TURNS" -lt "$MIN_TURNS" ]] 2>/dev/null; then
  exit 0
fi

# Guard: session too young
MIN_AGE=$(config_get '.compaction.min_session_age_minutes')
SESSION_AGE=$(tokens_session_age_minutes "$TRANSCRIPT_PATH")
if [[ "$SESSION_AGE" -lt "$MIN_AGE" ]] 2>/dev/null; then
  exit 0
fi

# Guard: context below threshold
TOKENS=$(tokens_get_latest "$TRANSCRIPT_PATH")
COMPACT_THRESHOLD=$(config_threshold compact)
if [[ -z "$TOKENS" ]] || [[ "$TOKENS" -eq 0 ]] 2>/dev/null || [[ "$TOKENS" -lt "$COMPACT_THRESHOLD" ]] 2>/dev/null; then
  exit 0
fi

# Auto-detect keep_last
KEEP_LAST=$(config_get '.compaction.keep_last')
if [[ "$KEEP_LAST" -ge "$USER_TURNS" ]] 2>/dev/null; then
  KEEP_LAST=$((USER_TURNS > 1 ? USER_TURNS - 1 : 1))
fi

# Lock file to prevent concurrent runs
LOCK_FILE="/tmp/auto-compact-$(platform_md5 "$TRANSCRIPT_PATH").lock"
if [[ -f "$LOCK_FILE" ]]; then
  LOCK_PID=$(cat "$LOCK_FILE" 2>/dev/null)
  if kill -0 "$LOCK_PID" 2>/dev/null; then
    exit 0
  fi
  rm -f "$LOCK_FILE"
fi

# Dry run check
DRY_RUN=$(config_get '.compaction.dry_run')
if [[ "$DRY_RUN" == "true" ]]; then
  WINDOW=$(config_get '.context_window_tokens')
  PCT=$((TOKENS * 100 / WINDOW))
  echo "[auto-compact] DRY RUN: Would compact session (~${PCT}%, ${USER_TURNS} turns, keep last ${KEEP_LAST})" >&2
  exit 0
fi

# Log rotation
LOG_DIR=$(config_log_dir)
mkdir -p "$LOG_DIR" 2>/dev/null
MAX_FILES=$(config_get '.logging.max_files')
if [[ -d "$LOG_DIR" ]]; then
  ls -t "$LOG_DIR"/*.log 2>/dev/null | tail -n +$((MAX_FILES)) | xargs rm -f 2>/dev/null || true
fi

# Build and run decant
MODEL=$(config_get '.compaction.model')
STRIP=$(config_get '.compaction.strip_noise')
LOG_FILE="$LOG_DIR/compact-$(date +%Y%m%d-%H%M%S).log"

NOTIFY_ENABLED=$(config_get '.notifications.enabled')
NOTIFY_COMPACT=$(config_get '.notifications.on_compaction')

nohup bash -c "
  echo \$\$ > '$LOCK_FILE'
  trap 'rm -f \"$LOCK_FILE\"' EXIT
  '$DECANT_BIN' compact '$TRANSCRIPT_PATH' --last $KEEP_LAST --model '$MODEL' $([ \"$STRIP\" = true ] && echo --strip) 2>&1
  EXIT_CODE=\$?
  if [[ \$EXIT_CODE -eq 0 ]] && [[ '$NOTIFY_ENABLED' == 'true' ]] && [[ '$NOTIFY_COMPACT' == 'true' ]]; then
    $(if [[ "$__PLATFORM" == "macos" ]]; then
        echo "osascript -e 'display notification \"Session partially compacted (kept last $KEEP_LAST turns)\" with title \"Claude Auto-Compact\"' 2>/dev/null || true"
      else
        echo "notify-send 'Claude Auto-Compact' 'Session partially compacted (kept last $KEEP_LAST turns)' 2>/dev/null || true"
      fi)
  fi
" > "$LOG_FILE" 2>&1 &

exit 0
