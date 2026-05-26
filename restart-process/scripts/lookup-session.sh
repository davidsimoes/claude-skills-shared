#!/usr/bin/env bash
# lookup-session.sh — given a claude PID, find its sessionId, cwd, version, source_config_dir
# Outputs single-line JSON to stdout, or empty + non-zero exit on failure.

set -euo pipefail

CLAUDE_PID="${1:?usage: lookup-session.sh <claude_pid>}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Enumerate candidate Claude config dirs to search for sessions/<pid>.json.
# The primary location is $CLAUDE_CONFIG_DIR (or $HOME/.claude). If a multi-profile
# manager populates $CLAUDE_CONFIG_DIRS as a colon-separated list, those are added too.
# This keeps the script useful for both single-profile and multi-profile setups
# without hard-coding any particular profile manager.
PROFILE_DIRS=$(python3 -c "
import os
seen = []
def add(d):
    d = os.path.expanduser(d) if d else d
    if d and d not in seen and os.path.isdir(d):
        seen.append(d)
add(os.environ.get('CLAUDE_CONFIG_DIR') or os.path.expanduser('~/.claude'))
for d in (os.environ.get('CLAUDE_CONFIG_DIRS') or '').split(':'):
    add(d)
for d in seen:
    print(d)
")

# Try each profile's sessions/<pid>.json (they may be hardlinked when mergeSessions: true)
SESSION_JSON=""
for dir in $PROFILE_DIRS; do
    candidate="$dir/sessions/$CLAUDE_PID.json"
    if [ -f "$candidate" ]; then
        SESSION_JSON="$candidate"
        break
    fi
done

# Fallback: also check primary ~/.claude/sessions/
if [ -z "$SESSION_JSON" ] && [ -f "$HOME/.claude/sessions/$CLAUDE_PID.json" ]; then
    SESSION_JSON="$HOME/.claude/sessions/$CLAUDE_PID.json"
fi

if [ -z "$SESSION_JSON" ]; then
    # Older claude version without sessions/<pid>.json — fallback via Python (cleaner than nested bash globs)
    python3 <<PYEOF
import os, json, sys, glob, subprocess

pid = $CLAUDE_PID
profile_dirs = """$PROFILE_DIRS""".strip().splitlines()
profile_dirs.append(os.path.expanduser('~/.claude'))

# Get the process's cwd via lsof
try:
    out = subprocess.check_output(['lsof', '-p', str(pid)], stderr=subprocess.DEVNULL).decode()
    proc_cwd = ''
    for line in out.splitlines():
        parts = line.split()
        if len(parts) > 8 and parts[3] == 'cwd':
            proc_cwd = ' '.join(parts[8:])
            break
except Exception:
    proc_cwd = ''

needle_pid = f'"pid":{pid}'
needle_sid = '"sessionId":'

for d in profile_dirs:
    proj = os.path.join(d, 'projects')
    if not os.path.isdir(proj):
        continue
    for entry in os.listdir(proj):
        edir = os.path.join(proj, entry)
        if not os.path.isdir(edir):
            continue
        for jsonl_path in glob.glob(os.path.join(edir, '*.jsonl')):
            try:
                with open(jsonl_path) as f:
                    first = f.readline()
            except Exception:
                continue
            if needle_pid in first and needle_sid in first:
                uuid = os.path.basename(jsonl_path).removesuffix('.jsonl')
                print(json.dumps({
                    'sessionId': uuid,
                    'cwd': proc_cwd or 'unknown',
                    'version': 'unknown',
                    'source_config_dir': d,
                    'fallback': True,
                }))
                sys.exit(0)

print(f'lookup-session: no sessions/<pid>.json found and no JSONL fallback match for pid={pid}', file=sys.stderr)
sys.exit(1)
PYEOF
    exit $?
fi

# Parse the sessions/<pid>.json.
# Source config dir is determined from the running Claude's PROCESS ENV
# (CLAUDE_CONFIG_DIR), NOT from the filesystem — some multi-profile setups
# hardlink projects/ across profiles, which makes filesystem-based source
# detection meaningless. Falls back to $HOME/.claude if the env var is unset.
python3 -c "
import json, os, sys, subprocess, re

with open('$SESSION_JSON') as f:
    d = json.load(f)

session_id = d.get('sessionId', '')
cwd = d.get('cwd', '')
version = d.get('version', '')

# Read source CLAUDE_CONFIG_DIR from the claude process's env via ps ewww.
# If unset → primary profile (\$HOME/.claude default).
source_dir = None
try:
    out = subprocess.check_output(['ps', 'ewww', str($CLAUDE_PID)], stderr=subprocess.DEVNULL).decode()
    m = re.search(r'CLAUDE_CONFIG_DIR=(\S+)', out)
    if m:
        source_dir = m.group(1)
    else:
        source_dir = os.path.expanduser('~/.claude')
except Exception:
    # PID might be dead; fall back to UNKNOWN
    source_dir = 'UNKNOWN'

print(json.dumps({
    'sessionId': session_id,
    'cwd': cwd,
    'version': version,
    'source_config_dir': source_dir,
    'fallback': False
}))
"
