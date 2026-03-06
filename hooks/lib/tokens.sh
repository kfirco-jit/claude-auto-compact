#!/bin/bash
# Token extraction from Claude Code session JSONL files

tokens_get_latest() {
  local path="$1"
  local line
  line=$(tail -100 "$path" 2>/dev/null | grep '"input_tokens"' | tail -1)
  if [[ -z "$line" ]]; then
    echo "0"
    return
  fi
  echo "$line" | jq '
    .message.usage |
    (.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0)
  ' 2>/dev/null || echo "0"
}

tokens_count_user_turns() {
  local path="$1"
  local count
  count=$(grep -c '"type":"user"' "$path" 2>/dev/null) || true
  echo "${count:-0}"
}

tokens_has_summary_record() {
  local path="$1"
  head -10 "$path" 2>/dev/null | grep -q '"type":"summary"'
}

# Count user turns added AFTER the last compaction (post-summary turns).
# If never compacted, returns total user turns.
tokens_count_post_summary_turns() {
  local path="$1"
  if ! tokens_has_summary_record "$path"; then
    tokens_count_user_turns "$path"
    return
  fi
  local summary_line
  summary_line=$(grep -n '"type":"summary"' "$path" 2>/dev/null | tail -1 | cut -d: -f1)
  if [[ -z "$summary_line" ]]; then
    tokens_count_user_turns "$path"
    return
  fi
  local count
  count=$(tail -n +"$((summary_line + 1))" "$path" 2>/dev/null | grep -c '"type":"user"') || true
  echo "${count:-0}"
}

tokens_session_age_minutes() {
  local path="$1"
  local first_ts
  first_ts=$(head -1 "$path" 2>/dev/null | jq -r '.timestamp // empty' 2>/dev/null)
  if [[ -z "$first_ts" ]]; then
    echo "0"
    return
  fi
  # Parse ISO timestamp to epoch seconds
  local ts_epoch now_epoch
  ts_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${first_ts%%.*}" "+%s" 2>/dev/null) || \
    ts_epoch=$(date -d "${first_ts}" "+%s" 2>/dev/null) || { echo "0"; return; }
  now_epoch=$(date "+%s")
  echo $(( (now_epoch - ts_epoch) / 60 ))
}

# Extract compaction summary text length (0 if not compacted)
tokens_summary_length() {
  local path="$1"
  local line
  line=$(head -10 "$path" 2>/dev/null | grep '"type":"summary"' | head -1)
  if [[ -z "$line" ]]; then
    echo "0"
    return
  fi
  echo "$line" | jq '.summary | length' 2>/dev/null || echo "0"
}

tokens_resolve_transcript() {
  local hook_input="$1"
  local path
  path=$(echo "$hook_input" | jq -r '.transcript_path // empty' 2>/dev/null)

  if [[ -n "$path" ]] && [[ -f "$path" ]]; then
    echo "$path"
    return 0
  fi

  # Fallback: construct from session_id + cwd
  local session_id cwd project_dir
  session_id=$(echo "$hook_input" | jq -r '.session_id // empty' 2>/dev/null)
  cwd=$(echo "$hook_input" | jq -r '.cwd // empty' 2>/dev/null)

  if [[ -n "$session_id" ]] && [[ -n "$cwd" ]]; then
    project_dir=$(echo "$cwd" | tr '/' '-')
    path="${HOME}/.claude/projects/${project_dir}/${session_id}.jsonl"
    if [[ -f "$path" ]]; then
      echo "$path"
      return 0
    fi
  fi

  return 1
}
