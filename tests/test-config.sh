#!/bin/bash
# Tests for hooks/lib/config.sh

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/../hooks/lib/platform.sh"
source "$SCRIPT_DIR/../hooks/lib/config.sh"

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

echo "=== config.sh tests ==="

# Load default config (no user/project overrides)
# Override HOME to isolate from installed user config
_ORIG_HOME="$HOME"
_TEST_HOME=$(mktemp -d)
HOME="$_TEST_HOME"
trap 'HOME="$_ORIG_HOME"; rm -rf "$_TEST_HOME"' EXIT

__INSTALL_DIR="$SCRIPT_DIR/.."
config_load ""

# Test config_get
assert_eq "version" "1" "$(config_get '.version')"
assert_eq "context_window_tokens" "200000" "$(config_get '.context_window_tokens')"
assert_eq "warn_pct" "70" "$(config_get '.thresholds.warn_pct')"
assert_eq "urgent_pct" "85" "$(config_get '.thresholds.urgent_pct')"
assert_eq "compact_pct" "70" "$(config_get '.thresholds.compact_pct')"
assert_eq "keep_last" "10" "$(config_get '.compaction.keep_last')"
assert_eq "strip_noise" "true" "$(config_get '.compaction.strip_noise')"
assert_eq "model" "haiku" "$(config_get '.compaction.model')"
assert_eq "dry_run" "true" "$(config_get '.compaction.dry_run')"
assert_eq "min_turns" "3" "$(config_get '.compaction.min_turns')"
assert_eq "notifications.enabled" "true" "$(config_get '.notifications.enabled')"
assert_eq "max_files" "20" "$(config_get '.logging.max_files')"

# Test config_threshold
assert_eq "warn threshold" "140000" "$(config_threshold warn)"
assert_eq "urgent threshold" "170000" "$(config_threshold urgent)"
assert_eq "compact threshold" "140000" "$(config_threshold compact)"

# Test config_decant_bin
BIN=$(config_decant_bin)
if [[ "$BIN" == *"/.claude/tools/decant/.venv/bin/decant" ]]; then
  echo "  PASS: decant_bin expanded correctly"
  PASS=$((PASS + 1))
else
  echo "  FAIL: decant_bin expansion ('$BIN')"
  FAIL=$((FAIL + 1))
fi

# Test config_log_dir
DIR=$(config_log_dir)
if [[ "$DIR" == *"/.claude/hooks/partial-compact/logs" ]]; then
  echo "  PASS: log_dir expanded correctly"
  PASS=$((PASS + 1))
else
  echo "  FAIL: log_dir expansion ('$DIR')"
  FAIL=$((FAIL + 1))
fi

# Test project override merge
TMPDIR_PROJ=$(mktemp -d)
mkdir -p "$TMPDIR_PROJ/.claude"
echo '{"compaction":{"keep_last":15,"model":"sonnet"}}' > "$TMPDIR_PROJ/.claude/partial-compact.json"
config_load "$TMPDIR_PROJ"
assert_eq "override keep_last" "15" "$(config_get '.compaction.keep_last')"
assert_eq "override model" "sonnet" "$(config_get '.compaction.model')"
assert_eq "non-overridden strip_noise" "true" "$(config_get '.compaction.strip_noise')"
assert_eq "non-overridden warn_pct" "70" "$(config_get '.thresholds.warn_pct')"
rm -rf "$TMPDIR_PROJ"

# Test config_validate — valid config (defaults are valid)
config_load ""
VALIDATION=$(config_validate 2>&1)
VALID_EXIT=$?
assert_eq "valid config returns 0" "0" "$VALID_EXIT"

# Test config_validate — warn_pct > urgent_pct
__CONFIG=$(echo "$__CONFIG" | jq '.thresholds.warn_pct = 90 | .thresholds.urgent_pct = 80')
VALIDATION=$(config_validate 2>&1)
if [[ $? -ne 0 ]] && echo "$VALIDATION" | grep -q "warn_pct"; then
  echo "  PASS: validates warn_pct > urgent_pct"
  PASS=$((PASS + 1))
else
  echo "  FAIL: should reject warn_pct > urgent_pct"
  FAIL=$((FAIL + 1))
fi

# Test config_validate — invalid strategy
config_load ""
__CONFIG=$(echo "$__CONFIG" | jq '.compaction.strategy = "invalid"')
VALIDATION=$(config_validate 2>&1)
if [[ $? -ne 0 ]] && echo "$VALIDATION" | grep -q "strategy"; then
  echo "  PASS: validates invalid strategy"
  PASS=$((PASS + 1))
else
  echo "  FAIL: should reject invalid strategy"
  FAIL=$((FAIL + 1))
fi

# Test config_validate — target_pct out of range
config_load ""
__CONFIG=$(echo "$__CONFIG" | jq '.compaction.target_pct = 5')
VALIDATION=$(config_validate 2>&1)
if [[ $? -ne 0 ]] && echo "$VALIDATION" | grep -q "target_pct"; then
  echo "  PASS: validates target_pct < 10"
  PASS=$((PASS + 1))
else
  echo "  FAIL: should reject target_pct < 10"
  FAIL=$((FAIL + 1))
fi

# Test config_validate — max_rounds out of range
config_load ""
__CONFIG=$(echo "$__CONFIG" | jq '.compaction.max_rounds = 10')
VALIDATION=$(config_validate 2>&1)
if [[ $? -ne 0 ]] && echo "$VALIDATION" | grep -q "max_rounds"; then
  echo "  PASS: validates max_rounds > 5"
  PASS=$((PASS + 1))
else
  echo "  FAIL: should reject max_rounds > 5"
  FAIL=$((FAIL + 1))
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $FAIL
