#!/bin/bash
# Shared strategy resolution logic.
# Sets: BOUNDARY_MODE, BOUNDARY_LAST, BOUNDARY_TOPIC, BOUNDARY_DESC, KEEP_LAST
# Requires: DECANT_BIN, KEEP_LAST, STRATEGY, TRANSCRIPT_PATH/session path

strategy_resolve() {
  local session_path="$1"
  local install_dir="$2"

  BOUNDARY_MODE="last"
  BOUNDARY_LAST="$KEEP_LAST"
  BOUNDARY_TOPIC=""
  BOUNDARY_DESC="kept last $KEEP_LAST turns"

  if [[ "$STRATEGY" != "auto" ]]; then
    return
  fi

  local decant_python strategy_script
  decant_python="$(dirname "$DECANT_BIN")/../.venv/bin/python3"
  strategy_script="$install_dir/hooks/lib/strategy.py"

  if [[ ! -x "$decant_python" ]] || [[ ! -f "$strategy_script" ]]; then
    return
  fi

  local strategy_result strategy_mode strategy_last
  strategy_result=$("$decant_python" "$strategy_script" "$session_path" "$KEEP_LAST" 2>/dev/null) || return
  strategy_mode=$(echo "$strategy_result" | jq -r '.mode // empty' 2>/dev/null)
  strategy_last=$(echo "$strategy_result" | jq -r '.last // empty' 2>/dev/null)

  if [[ -n "$strategy_last" ]] && [[ "$strategy_last" -gt 0 ]] 2>/dev/null; then
    KEEP_LAST="$strategy_last"
    BOUNDARY_LAST="$KEEP_LAST"
    BOUNDARY_DESC="kept last $KEEP_LAST turns"
  fi

  if [[ "$strategy_mode" == "topic" ]]; then
    local topic
    topic=$(echo "$strategy_result" | jq -r '.topic // empty' 2>/dev/null)
    if [[ -n "$topic" ]]; then
      BOUNDARY_MODE="topic"
      BOUNDARY_TOPIC="$topic"
      BOUNDARY_DESC="topic: $topic (fallback: last $KEEP_LAST)"
    fi
  fi
}
