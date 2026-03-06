#!/bin/bash
# install.sh — Interactive installer for claude-auto-compact
set -e

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="$HOME/.claude/hooks/partial-compact"
DECANT_DIR="$HOME/.claude/tools/decant"
SETTINGS_FILE="$HOME/.claude/settings.json"

echo ""
echo "  claude-auto-compact installer"
echo "  =============================="
echo ""

# Check prerequisites
MISSING=""
command -v jq &>/dev/null || MISSING="$MISSING jq"
command -v python3 &>/dev/null || MISSING="$MISSING python3"
command -v git &>/dev/null || MISSING="$MISSING git"

if [[ -n "$MISSING" ]]; then
  echo "Missing prerequisites:$MISSING"
  echo ""
  echo "Install with:"
  echo "  macOS: brew install$MISSING"
  echo "  Linux: sudo apt install$MISSING"
  exit 1
fi
echo "[OK] Prerequisites: jq, python3, git"

# Check for existing installation
if [[ -d "$INSTALL_DIR" ]]; then
  echo ""
  echo "Existing installation found at $INSTALL_DIR"
  read -p "Upgrade? [Y/n] " -n 1 -r
  echo ""
  if [[ $REPLY =~ ^[Nn]$ ]]; then
    echo "Aborted."
    exit 0
  fi
fi

# Install decant if not present
if [[ -x "$DECANT_DIR/.venv/bin/decant" ]]; then
  echo "[OK] Decant already installed at $DECANT_DIR"
else
  echo ""
  echo "Installing decant..."
  if [[ -d "$DECANT_DIR" ]]; then
    (cd "$DECANT_DIR" && git pull 2>/dev/null || true)
  else
    git clone https://github.com/TKasperczyk/decant.git "$DECANT_DIR"
  fi
  (cd "$DECANT_DIR" && python3 -m venv .venv && .venv/bin/pip install -e . -q)
  echo "[OK] Decant installed"
fi

# Copy files
echo ""
echo "Installing to $INSTALL_DIR..."
mkdir -p "$INSTALL_DIR"/{hooks/lib,bin,config,logs}

cp "$REPO_DIR/hooks/stop-monitor.sh" "$INSTALL_DIR/hooks/"
cp "$REPO_DIR/hooks/session-end-compact.sh" "$INSTALL_DIR/hooks/"
cp "$REPO_DIR/hooks/lib/platform.sh" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/hooks/lib/config.sh" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/hooks/lib/tokens.sh" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/hooks/lib/strategy.py" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/hooks/lib/compact-runner.sh" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/hooks/lib/strategy-resolve.sh" "$INSTALL_DIR/hooks/lib/"
cp "$REPO_DIR/bin/auto-compact" "$INSTALL_DIR/bin/"
cp "$REPO_DIR/config/default.json" "$INSTALL_DIR/config/"
cp "$REPO_DIR/config/schema.json" "$INSTALL_DIR/config/"

chmod +x "$INSTALL_DIR/hooks/"*.sh "$INSTALL_DIR/hooks/lib/"*.sh "$INSTALL_DIR/bin/auto-compact"

# Create user config if it doesn't exist
if [[ ! -f "$INSTALL_DIR/config.json" ]]; then
  cp "$REPO_DIR/config/default.json" "$INSTALL_DIR/config.json"
  echo "[OK] Created config at $INSTALL_DIR/config.json (dry_run: true)"
else
  echo "[OK] Existing config preserved at $INSTALL_DIR/config.json"
fi

# Merge hooks into settings.json (with backup)
echo ""
if [[ ! -f "$SETTINGS_FILE" ]]; then
  echo '{}' > "$SETTINGS_FILE"
fi

# Backup before modification
cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"

STOP_HOOK='{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/partial-compact/hooks/stop-monitor.sh"}]}'
END_HOOK='{"hooks":[{"type":"command","command":"$HOME/.claude/hooks/partial-compact/hooks/session-end-compact.sh","timeout":10}]}'

UPDATED=""
if grep -q "partial-compact" "$SETTINGS_FILE" 2>/dev/null; then
  echo "Updating hooks in $SETTINGS_FILE..."
  UPDATED=$(jq \
    --argjson stop_hook "$STOP_HOOK" \
    --argjson end_hook "$END_HOOK" \
    '
    .hooks.Stop = [(.hooks.Stop // [] | .[] | select(.hooks[0].command | test("partial-compact") | not))] + [$stop_hook] |
    .hooks.SessionEnd = [(.hooks.SessionEnd // [] | .[] | select(.hooks[0].command | test("partial-compact") | not))] + [$end_hook]
    ' "$SETTINGS_FILE")
else
  echo "Registering hooks in $SETTINGS_FILE..."
  UPDATED=$(jq \
    --argjson stop_hook "$STOP_HOOK" \
    --argjson end_hook "$END_HOOK" \
    '.hooks.Stop = (.hooks.Stop // []) + [$stop_hook] | .hooks.SessionEnd = (.hooks.SessionEnd // []) + [$end_hook]' \
    "$SETTINGS_FILE")
fi

# Atomic write: validate before overwriting
if [[ -n "$UPDATED" ]] && echo "$UPDATED" | jq empty 2>/dev/null; then
  echo "$UPDATED" > "$SETTINGS_FILE"
  rm -f "${SETTINGS_FILE}.bak"
  echo "[OK] Hooks registered"
else
  echo "[FAIL] Failed to update $SETTINGS_FILE — restoring backup"
  mv "${SETTINGS_FILE}.bak" "$SETTINGS_FILE"
  exit 1
fi

# Symlink CLI
echo ""
SYMLINK_DIR="$HOME/.local/bin"
if [[ -d "$SYMLINK_DIR" ]]; then
  ln -sf "$INSTALL_DIR/bin/auto-compact" "$SYMLINK_DIR/auto-compact"
  echo "[OK] CLI symlinked to $SYMLINK_DIR/auto-compact"
elif [[ -d "/usr/local/bin" ]] && [[ -w "/usr/local/bin" ]]; then
  ln -sf "$INSTALL_DIR/bin/auto-compact" "/usr/local/bin/auto-compact"
  echo "[OK] CLI symlinked to /usr/local/bin/auto-compact"
else
  echo "[NOTE] Add to PATH manually: export PATH=\"$INSTALL_DIR/bin:\$PATH\""
fi

# Run health check
echo ""
"$INSTALL_DIR/bin/auto-compact" health

echo ""
echo "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Edit $INSTALL_DIR/config.json to customize settings"
echo "  2. Set \"dry_run\": false to enable actual compaction"
echo "  3. Start a Claude Code session — hooks are now active"
echo "  4. Run: auto-compact status  (to check current session)"
echo ""
