#!/bin/bash
# Test runner for claude-auto-compact

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0
TOTAL_FAIL=0

for test_file in "$SCRIPT_DIR"/test-*.sh; do
  echo ""
  bash "$test_file"
  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    TOTAL_FAIL=$((TOTAL_FAIL + exit_code))
  fi
done

echo ""
echo "================================"
if [[ $TOTAL_FAIL -eq 0 ]]; then
  echo "All tests passed!"
else
  echo "Total failures: $TOTAL_FAIL"
fi
exit $TOTAL_FAIL
