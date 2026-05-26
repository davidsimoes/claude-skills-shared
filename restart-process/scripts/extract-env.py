#!/usr/bin/env python3
"""
Cross-platform env extraction from a PID. Emits NUL-delimited KEY=VALUE pairs
filtered to claude-relevant prefixes only.

Usage: extract-env.py <pid>

On Linux: reads /proc/<pid>/environ (NUL-separated, authoritative)
On macOS: parses `ps ewww <pid>` output (positional, no -o, no -p) — `-o command= -p PID` does NOT emit env on Darwin.

Exit codes:
  0 = success (env may be empty if no relevant vars set)
  2 = PID dead or env unreadable (caller should fall back to CLAUDE_CONFIG_DIR-only)
"""
import sys
import os
import re
import subprocess

PREFIXES = re.compile(r'^(ANTHROPIC_|CLAUDE_CODE_|AWS_|GOOGLE_CLOUD_|OPENAI_API_KEY=)')


def main():
    if len(sys.argv) != 2:
        print('usage: extract-env.py <pid>', file=sys.stderr)
        sys.exit(2)
    try:
        pid = int(sys.argv[1])
    except ValueError:
        print(f'extract-env: invalid pid {sys.argv[1]!r}', file=sys.stderr)
        sys.exit(2)

    try:
        if sys.platform == 'linux':
            with open(f'/proc/{pid}/environ', 'rb') as f:
                env_bytes = f.read().split(b'\x00')
            for kv in env_bytes:
                if not kv:
                    continue
                s = kv.decode('utf-8', errors='replace')
                if PREFIXES.match(s):
                    sys.stdout.buffer.write(kv + b'\x00')
        else:
            # macOS — use positional `ps ewww PID`
            out = subprocess.check_output(
                ['ps', 'ewww', str(pid)],
                stderr=subprocess.DEVNULL,
            ).decode().rstrip('\n')
            lines = out.splitlines()
            # Skip header line if present (header doesn't start with PID digit)
            if lines and not re.match(r'^\s*\d+', lines[0]):
                lines = lines[1:]
            data = ' '.join(lines)
            toks = data.split()  # split on any whitespace run — eliminates empty tokens
            env_start = None
            for i, tok in enumerate(toks):
                if re.match(r'^[A-Z_][A-Z0-9_]*=', tok):
                    env_start = i
                    break
            if env_start is None:
                sys.exit(0)
            env = {}
            cur_key = None
            for tok in toks[env_start:]:
                if re.match(r'^[A-Z_][A-Z0-9_]*=', tok):
                    k, v = tok.split('=', 1)
                    env[k] = v
                    cur_key = k
                elif cur_key is not None:
                    env[cur_key] += ' ' + tok
            for k, v in env.items():
                if PREFIXES.match(f'{k}='):
                    sys.stdout.buffer.write(f'{k}={v}'.encode() + b'\x00')
    except (FileNotFoundError, ProcessLookupError, subprocess.CalledProcessError, PermissionError) as e:
        print(f'extract-env: cannot read env for pid {pid}: {e}', file=sys.stderr)
        sys.exit(2)


if __name__ == '__main__':
    main()
