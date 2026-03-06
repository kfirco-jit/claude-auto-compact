#!/bin/bash
# Tests for hooks/lib/tokens.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib/platform.sh"
source "$SCRIPT_DIR/../hooks/lib/tokens.sh"

FIXTURE="$SCRIPT_DIR/fixtures/sample-session.jsonl"

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [[ "$expected" == "$actual" ]]; then
    echo "  PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    FAIL=$((FAIL + 1))
  fi
}

echo "=== tokens.sh tests ==="

# tokens_get_latest — last assistant message has 1 + 4000 + 145000 = 149001
TOKENS=$(tokens_get_latest "$FIXTURE")
assert_eq "get_latest returns correct total" "149001" "$TOKENS"

# tokens_count_user_turns
TURNS=$(tokens_count_user_turns "$FIXTURE")
assert_eq "count_user_turns" "3" "$TURNS"

# tokens_has_summary_record — fixture has no summary
if tokens_has_summary_record "$FIXTURE"; then
  echo "  FAIL: should not detect summary in normal fixture"
  FAIL=$((FAIL + 1))
else
  echo "  PASS: no summary in normal fixture"
  PASS=$((PASS + 1))
fi

# Test with a compacted fixture (summary + subsequent turns)
COMPACT_FIXTURE=$(mktemp)
echo '{"type":"summary","summary":"This is a test summary of previous work","leafUuid":"test"}' > "$COMPACT_FIXTURE"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"first post-summary turn"}]}}' >> "$COMPACT_FIXTURE"
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"response"}]}}' >> "$COMPACT_FIXTURE"
echo '{"type":"user","message":{"role":"user","content":[{"type":"text","text":"second post-summary turn"}]}}' >> "$COMPACT_FIXTURE"
echo '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"response"}]}}' >> "$COMPACT_FIXTURE"

if tokens_has_summary_record "$COMPACT_FIXTURE"; then
  echo "  PASS: detects summary in compacted fixture"
  PASS=$((PASS + 1))
else
  echo "  FAIL: should detect summary in compacted fixture"
  FAIL=$((FAIL + 1))
fi

# tokens_count_post_summary_turns — should count only turns after summary
POST_TURNS=$(tokens_count_post_summary_turns "$COMPACT_FIXTURE")
assert_eq "count_post_summary_turns" "2" "$POST_TURNS"

# tokens_count_post_summary_turns — on non-compacted file returns total
POST_TURNS_NORMAL=$(tokens_count_post_summary_turns "$FIXTURE")
assert_eq "count_post_summary_turns on normal file" "3" "$POST_TURNS_NORMAL"

# tokens_summary_length — should return length of summary text
SUMMARY_LEN=$(tokens_summary_length "$COMPACT_FIXTURE")
assert_eq "summary_length" "39" "$SUMMARY_LEN"

# tokens_summary_length — on non-compacted file returns 0
SUMMARY_LEN_NORMAL=$(tokens_summary_length "$FIXTURE")
assert_eq "summary_length on normal file" "0" "$SUMMARY_LEN_NORMAL"

rm -f "$COMPACT_FIXTURE"

# tokens_session_age_minutes
AGE=$(tokens_session_age_minutes "$FIXTURE")
if [[ "$AGE" =~ ^[0-9]+$ ]] && [[ "$AGE" -gt 0 ]]; then
  echo "  PASS: session_age_minutes is positive integer ($AGE)"
  PASS=$((PASS + 1))
else
  echo "  FAIL: session_age_minutes not positive integer ('$AGE')"
  FAIL=$((FAIL + 1))
fi

# tokens_resolve_transcript — with valid transcript_path
RESOLVED=$(tokens_resolve_transcript "{\"transcript_path\":\"$FIXTURE\",\"session_id\":\"x\",\"cwd\":\"/tmp\"}")
assert_eq "resolve with transcript_path" "$FIXTURE" "$RESOLVED"

# tokens_resolve_transcript — with empty transcript_path (should fail for nonexistent session)
RESOLVED=$(tokens_resolve_transcript '{"transcript_path":"","session_id":"nonexistent","cwd":"/nonexistent"}')
assert_eq "resolve with nonexistent fallback" "" "$RESOLVED"

# Edge case: empty file
EMPTY=$(mktemp)
TOKENS=$(tokens_get_latest "$EMPTY")
assert_eq "get_latest on empty file" "0" "$TOKENS"
TURNS=$(tokens_count_user_turns "$EMPTY")
assert_eq "count_turns on empty file" "0" "$TURNS"
rm -f "$EMPTY"

# Edge case: nonexistent file
TOKENS=$(tokens_get_latest "/nonexistent/file.jsonl")
assert_eq "get_latest on nonexistent file" "0" "$TOKENS"

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
