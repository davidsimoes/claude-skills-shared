#!/usr/bin/env python3
"""
Canonical CWD encoding used by Claude Code for session-transcript directory names
under its config dir's `projects/` subfolder. Verified by inspection of a live install.

Algorithm:
  1. Each '/' → '-'
  2. Each '.' → '-'
  Existing literal '-' characters in the path are preserved as '-' (no double-dash).
  The double-dash you may see in something like `-Users-alice--config-skills-...` comes
  from a `/.` sequence (slash then dot) collapsing to `--`, NOT from escaping a literal
  '-' in the path.

Usage: escape-cwd.py /Users/alice/projects/my-app
       → -Users-alice-projects-my-app
"""
import sys


def escape_cwd(path: str) -> str:
    return path.replace('/', '-').replace('.', '-')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('usage: escape-cwd.py <absolute-path>', file=sys.stderr)
        sys.exit(2)
    print(escape_cwd(sys.argv[1]))
