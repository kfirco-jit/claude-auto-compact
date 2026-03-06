#!/bin/bash
# compact-runner.sh — Runs compaction with validation and iterative budget targeting.
# Called by session-end-compact.sh via nohup. Not meant to be called directly.
#
# Arguments (passed as env vars):
#   DECANT_BIN, TRANSCRIPT_PATH, BOUNDARY_ARGS, MODEL, STRIP,
#   KEEP_LAST, BEFORE_SIZE, TARGET_PCT, MAX_ROUNDS, PLATFORM,
#   NOTIFY_ENABLED, NOTIFY_COMPACT, BOUNDARY_DESC

validate_jsonl() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "VALIDATION FAILED: session file is empty"
    return 1
  fi
  if ! head -1 "$path" | python3 -c 'import sys,json; json.loads(sys.stdin.readline())' 2>/dev/null; then
    echo "VALIDATION FAILED: first line is not valid JSON"
    return 1
  fi
  if ! tail -1 "$path" | python3 -c 'import sys,json; json.loads(sys.stdin.readline())' 2>/dev/null; then
    echo "VALIDATION FAILED: last line is not valid JSON (truncated?)"
    return 1
  fi
  return 0
}

restore_backup() {
  if [[ -f "${TRANSCRIPT_PATH}.bak" ]]; then
    cp "${TRANSCRIPT_PATH}.bak" "$TRANSCRIPT_PATH"
    echo "Restored from backup"
  fi
}

send_notification() {
  local msg="$1"
  if [[ "$NOTIFY_ENABLED" != "true" ]] || [[ "$NOTIFY_COMPACT" != "true" ]]; then
    return
  fi
  if [[ "$PLATFORM" == "macos" ]]; then
    osascript -e "display notification \"$msg\" with title \"Claude Auto-Compact\"" 2>/dev/null || true
  else
    notify-send "Claude Auto-Compact" "$msg" 2>/dev/null || true
  fi
}

# --- Main ---

echo "Strategy: $BOUNDARY_DESC"
echo "Pre-compaction: $KEEP_LAST keep, $BEFORE_SIZE bytes"
echo ""

TARGET_SIZE=$((BEFORE_SIZE * TARGET_PCT / 100))
ROUND=1
CURRENT_ARGS="$BOUNDARY_ARGS"
CURRENT_KEEP="$KEEP_LAST"

while [[ "$ROUND" -le "$MAX_ROUNDS" ]]; do
  echo "=== Round $ROUND / $MAX_ROUNDS (keep_last=$CURRENT_KEEP) ==="

  STRIP_FLAG=""
  if [[ "$STRIP" == "true" ]]; then
    STRIP_FLAG="--strip"
  fi

  eval "'$DECANT_BIN' compact '$TRANSCRIPT_PATH' $CURRENT_ARGS --model '$MODEL' $STRIP_FLAG" 2>&1
  EXIT_CODE=$?

  if [[ $EXIT_CODE -ne 0 ]]; then
    echo "Decant failed with exit code $EXIT_CODE"
    restore_backup
    exit 1
  fi

  if ! validate_jsonl "$TRANSCRIPT_PATH"; then
    restore_backup
    exit 1
  fi

  AFTER_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
  echo "Round $ROUND done. Size: $BEFORE_SIZE -> $AFTER_SIZE bytes (target: <$TARGET_SIZE)"

  # Check if we hit target
  if [[ "$AFTER_SIZE" -le "$TARGET_SIZE" ]]; then
    echo "Target reached."
    break
  fi

  # Prepare next round: halve keep_last, switch to --last mode
  ROUND=$((ROUND + 1))
  if [[ "$ROUND" -gt "$MAX_ROUNDS" ]]; then
    echo "Max rounds reached. File still above target but stopping."
    break
  fi

  CURRENT_KEEP=$((CURRENT_KEEP / 2))
  if [[ "$CURRENT_KEEP" -lt 1 ]]; then
    CURRENT_KEEP=1
  fi
  CURRENT_ARGS="--last $CURRENT_KEEP"
  BEFORE_SIZE="$AFTER_SIZE"
  TARGET_SIZE=$((AFTER_SIZE * TARGET_PCT / 100))
done

echo ""
echo "Compaction complete."
send_notification "Session partially compacted ($BOUNDARY_DESC)"
