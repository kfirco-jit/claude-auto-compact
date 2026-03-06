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
config_validate 2>/dev/null || exit 0

# Check decant is installed
DECANT_BIN=$(config_decant_bin)
if [[ ! -x "$DECANT_BIN" ]]; then
  exit 0
fi

TRANSCRIPT_PATH=$(tokens_resolve_transcript "$HOOK_INPUT") || exit 0

# Guard: too few turns (use post-summary turns if already compacted)
MIN_TURNS=$(config_get '.compaction.min_turns')
if tokens_has_summary_record "$TRANSCRIPT_PATH"; then
  USER_TURNS=$(tokens_count_post_summary_turns "$TRANSCRIPT_PATH")
else
  USER_TURNS=$(tokens_count_user_turns "$TRANSCRIPT_PATH")
fi
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
STRATEGY=$(config_get '.compaction.strategy')
LOG_FILE="$LOG_DIR/compact-$(date +%Y%m%d-%H%M%S).log"

# Determine compaction boundary (--last N or --topic)
BOUNDARY_ARGS="--last $KEEP_LAST"
BOUNDARY_DESC="kept last $KEEP_LAST turns"
if [[ "$STRATEGY" == "auto" ]]; then
  DECANT_PYTHON="$(dirname "$DECANT_BIN")/../.venv/bin/python3"
  STRATEGY_SCRIPT="$SCRIPT_DIR/lib/strategy.py"
  if [[ -x "$DECANT_PYTHON" ]] && [[ -f "$STRATEGY_SCRIPT" ]]; then
    STRATEGY_RESULT=$("$DECANT_PYTHON" "$STRATEGY_SCRIPT" "$TRANSCRIPT_PATH" "$KEEP_LAST" 2>/dev/null) || true
    STRATEGY_MODE=$(echo "$STRATEGY_RESULT" | jq -r '.mode // empty' 2>/dev/null)
    STRATEGY_LAST=$(echo "$STRATEGY_RESULT" | jq -r '.last // empty' 2>/dev/null)
    # Update keep_last if haiku recommended a different value
    if [[ -n "$STRATEGY_LAST" ]] && [[ "$STRATEGY_LAST" -gt 0 ]] 2>/dev/null; then
      KEEP_LAST="$STRATEGY_LAST"
      BOUNDARY_ARGS="--last $KEEP_LAST"
      BOUNDARY_DESC="kept last $KEEP_LAST turns"
    fi
    if [[ "$STRATEGY_MODE" == "topic" ]]; then
      STRATEGY_TOPIC=$(echo "$STRATEGY_RESULT" | jq -r '.topic // empty' 2>/dev/null)
      if [[ -n "$STRATEGY_TOPIC" ]]; then
        BOUNDARY_ARGS="--topic '$STRATEGY_TOPIC'"
        BOUNDARY_DESC="topic: $STRATEGY_TOPIC (fallback: last $KEEP_LAST)"
      fi
    fi
  fi
fi

NOTIFY_ENABLED=$(config_get '.notifications.enabled')
NOTIFY_COMPACT=$(config_get '.notifications.on_compaction')
TARGET_PCT=$(config_get '.compaction.target_pct')
MAX_ROUNDS=$(config_get '.compaction.max_rounds')
BEFORE_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')

RUNNER="$SCRIPT_DIR/lib/compact-runner.sh"

nohup env \
  DECANT_BIN="$DECANT_BIN" \
  TRANSCRIPT_PATH="$TRANSCRIPT_PATH" \
  BOUNDARY_ARGS="$BOUNDARY_ARGS" \
  MODEL="$MODEL" \
  STRIP="$STRIP" \
  KEEP_LAST="$KEEP_LAST" \
  BEFORE_SIZE="$BEFORE_SIZE" \
  TARGET_PCT="${TARGET_PCT:-50}" \
  MAX_ROUNDS="${MAX_ROUNDS:-3}" \
  PLATFORM="$__PLATFORM" \
  NOTIFY_ENABLED="$NOTIFY_ENABLED" \
  NOTIFY_COMPACT="$NOTIFY_COMPACT" \
  BOUNDARY_DESC="$BOUNDARY_DESC" \
  LOCK_FILE="$LOCK_FILE" \
  bash -c "
    echo \$\$ > '$LOCK_FILE'
    trap 'rm -f \"$LOCK_FILE\"' EXIT
    bash '$RUNNER'
  " > "$LOG_FILE" 2>&1 &

exit 0
