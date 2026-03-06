#!/bin/bash
# compact-runner.sh — Runs compaction with validation and iterative budget targeting.
# Called by session-end-compact.sh via nohup. Not meant to be called directly.
#
# Arguments (passed as env vars):
#   DECANT_BIN, TRANSCRIPT_PATH, MODEL, STRIP, KEEP_LAST,
#   BEFORE_SIZE, TARGET_PCT, MAX_ROUNDS, BOUNDARY_DESC,
#   BOUNDARY_MODE (last|topic), BOUNDARY_TOPIC, BOUNDARY_LAST,
#   SESSION_ID, LOG_DIR, LOCK_FILE,
#   NOTIFY_ENABLED, NOTIFY_COMPACT

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/platform.sh"

validate_jsonl() {
  local path="$1"
  if [[ ! -s "$path" ]]; then
    echo "VALIDATION FAILED: session file is empty"
    return 1
  fi
  if ! head -1 "$path" | jq empty 2>/dev/null; then
    echo "VALIDATION FAILED: first line is not valid JSON"
    return 1
  fi
  if ! tail -1 "$path" | jq empty 2>/dev/null; then
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

build_decant_cmd() {
  local keep="$1"
  CMD=("$DECANT_BIN" compact "$TRANSCRIPT_PATH")
  if [[ "$BOUNDARY_MODE" == "topic" ]] && [[ "$keep" == "$BOUNDARY_LAST" ]]; then
    CMD+=(--topic "$BOUNDARY_TOPIC")
  else
    CMD+=(--last "$keep")
  fi
  CMD+=(--model "$MODEL")
  if [[ "$STRIP" == "true" ]]; then
    CMD+=(--strip)
  fi
}

append_history() {
  local after_size="$1" rounds="$2" duration="$3"
  local history_file="${LOG_DIR}/history.jsonl"
  jq -n \
    --arg sid "${SESSION_ID:-unknown}" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg mode "$BOUNDARY_MODE" \
    --arg topic "${BOUNDARY_TOPIC:-}" \
    --arg desc "$BOUNDARY_DESC" \
    --argjson last "${BOUNDARY_LAST:-0}" \
    --argjson before "${BEFORE_SIZE:-0}" \
    --argjson after "$after_size" \
    --argjson rounds "$rounds" \
    --argjson duration "$duration" \
    '{session_id: $sid, timestamp: $ts, strategy: {mode: $mode, topic: $topic, last: $last, description: $desc}, before_bytes: $before, after_bytes: $after, rounds: $rounds, duration_seconds: $duration}' \
    >> "$history_file" 2>/dev/null || true
}

# --- Main ---

START_TIME=$(date +%s)
ORIGINAL_SIZE="$BEFORE_SIZE"
TARGET_SIZE=$((ORIGINAL_SIZE * TARGET_PCT / 100))

echo "Strategy: $BOUNDARY_DESC"
echo "Pre-compaction: $KEEP_LAST keep, $BEFORE_SIZE bytes, target: <$TARGET_SIZE bytes"
echo ""

ROUND=1
CURRENT_KEEP="$BOUNDARY_LAST"

while [[ "$ROUND" -le "$MAX_ROUNDS" ]]; do
  echo "=== Round $ROUND / $MAX_ROUNDS (keep_last=$CURRENT_KEEP) ==="

  build_decant_cmd "$CURRENT_KEEP"
  "${CMD[@]}" 2>&1
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

  if [[ "$AFTER_SIZE" -le "$TARGET_SIZE" ]]; then
    echo "Target reached."
    break
  fi

  ROUND=$((ROUND + 1))
  if [[ "$ROUND" -gt "$MAX_ROUNDS" ]]; then
    echo "Max rounds reached. File still above target but stopping."
    break
  fi

  CURRENT_KEEP=$((CURRENT_KEEP / 2))
  if [[ "$CURRENT_KEEP" -lt 1 ]]; then
    CURRENT_KEEP=1
  fi
  BEFORE_SIZE="$AFTER_SIZE"
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
FINAL_SIZE=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')

echo ""
echo "Compaction complete. Duration: ${DURATION}s"

append_history "$FINAL_SIZE" "$((ROUND > MAX_ROUNDS ? MAX_ROUNDS : ROUND))" "$DURATION"

if [[ "$NOTIFY_ENABLED" == "true" ]] && [[ "$NOTIFY_COMPACT" == "true" ]]; then
  platform_notify "Claude Auto-Compact" "Session partially compacted ($BOUNDARY_DESC)"
fi
