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

  if [[ -z "$__INSTALL_DIR" ]]; then
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
