#!/bin/bash
# JSON config loading and merging for claude-auto-compact

__CONFIG=""
__INSTALL_DIR=""

config_find_install_dir() {
  local dir="$1"
  while [[ "$dir" != "/" ]]; do
    if [[ -f "$dir/config/default.json" ]]; then
      echo "$dir"
      return 0
    fi
    dir="$(dirname "$dir")"
  done
  # Fallback: installed location
  local expanded="${HOME}/.claude/hooks/partial-compact"
  if [[ -f "$expanded/config/default.json" ]]; then
    echo "$expanded"
    return 0
  fi
  return 1
}

config_load() {
  local cwd="${1:-}"
  local install_dir="${2:-}"

  if [[ -n "$install_dir" ]]; then
    __INSTALL_DIR="$install_dir"
  elif [[ -z "$__INSTALL_DIR" ]]; then
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    __INSTALL_DIR=$(config_find_install_dir "$script_dir") || return 1
  fi

  local default_config="$__INSTALL_DIR/config/default.json"
  local user_config="${HOME}/.claude/hooks/partial-compact/config.json"
  local project_config=""

  if [[ -n "$cwd" ]] && [[ -f "$cwd/.claude/partial-compact.json" ]]; then
    project_config="$cwd/.claude/partial-compact.json"
  fi

  if [[ -n "$project_config" ]]; then
    __CONFIG=$(jq -s '.[0] * .[1] * .[2]' \
      "$default_config" \
      <(if [[ -f "$user_config" ]]; then cat "$user_config"; else echo '{}'; fi) \
      "$project_config" 2>/dev/null)
  elif [[ -f "$user_config" ]]; then
    __CONFIG=$(jq -s '.[0] * .[1]' "$default_config" "$user_config" 2>/dev/null)
  else
    __CONFIG=$(cat "$default_config" 2>/dev/null)
  fi

  if [[ -z "$__CONFIG" ]]; then
    __CONFIG=$(cat "$default_config" 2>/dev/null)
  fi
}

config_get() {
  local path="$1"
  echo "$__CONFIG" | jq -r "$path" 2>/dev/null
}

config_threshold() {
  local which="$1"
  local pct
  pct=$(config_get ".thresholds.${which}_pct")
  local window
  window=$(config_get ".context_window_tokens")
  echo $(( window * pct / 100 ))
}

config_decant_bin() {
  local bin
  bin=$(config_get ".decant_bin")
  echo "${bin/#\~/$HOME}"
}

config_log_dir() {
  local dir
  dir=$(config_get ".logging.directory")
  echo "${dir/#\~/$HOME}"
}

# Validate config values. Returns warnings on stderr, returns 0 if valid, 1 if critical errors.
config_validate() {
  local errors=0
  local warn_pct compact_pct urgent_pct keep_last min_turns

  warn_pct=$(config_get '.thresholds.warn_pct')
  compact_pct=$(config_get '.thresholds.compact_pct')
  urgent_pct=$(config_get '.thresholds.urgent_pct')
  keep_last=$(config_get '.compaction.keep_last')
  min_turns=$(config_get '.compaction.min_turns')

  if [[ "$warn_pct" -gt "$urgent_pct" ]] 2>/dev/null; then
    echo "[auto-compact] config: warn_pct ($warn_pct) > urgent_pct ($urgent_pct)" >&2
    errors=1
  fi
  if [[ "$compact_pct" -gt "$urgent_pct" ]] 2>/dev/null; then
    echo "[auto-compact] config: compact_pct ($compact_pct) > urgent_pct ($urgent_pct)" >&2
    errors=1
  fi
  if [[ "$keep_last" -lt 1 ]] 2>/dev/null; then
    echo "[auto-compact] config: keep_last must be >= 1" >&2
    errors=1
  fi
  if [[ "$min_turns" -lt 1 ]] 2>/dev/null; then
    echo "[auto-compact] config: min_turns must be >= 1" >&2
    errors=1
  fi

  local strategy
  strategy=$(config_get '.compaction.strategy')
  if [[ "$strategy" != "auto" ]] && [[ "$strategy" != "last" ]]; then
    echo "[auto-compact] config: strategy must be 'auto' or 'last', got '$strategy'" >&2
    errors=1
  fi

  local target_pct
  target_pct=$(config_get '.compaction.target_pct')
  if [[ "$target_pct" -lt 10 ]] 2>/dev/null || [[ "$target_pct" -gt 90 ]] 2>/dev/null; then
    echo "[auto-compact] config: target_pct must be 10-90, got '$target_pct'" >&2
    errors=1
  fi

  local max_rounds
  max_rounds=$(config_get '.compaction.max_rounds')
  if [[ "$max_rounds" -lt 1 ]] 2>/dev/null || [[ "$max_rounds" -gt 5 ]] 2>/dev/null; then
    echo "[auto-compact] config: max_rounds must be 1-5, got '$max_rounds'" >&2
    errors=1
  fi

  return $errors
}
