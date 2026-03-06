#!/bin/bash
# Token extraction from Claude Code session JSONL files

tokens_get_latest() {
  local path="$1"
  tail -100 "$path" 2>/dev/null \
    | grep '"input_tokens"' \
    | tail -1 \
    | python3 -c "
import sys, json
line = sys.stdin.readline()
if not line.strip():
    print(0)
    sys.exit(0)
obj = json.loads(line)
u = obj.get('message', {}).get('usage', {})
total = u.get('input_tokens', 0) + u.get('cache_creation_input_tokens', 0) + u.get('cache_read_input_tokens', 0)
print(total)
" 2>/dev/null || echo "0"
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
  # Find the line number of the last summary record, count user turns after it
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
  local ts
  ts=$(head -1 "$path" 2>/dev/null | python3 -c "
import sys, json
from datetime import datetime, timezone
line = sys.stdin.readline()
if not line.strip():
    print(0)
    sys.exit(0)
obj = json.loads(line)
ts = obj.get('timestamp', '')
if not ts:
    print(0)
    sys.exit(0)
dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
age = (datetime.now(timezone.utc) - dt).total_seconds() / 60
print(int(age))
" 2>/dev/null) || echo "0"
  echo "$ts"
}

# Extract compaction summary text length (0 if not compacted)
tokens_summary_length() {
  local path="$1"
  head -10 "$path" 2>/dev/null | grep '"type":"summary"' | head -1 | python3 -c "
import sys, json
line = sys.stdin.readline()
if not line.strip():
    print(0)
    sys.exit(0)
obj = json.loads(line)
print(len(obj.get('summary', '')))
" 2>/dev/null || echo "0"
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
