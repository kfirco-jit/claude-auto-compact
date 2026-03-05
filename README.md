# claude-auto-compact

Automatic **partial** compaction for Claude Code sessions. Keeps your recent context verbatim while summarizing older exchanges — triggered automatically when you exit a session.

## The Problem

Claude Code's built-in auto-compact summarizes your **entire** conversation when the context window fills up. This destroys recent working context — the code you just wrote, the decisions you just made, the bugs you just found. Framework compliance drops from ~95% to ~60-70% after compaction.

## How This Solves It

Two Claude Code hooks work together:

1. **Stop hook** — After every Claude response, checks context usage and warns you when it's getting high (so you can exit before auto-compact fires)
2. **SessionEnd hook** — When you exit, automatically runs [decant](https://github.com/TKasperczyk/decant) to partially compact the session: summarize old stuff, keep last N turns verbatim

Next time you `claude --resume`, you get a cleaner context with your recent work preserved exactly as-is.

```
┌─────────────────────────────────────────────────────────┐
│  Session in Claude Code                                 │
│                                                         │
│  [old exchanges] ──→ summarized by decant               │
│  [old exchanges] ──→ summarized by decant               │
│  [old exchanges] ──→ summarized by decant               │
│  ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─               │
│  [recent turn 1] ──→ preserved verbatim                 │
│  [recent turn 2] ──→ preserved verbatim                 │
│  ...                                                    │
│  [recent turn N] ──→ preserved verbatim                 │
└─────────────────────────────────────────────────────────┘
```

## Requirements

- Claude Code (obviously)
- `jq` — JSON processor
- `python3` (3.10+)
- `git`

## Install

```bash
git clone https://github.com/kfirco-jit/claude-auto-compact.git
cd claude-auto-compact
./install.sh
```

The installer will:
- Install [decant](https://github.com/TKasperczyk/decant) if not present
- Copy hooks to `~/.claude/hooks/partial-compact/`
- Register hooks in `~/.claude/settings.json`
- Create a config file with safe defaults (`dry_run: true`)

## Quick Start

After install, **dry run is ON by default** — no actual compaction happens until you enable it:

```bash
# Check everything is working
auto-compact health

# See your current session's context usage
auto-compact status

# When ready, enable actual compaction:
# Edit ~/.claude/hooks/partial-compact/config.json
# Set "dry_run": false
```

## Configuration

Config file: `~/.claude/hooks/partial-compact/config.json`

```json
{
  "context_window_tokens": 200000,
  "thresholds": {
    "warn_pct": 70,
    "urgent_pct": 85,
    "compact_pct": 70
  },
  "compaction": {
    "strategy": "auto",
    "keep_last": 10,
    "strip_noise": true,
    "model": "haiku",
    "dry_run": false,
    "min_turns": 3,
    "min_session_age_minutes": 5
  },
  "notifications": {
    "enabled": true,
    "on_warning": false,
    "on_compaction": true
  },
  "logging": {
    "directory": "~/.claude/hooks/partial-compact/logs",
    "max_files": 20
  },
  "decant_bin": "~/.claude/tools/decant/.venv/bin/decant"
}
```

| Setting | Default | Description |
|---------|---------|-------------|
| `context_window_tokens` | 200000 | Your model's context window size |
| `thresholds.warn_pct` | 70 | Show warning at this % |
| `thresholds.urgent_pct` | 85 | Show urgent warning at this % |
| `thresholds.compact_pct` | 70 | Trigger compaction on exit at this % |
| `compaction.strategy` | auto | Boundary selection: `auto` (haiku decides topic vs last), `last` (always keep last N) |
| `compaction.keep_last` | 10 | Number of recent user turns to preserve verbatim (used as default/fallback) |
| `compaction.strip_noise` | true | Remove progress indicators, thinking blocks, oversized tool output |
| `compaction.model` | haiku | Model for summarization (haiku/sonnet/opus) |
| `compaction.dry_run` | true | Simulate compaction without modifying files |
| `compaction.min_turns` | 3 | Don't compact sessions with fewer user turns |
| `compaction.min_session_age_minutes` | 5 | Don't compact brand-new sessions |
| `notifications.on_compaction` | true | macOS/Linux notification when compaction completes |

### Per-Project Overrides

Create `.claude/partial-compact.json` in your project root. Only specified keys override defaults:

```json
{
  "compaction": {
    "keep_last": 15,
    "model": "sonnet"
  }
}
```

## CLI

```bash
auto-compact status              # Current session context usage
auto-compact health              # Validate installation
auto-compact config              # Print merged config
auto-compact logs                # Recent compaction logs
auto-compact logs --tail 20      # Last 20 lines of most recent log
auto-compact compact             # Manually compact current session
auto-compact compact --force     # Skip guards (dry_run, min-turns, etc.)
auto-compact version             # Print version
```

## How It Works (Technical)

1. **Stop hook** fires after every Claude response
2. Reads the last 100 lines of the session JSONL file
3. Extracts `input_tokens + cache_creation_input_tokens + cache_read_input_tokens` from the last assistant message
4. If above warn threshold → prints warning to stderr
5. If above urgent threshold → prints urgent warning + optional notification

6. **SessionEnd hook** fires when you exit Claude
7. Runs guard checks: not `/clear`, decant installed, not already compacted, enough turns, old enough, above threshold
8. Auto-adjusts `keep_last` if fewer turns exist than configured
9. Runs `decant compact` in the background via `nohup` (doesn't block your terminal)
10. Creates timestamped log, rotates old logs

**Why this works:** Claude Code stores sessions as JSONL files. When a session is not active, the JSONL is the only state. `decant` rewrites the JSONL with a summary of old exchanges + verbatim recent turns. When you `claude --resume`, it reconstructs from the JSONL — loading the partially compacted version.

**Why it can't work during a session:** Claude Code's in-memory state is the source of truth during an active session. The JSONL is an append-only log. Modifying the JSONL has no effect on the running session.

## Uninstall

```bash
cd claude-auto-compact
./uninstall.sh
```

## Cross-Platform

| Feature | macOS | Linux |
|---------|-------|-------|
| MD5 hashing | `md5 -q` | `md5sum` |
| Notifications | `osascript` | `notify-send` |
| File timestamps | `stat -f %m` | `stat -c %Y` |

## Troubleshooting

**"No warnings appear"** — Check `auto-compact health`. Verify hooks are registered in `~/.claude/settings.json`.

**"Compaction doesn't run on exit"** — Check `dry_run` setting. Run `auto-compact logs` to see if compaction was attempted.

**"decant errors"** — Check `auto-compact logs --tail 50`. Common issues: authentication (decant needs Anthropic API access via Claude Code's OAuth or `ANTHROPIC_API_KEY`), too few turns.

**"Context still fills up"** — This tool helps on resume, not during a live session. If auto-compact fires before you exit, the live session gets Claude's native compaction. The Stop hook warnings are meant to prompt you to exit in time.

## Credits

- [decant](https://github.com/TKasperczyk/decant) by TKasperczyk — the compaction engine
- Built with Claude Code hooks ([docs](https://code.claude.com/docs/en/hooks))

## License

MIT
