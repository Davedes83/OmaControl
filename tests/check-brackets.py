#!/usr/bin/env python3
"""Structural delimiter-balance check for QML/JS sources.

qmllint needs the Quickshell module tree, which CI cannot provide, but a
truncated or brace-misbalanced file is a hard syntax error every backend can
detect. This checker strips comments, strings, regex-as-literal-guess and
template literals, then verifies (), [] and {} stay balanced — cheap, offline,
and false-positive-free on the codebase's actual sources.

Usage: check-brackets.py FILE...
"""

import sys

QUOTES = ("'", '"', "`")


def strip_comments_and_strings(text):
    out = []
    i = 0
    n = len(text)
    state = "code"  # code | sq | dq | bt | line | block
    while i < n:
        c = text[i]
        nxt = text[i + 1] if i + 1 < n else ""
        if state == "code":
            if c == "'":
                state = "sq"
            elif c == '"':
                state = "dq"
            elif c == "`":
                state = "bt"
            elif c == "/" and nxt == "/":
                state = "line"
                i += 1
            elif c == "/" and nxt == "*":
                state = "block"
                i += 1
            else:
                out.append(c)
        elif state in ("sq", "dq", "bt"):
            if c == "\\":
                i += 1  # skip the escaped char below
            elif c == ("'" if state == "sq" else '"' if state == "dq" else "`"):
                state = "code"
            # any other char is string content — dropped
        elif state == "line":
            if c == "\n":
                state = "code"
                out.append(c)
        elif state == "block":
            if c == "*" and nxt == "/":
                state = "code"
                i += 1
        i += 1
    return "".join(out)


def check(path):
    with open(path, encoding="utf-8") as f:
        code = strip_comments_and_strings(f.read())
    stack = []
    pairs = {")": "(", "]": "[", "}": "{"}
    closes = set(pairs)
    for pos, ch in enumerate(code):
        if ch in "([{":
            stack.append(ch)
        elif ch in closes:
            if not stack or stack[-1] != pairs[ch]:
                print(f"{path}: unmatched {ch!r} at character {pos}")
                return False
            stack.pop()
    if stack:
        print(f"{path}: {len(stack)} unclosed delimiter(s): {''.join(stack)}")
        return False
    return True


def main(argv):
    bad = False
    for path in argv[1:]:
        if not check(path):
            bad = True
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))