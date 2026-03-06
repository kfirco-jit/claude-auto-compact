#!/usr/bin/env python3
"""Analyze session to decide optimal compaction strategy (topic vs last N)."""

import json
import signal
import sys

from decant.auth import create_client, is_oauth_client, CLAUDE_CODE_SYSTEM_PROMPT
from decant.models import MODELS

MAX_TEXT = 300
MAX_TRANSCRIPT_CHARS = 400_000
MIN_EXCHANGES = 5
API_TIMEOUT_SECONDS = 30


def extract_exchanges(session_path):
    """Extract user messages with metadata about assistant responses."""
    exchanges = []
    pending_user = None

    with open(session_path, encoding="utf-8") as f:
        for line in f:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue

            if record.get("type") == "user":
                if pending_user is not None:
                    exchanges.append(pending_user)
                content = record.get("message", {}).get("content", [])
                text = ""
                for block in content:
                    if isinstance(block, str):
                        text = block
                        break
                    if isinstance(block, dict):
                        if block.get("type") == "text":
                            text = block.get("text", "")
                            break
                        if block.get("type") == "tool_result":
                            inner = block.get("content", "")
                            if isinstance(inner, list):
                                for ib in inner:
                                    if isinstance(ib, dict) and ib.get("type") == "text":
                                        text = f"[tool result] {ib.get('text', '')}"
                                        break
                            elif isinstance(inner, str):
                                text = f"[tool result] {inner}"
                            break
                full_len = len(text)
                text = text[:MAX_TEXT].replace("\n", " ").strip()
                pending_user = {
                    "text": text or "(continuation)",
                    "full_len": full_len,
                    "tools_used": [],
                    "assistant_len": 0,
                }

            elif record.get("type") == "assistant" and pending_user is not None:
                content = record.get("message", {}).get("content", [])
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    if block.get("type") == "tool_use":
                        name = block.get("name", "unknown")
                        inp = block.get("input", {})
                        detail = ""
                        if name in ("Read", "Write", "Edit", "Glob"):
                            detail = inp.get("file_path", inp.get("pattern", ""))[:80]
                        elif name == "Bash":
                            detail = inp.get("command", "")[:80]
                        elif name == "Grep":
                            detail = inp.get("pattern", "")[:80]
                        elif name == "Task":
                            detail = inp.get("description", "")[:80]
                        if detail:
                            pending_user["tools_used"].append(f"{name}:{detail}")
                        else:
                            pending_user["tools_used"].append(name)
                    elif block.get("type") == "text":
                        pending_user["assistant_len"] += len(block.get("text", ""))

    if pending_user is not None:
        exchanges.append(pending_user)

    return exchanges


def format_exchange(index, total, ex):
    """Format a single exchange for the transcript."""
    parts = [f"[{index}/{total}] {ex['text']}"]
    if ex["full_len"] > MAX_TEXT:
        parts.append(f"  (message truncated, full length: {ex['full_len']} chars)")
    if ex["tools_used"]:
        tools = ", ".join(ex["tools_used"][:8])
        if len(ex["tools_used"]) > 8:
            tools += f" (+{len(ex['tools_used']) - 8} more)"
        parts.append(f"  tools: {tools}")
    if ex["assistant_len"] > 0:
        parts.append(f"  response: ~{ex['assistant_len']} chars")
    return "\n".join(parts)


def decide_strategy(session_path, keep_last_default):
    exchanges = extract_exchanges(session_path)

    if len(exchanges) < MIN_EXCHANGES:
        return {"mode": "last", "last": keep_last_default}

    total = len(exchanges)
    full_transcript = "\n\n".join(
        format_exchange(i + 1, total, ex) for i, ex in enumerate(exchanges)
    )
    if len(full_transcript) > MAX_TRANSCRIPT_CHARS:
        half = MAX_TRANSCRIPT_CHARS // 2
        transcript = (
            full_transcript[:half]
            + f"\n\n[... {total} exchanges total, middle truncated ...]\n\n"
            + full_transcript[-half:]
        )
    else:
        transcript = full_transcript

    client = create_client()
    system = (
        "You analyze Claude Code session transcripts to find the optimal "
        "compaction boundary. Your goal: decide what recent work to preserve "
        "verbatim vs what can be summarized.\n\n"
        "Each exchange shows: [index/total] user message, tools the assistant "
        "used, and response size. Use this to understand what happened at each "
        "turn.\n\n"
        "Determine:\n\n"
        "1. MODE:\n"
        "   - 'topic': Clear shift where the user moved to a different task. "
        "Return a topic description of the newer work to keep.\n"
        "   - 'last': Continuous flow on one task. Use a turn count.\n\n"
        "2. TOPIC (if mode=topic): Short description of the newer work to "
        "KEEP. Specific enough for an LLM to find the boundary message.\n\n"
        "3. CUT_BEFORE_INDEX: The index of the first exchange to KEEP "
        "verbatim. Everything before this index gets summarized. "
        "For example, cut_before_index=15 means exchanges 1-14 are "
        "summarized and 15 onward are kept.\n\n"
        "Consider:\n"
        "- Keep more turns if recent work is complex (many tools, large "
        "responses, multi-step implementation)\n"
        "- Keep fewer if recent turns are simple (short commands, confirmations)\n"
        "- Look for natural boundaries: topic shifts, 'now let's...', "
        "new feature starts, bug shifts\n\n"
        "Respond with ONLY valid JSON, no other text:\n"
        '{"mode": "topic"|"last", "topic": "<description>" or null, '
        '"cut_before_index": <number>, "reasoning": "<one sentence>"}'
    )
    if is_oauth_client(client):
        system = CLAUDE_CODE_SYSTEM_PROMPT + "\n\n" + system

    # Timeout to prevent hanging on API issues
    old_handler = signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(TimeoutError()))
    signal.alarm(API_TIMEOUT_SECONDS)
    try:
        response = client.messages.create(
            model=MODELS["haiku"],
            max_tokens=256,
            system=system,
            messages=[{
                "role": "user",
                "content": f"Session has {total} exchanges.\n\n{transcript}",
            }],
        )
    finally:
        signal.alarm(0)
        signal.signal(signal.SIGALRM, old_handler)

    if not response.content:
        return {"mode": "last", "last": keep_last_default}

    raw_response = response.content[0].text.strip()
    # Strip markdown code fences if wrapping the response
    if raw_response.startswith("```"):
        lines = raw_response.split("\n")
        if lines[0].startswith("```"):
            lines = lines[1:]
        if lines and lines[-1].startswith("```"):
            lines = lines[:-1]
        raw_response = "\n".join(lines).strip()

    try:
        result = json.loads(raw_response)
        cut = result.get("cut_before_index")
        if isinstance(cut, int) and 1 < cut <= total:
            result["last"] = total - cut + 1
        else:
            result["last"] = keep_last_default
        result["last"] = max(1, min(result["last"], total - 1))
        if result.get("mode") == "topic" and result.get("topic"):
            return result
        result["mode"] = "last"
        return result
    except json.JSONDecodeError:
        pass

    return {"mode": "last", "last": keep_last_default}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"mode": "last", "last": 10, "error": "usage: strategy.py <session> <keep_last>"}))
        sys.exit(1)

    try:
        session_path = sys.argv[1]
        keep_last = int(sys.argv[2])
        result = decide_strategy(session_path, keep_last)
    except Exception as e:
        result = {"mode": "last", "last": int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[2].isdigit() else 10, "fallback": True, "error": str(e)}

    print(json.dumps(result))
