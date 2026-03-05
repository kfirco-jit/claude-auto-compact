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
    ((PASS++))
  else
    echo "  FAIL: $desc (expected '$expected', got '$actual')"
    ((FAIL++))
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
  ((FAIL++))
else
  echo "  PASS: no summary in normal fixture"
  ((PASS++))
fi

# Test with a compacted fixture
COMPACT_FIXTURE=$(mktemp)
echo '{"type":"summary","summary":"This is a test summary","leafUuid":"test"}' > "$COMPACT_FIXTURE"
cat "$FIXTURE" >> "$COMPACT_FIXTURE"
if tokens_has_summary_record "$COMPACT_FIXTURE"; then
  echo "  PASS: detects summary in compacted fixture"
  ((PASS++))
else
  echo "  FAIL: should detect summary in compacted fixture"
  ((FAIL++))
fi
rm -f "$COMPACT_FIXTURE"

# tokens_session_age_minutes
AGE=$(tokens_session_age_minutes "$FIXTURE")
if [[ "$AGE" =~ ^[0-9]+$ ]] && [[ "$AGE" -gt 0 ]]; then
  echo "  PASS: session_age_minutes is positive integer ($AGE)"
  ((PASS++))
else
  echo "  FAIL: session_age_minutes not positive integer ('$AGE')"
  ((FAIL++))
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
