#!/usr/bin/env python3
"""Analyze session to decide optimal compaction strategy (topic vs last N)."""

import json
import sys

from decant.auth import create_client, is_oauth_client, CLAUDE_CODE_SYSTEM_PROMPT
from decant.models import MODELS


def extract_user_messages(session_path, max_chars=150):
    """Extract condensed user message list from JSONL."""
    messages = []
    with open(session_path) as f:
        for line in f:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "user":
                continue
            content = record.get("message", {}).get("content", [])
            text = ""
            for block in content:
                if isinstance(block, str):
                    text = block
                    break
                if isinstance(block, dict) and block.get("type") == "text":
                    text = block.get("text", "")
                    break
            text = text[:max_chars].replace("\n", " ").strip()
            if text:
                messages.append(text)
    return messages


def decide_strategy(session_path, keep_last_default):
    messages = extract_user_messages(session_path)

    if len(messages) < 5:
        return {"mode": "last", "last": keep_last_default}

    transcript = "\n".join(
        f"[{i+1}/{len(messages)}] {msg}" for i, msg in enumerate(messages)
    )

    client = create_client()
    system = (
        "You analyze Claude Code session transcripts to find the optimal "
        "compaction boundary. Your goal: decide what recent work is worth "
        "preserving verbatim vs what can be summarized.\n\n"
        "Given a numbered list of user messages from a coding session, "
        "determine:\n\n"
        "1. MODE - How to select the boundary:\n"
        "   - 'topic': There's a clear shift where the user moved to a "
        "different task. Use a topic description to find the boundary.\n"
        "   - 'last': The session is a continuous flow. Use a turn count.\n\n"
        "2. TOPIC (if mode=topic) - A short description of the newer work "
        "to KEEP. Be specific enough that an LLM can find the first message "
        "matching this topic.\n\n"
        "3. LAST (always) - How many recent user turns to keep verbatim. "
        "Consider: more turns if the recent work is complex/multi-step, "
        "fewer if it's simple. Range: 3 to 20.\n\n"
        "Respond with ONLY valid JSON, no other text:\n"
        '{"mode": "topic"|"last", "topic": "<description>" or null, '
        '"last": <number>, "reasoning": "<one sentence>"}'
    )
    if is_oauth_client(client):
        system = CLAUDE_CODE_SYSTEM_PROMPT + "\n\n" + system

    response = client.messages.create(
        model=MODELS["haiku"],
        max_tokens=256,
        system=system,
        messages=[{
            "role": "user",
            "content": (
                f"Session has {len(messages)} user messages. "
                f"Default keep_last: {keep_last_default}\n\n{transcript}"
            ),
        }],
    )

    text = response.content[0].text.strip()
    try:
        result = json.loads(text)
        # Validate and clamp last
        last = result.get("last")
        if not isinstance(last, int) or last < 1:
            last = keep_last_default
        result["last"] = max(1, min(last, len(messages) - 1))
        # Validate mode
        if result.get("mode") == "topic" and result.get("topic"):
            return result
        # Default to last mode
        result["mode"] = "last"
        return result
    except (json.JSONDecodeError, KeyError):
        pass

    return {"mode": "last", "last": keep_last_default}


if __name__ == "__main__":
    if len(sys.argv) < 3:
        print(json.dumps({"mode": "last", "last": 10, "error": "usage: strategy.py <session> <keep_last>"}))
        sys.exit(0)

    session_path = sys.argv[1]
    keep_last = int(sys.argv[2])

    try:
        result = decide_strategy(session_path, keep_last)
    except Exception as e:
        result = {"mode": "last", "last": keep_last, "fallback": True, "error": str(e)}

    print(json.dumps(result))
