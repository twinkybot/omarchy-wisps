#!/usr/bin/env python3
"""Decide whether a finished turn ended well or badly.

The Stop hook only knows that the agent stopped, not how it went. PostToolUse
would be the obvious place to notice a failing command, but it does not fire
for failed tool calls at all -- only successful ones -- so the failure never
reaches a hook.

The transcript does record it. Every failed tool call lands in the session's
JSONL as a tool_result carrying "is_error": true, so on Stop we read back the
turn that just ended and count them.

Prints "trouble" or "done". Any doubt at all prints "done": a cosmetic plugin
should never claim something went wrong when it cannot tell.
"""
import json
import os
import stat
import sys
from collections import deque

# One failed command is ordinary -- a grep that matches nothing, a test that is
# meant to fail, a probe. Several in a single turn is the agent flailing, which
# is the moment actually worth looking up at.
ERROR_THRESHOLD = 3

# Errors from the turn that just ended will be near the end of the file, and a
# long session's transcript can be many megabytes.
TAIL_LINES = 800


def is_user_turn(entry):
    """True for a real user prompt, not a tool result echoed back as 'user'."""
    if entry.get("type") != "user":
        return False
    content = (entry.get("message") or {}).get("content")
    if isinstance(content, str):
        return True
    if isinstance(content, list):
        return not any(
            isinstance(c, dict) and c.get("type") == "tool_result" for c in content
        )
    return False


# A transcript line is JSON holding whole tool outputs, so it can be large.
MAX_LINE = 256 * 1024


def count_errors(path):
    # Regular files only, and never follow a symlink into something else --
    # the path arrives in a hook payload, so treat it as untrusted input.
    st = os.lstat(path)
    if not stat.S_ISREG(st.st_mode):
        raise ValueError("not a regular file")

    with open(path, "r", errors="replace") as fh:
        lines = deque((ln[:MAX_LINE] for ln in fh), maxlen=TAIL_LINES)

    entries = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except (ValueError, TypeError):
            continue

    # Walk back to the start of the turn that just finished.
    start = 0
    for i in range(len(entries) - 1, -1, -1):
        if is_user_turn(entries[i]):
            start = i
            break

    errors = 0
    for entry in entries[start:]:
        content = (entry.get("message") or {}).get("content")
        if not isinstance(content, list):
            continue
        for c in content:
            if isinstance(c, dict) and c.get("type") == "tool_result" and c.get("is_error"):
                errors += 1
    return errors


def main():
    try:
        payload = json.load(sys.stdin)
        path = payload.get("transcript_path")
        if not path:
            print("done")
            return
        print("trouble" if count_errors(path) >= ERROR_THRESHOLD else "done")
    except Exception:
        print("done")


if __name__ == "__main__":
    main()
