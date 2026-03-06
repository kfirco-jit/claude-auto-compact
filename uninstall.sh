#!/bin/bash
# uninstall.sh — Clean removal of claude-auto-compact
set -e

INSTALL_DIR="$HOME/.claude/hooks/partial-compact"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
echo "  claude-auto-compact uninstaller"
echo "  ================================"
echo ""

# Remove hooks from settings.json
if [[ -f "$SETTINGS_FILE" ]] && grep -q "partial-compact" "$SETTINGS_FILE" 2>/dev/null; then
  echo "Removing hooks from $SETTINGS_FILE..."
  UPDATED=$(jq '
    if .hooks.Stop then
      .hooks.Stop = [.hooks.Stop[] | select(.hooks[0].command | test("partial-compact") | not)]
    else . end |
    if .hooks.SessionEnd then
      .hooks.SessionEnd = [.hooks.SessionEnd[] | select(.hooks[0].command | test("partial-compact") | not)]
    else . end |
    if .hooks.Stop == [] then del(.hooks.Stop) else . end |
    if .hooks.SessionEnd == [] then del(.hooks.SessionEnd) else . end |
    if .hooks == {} then del(.hooks) else . end
  ' "$SETTINGS_FILE")
  echo "$UPDATED" > "$SETTINGS_FILE"
  echo "[OK] Hooks removed from settings.json"
else
  echo "[OK] No hooks found in settings.json"
fi

# Remove symlinks
for dir in "$HOME/.local/bin" "/usr/local/bin"; do
  if [[ -L "$dir/auto-compact" ]]; then
    rm -f "$dir/auto-compact"
    echo "[OK] Removed symlink from $dir"
  fi
done

# Remove installation
if [[ -d "$INSTALL_DIR" ]]; then
  echo ""
  read -p "Remove $INSTALL_DIR? [Y/n] " -n 1 -r
  echo ""
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    if [[ "$INSTALL_DIR" == "$HOME/.claude/hooks/partial-compact" ]]; then
      rm -rf "$INSTALL_DIR"
      echo "[OK] Removed $INSTALL_DIR"
    else
      echo "[FAIL] Unexpected install dir: $INSTALL_DIR — skipping removal"
    fi
  fi
fi

# Clean up tmp files
rm -f /tmp/auto-compact-*.lock/pid 2>/dev/null || true
rmdir /tmp/auto-compact-*.lock 2>/dev/null || true
rm -f /tmp/auto-compact-stats-* 2>/dev/null || true

# Optionally remove decant
DECANT_DIR="$HOME/.claude/tools/decant"
if [[ -d "$DECANT_DIR" ]]; then
  echo ""
  read -p "Remove decant at $DECANT_DIR? [y/N] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    rm -rf "$DECANT_DIR"
    echo "[OK] Removed decant"
  else
    echo "[OK] Kept decant (it can be used independently)"
  fi
fi

echo ""
echo "Uninstall complete."
echo ""
