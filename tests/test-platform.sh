#!/bin/bash
# Tests for hooks/lib/platform.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib/platform.sh"

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

assert_not_empty() {
  local desc="$1" actual="$2"
  if [[ -n "$actual" ]]; then
    echo "  PASS: $desc"
    ((PASS++))
  else
    echo "  FAIL: $desc (empty)"
    ((FAIL++))
  fi
}

echo "=== platform.sh tests ==="

# platform_init
assert_not_empty "platform detected" "$__PLATFORM"
if [[ "$(uname -s)" == "Darwin" ]]; then
  assert_eq "macOS detected" "macos" "$__PLATFORM"
else
  assert_eq "Linux detected" "linux" "$__PLATFORM"
fi

# platform_md5
HASH=$(platform_md5 "test-string")
assert_not_empty "md5 produces output" "$HASH"
assert_eq "md5 is 32 chars" "32" "${#HASH}"

HASH2=$(platform_md5 "test-string")
assert_eq "md5 is deterministic" "$HASH" "$HASH2"

HASH3=$(platform_md5 "different-string")
if [[ "$HASH" != "$HASH3" ]]; then
  echo "  PASS: md5 differs for different input"
  ((PASS++))
else
  echo "  FAIL: md5 same for different input"
  ((FAIL++))
fi

# platform_stat_mtime
MTIME=$(platform_stat_mtime "$SCRIPT_DIR/../config/default.json")
assert_not_empty "stat_mtime returns value" "$MTIME"
if [[ "$MTIME" =~ ^[0-9]+$ ]]; then
  echo "  PASS: stat_mtime is numeric"
  ((PASS++))
else
  echo "  FAIL: stat_mtime not numeric ('$MTIME')"
  ((FAIL++))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
