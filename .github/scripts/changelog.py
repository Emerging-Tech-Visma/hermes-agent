#!/usr/bin/env python3
"""Read CHANGELOG.md — the single source of truth for the repo's version.

Used by .github/workflows/changelog.yml (gate) and release.yml (publish), and
usable by hand:

    python3 .github/scripts/changelog.py top            # 0.14.3
    python3 .github/scripts/changelog.py versions       # every released version
    python3 .github/scripts/changelog.py notes 0.14.3   # that section's body
"""

import re
import sys
from pathlib import Path

HEADING = re.compile(r"^## \[(?P<version>\d+\.\d+\.\d+)\][^\n]*$")
SEMVER = re.compile(r"^\d+\.\d+\.\d+$")


def sections(text):
    """Yield (version, heading_line, body) for every released version, in file order.

    A section runs from its `## [x.y.z]` heading to the next `## ` heading. Entries in
    this file are separated by `---` rules, so the trailing rule is stripped from the
    body. `## [Unreleased]` is skipped — it carries no version.
    """
    lines = text.splitlines()
    starts = [i for i, line in enumerate(lines) if line.startswith("## ")]
    for n, start in enumerate(starts):
        match = HEADING.match(lines[start])
        if not match:
            continue
        end = starts[n + 1] if n + 1 < len(starts) else len(lines)
        body = lines[start + 1 : end]
        while body and (body[-1].strip() == "" or body[-1].strip() == "---"):
            body.pop()
        yield match.group("version"), lines[start], "\n".join(body).strip()


def key(version):
    return tuple(int(part) for part in version.split("."))


def main(argv):
    path = Path(argv[2] if len(argv) > 2 and argv[1] == "--file" else "CHANGELOG.md")
    args = argv[3:] if argv[1] == "--file" else argv[1:]
    if not args:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    command = args[0]
    found = list(sections(path.read_text(encoding="utf-8")))

    if command == "top":
        if not found:
            print("no released version found in CHANGELOG.md", file=sys.stderr)
            return 1
        print(found[0][0])
    elif command == "versions":
        for version, _, _ in found:
            print(version)
    elif command == "notes":
        if len(args) < 2 or not SEMVER.match(args[1]):
            print("usage: changelog.py notes <x.y.z>", file=sys.stderr)
            return 2
        for version, _, body in found:
            if version == args[1]:
                print(body)
                return 0
        print(f"no section for {args[1]} in {path}", file=sys.stderr)
        return 1
    elif command == "newer":
        if len(args) < 3:
            print("usage: changelog.py newer <a> <b>", file=sys.stderr)
            return 2
        return 0 if key(args[1]) > key(args[2]) else 1
    else:
        print(f"unknown command: {command}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
