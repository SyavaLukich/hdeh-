#!/usr/bin/env python3
"""Structural checker for the Pascal sources of hdeh.

It is not a parser - it only catches the structural mistakes that are easy
to make in a large Pascal source tree and cheap to detect:

  * begin/repeat/case/try/record/asm ... end/until imbalance
  * a missing final "end." of a unit / program
  * ";" right before "else" (always a syntax error in Pascal)
  * unbalanced parentheses / brackets
  * unterminated comments and strings

Usage: tools/paslint.py [file.pas ...]     (defaults to src, tests, examples)
Exit status 0 when all files are clean.
"""
import os
import re
import sys

KEYWORDS_OPEN = {"begin", "repeat", "case", "try", "record", "asm"}
# "class" and "object" only open a block after a type declaration: T = class
TYPE_OPEN = {"class", "object"}
KEYWORDS_CLOSE = {"end", "until"}


def strip(src: str):
    """Return (clean_source, tokens, problems)."""
    out = []
    tokens = []
    problems = []
    i = 0
    n = len(src)
    line = 1
    while i < n:
        c = src[i]
        if c == "\n":
            line += 1
            out.append(c)
            i += 1
            continue
        if c == "{":
            j = src.find("}", i)
            if j < 0:
                problems.append((line, "unterminated { comment"))
                break
            line += src.count("\n", i, j)
            out.append("\n" * src.count("\n", i, j))
            i = j + 1
            continue
        if src.startswith("(*", i):
            j = src.find("*)", i + 2)
            if j < 0:
                problems.append((line, "unterminated (* comment"))
                break
            line += src.count("\n", i, j)
            out.append("\n" * src.count("\n", i, j))
            i = j + 2
            continue
        if src.startswith("//", i):
            j = src.find("\n", i)
            if j < 0:
                j = n
            out.append(" " * (j - i))
            i = j
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if src[j] == "'":
                    if j + 1 < n and src[j + 1] == "'":
                        j += 2
                        continue
                    break
                if src[j] == "\n":
                    problems.append((line, "unterminated string"))
                    break
                j += 1
            else:
                problems.append((line, "unterminated string"))
                break
            tokens.append((line, "string"))
            out.append(" " * (j - i + 1 if j < n else j - i))
            i = j + 1
            continue
        out.append(c)
        i += 1

    clean = "".join(out)

    # tokenise identifiers / numbers / punctuation per line
    for ln, text in enumerate(clean.split("\n"), start=1):
        for m in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*|\d+\.\d+|:=|<=|>=|<>|\.\.|[-+*/=<>()\[\];,.:^@]", text):
            tokens.append((ln, m.group(0).lower()))
    return clean, tokens, problems


def check(path: str) -> list:
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        src = f.read()
    clean, tokens, problems = strip(src)

    # "unit X;" opens an implicit block that the final "end." closes, so
    # such files start with a depth of one.  A program has a real "begin".
    depth = 1 if re.match(r"\s*(unit|library)\b", clean, re.IGNORECASE) else 0
    paren = 0
    prev = None
    for idx, (ln, tok) in enumerate(tokens):
        if tok in TYPE_OPEN:
            # "TFoo = class" opens a block; "TFoo = class(Base);" and
            # "TFoo = class;" are declarations without a body, and
            # "class procedure" is a modifier rather than a block
            if prev == "=":
                j = idx + 1
                if j < len(tokens) and tokens[j][1] == "(":
                    lvl = 0
                    while j < len(tokens):
                        if tokens[j][1] == "(":
                            lvl += 1
                        elif tokens[j][1] == ")":
                            lvl -= 1
                            if lvl == 0:
                                j += 1
                                break
                        j += 1
                if j < len(tokens) and tokens[j][1] == ";":
                    pass          # declaration only
                else:
                    depth += 1
            prev = tok
            continue
        if tok == "(":
            paren += 1
        elif tok == ")":
            paren -= 1
            if paren < 0:
                problems.append((ln, "unbalanced ')'"))
                paren = 0
        elif tok == "[":
            paren += 1
        elif tok == "]":
            paren -= 1
            if paren < 0:
                problems.append((ln, "unbalanced ']'"))
                paren = 0
        elif tok in KEYWORDS_OPEN:
            depth += 1
        elif tok in KEYWORDS_CLOSE:
            depth -= 1
            if depth < 0:
                problems.append((ln, f"unexpected '{tok}' (block closed too often)"))
                depth = 0
        elif tok == "else" and prev == ";":
            problems.append((ln, "';' before 'else'"))
        prev = tok

    if paren != 0:
        problems.append((0, f"unbalanced parentheses/brackets ({paren:+d})"))
    if depth != 0:
        problems.append((0, f"unbalanced blocks ({depth:+d} unclosed)"))
    elif not re.search(r"\bend\s*\.\s*$", clean.rstrip()):
        problems.append((0, "file does not end with 'end.'"))

    # leftover preprocessor-level junk
    if "\t" in src:
        pass

    return problems


def iter_sources(args):
    if args:
        yield from args
        return
    for root in ("src", "tests", "examples"):
        for dirpath, _dirs, files in os.walk(root):
            for name in sorted(files):
                if name.endswith((".pas", ".pp", ".lpr")):
                    yield os.path.join(dirpath, name)


def main() -> int:
    bad = 0
    files = sorted(iter_sources(sys.argv[1:]))
    for path in files:
        problems = check(path)
        if problems:
            bad += 1
            print(f"{path}:")
            for ln, msg in problems:
                print(f"    {ln or '?':>6}: {msg}")
        else:
            print(f"{path}: ok")
    print(f"---- {len(files)} files, {bad} with problems ----")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
