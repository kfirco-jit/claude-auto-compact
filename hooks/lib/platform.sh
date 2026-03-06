#!/bin/bash
# Cross-platform utilities for claude-auto-compact

__PLATFORM=""

platform_init() {
  case "$(uname -s)" in
    Darwin) __PLATFORM="macos" ;;
    Linux)  __PLATFORM="linux" ;;
    *)      __PLATFORM="unknown" ;;
  esac
}

platform_md5() {
  local input="$1"
  if [[ "$__PLATFORM" == "macos" ]]; then
    echo -n "$input" | md5 -q
  else
    echo -n "$input" | md5sum | cut -d' ' -f1
  fi
}

platform_notify() {
  local title="$1"
  local message="$2"

  if [[ "$__PLATFORM" == "macos" ]]; then
    osascript \
      -e "on run {t, m}" \
      -e "display notification m with title t" \
      -e "end run" \
      -- "$title" "$message" 2>/dev/null || true
  elif command -v notify-send &>/dev/null; then
    notify-send "$title" "$message" 2>/dev/null || true
  fi
}

platform_stat_mtime() {
  local path="$1"
  if [[ "$__PLATFORM" == "macos" ]]; then
    stat -f %m "$path" 2>/dev/null
  else
    stat -c %Y "$path" 2>/dev/null
  fi
}

platform_init
