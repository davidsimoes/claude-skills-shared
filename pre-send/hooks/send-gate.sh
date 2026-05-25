#!/usr/bin/env bash
# send-gate.sh — PreToolUse hook that blocks outbound-send tools
#                unless an approval flag exists from /pre-send.
#
# Wire it via settings.local.json with a PreToolUse matcher covering
# your send tools. See pre-send/SKILL.md "Setup" for the matcher example.
#
# Input via stdin (Claude Code hook contract):
#   {"tool_name": "...", "tool_input": {...}}
#
# Output:
#   exit 0 → allow
#   exit 2 → block (stderr message shown to user)

set -euo pipefail

FLAG="/tmp/claude-send-approved"
TTL_SECONDS=300   # 5 minutes — must match /pre-send skill expectation

# Read the hook payload (we don't need to parse it for matchers — settings.json
# does that — but we keep the read so stdin is fully consumed, not blocking
# Claude's tool dispatch).
INPUT="$(cat || true)"

# Autopilot escape hatch — for long-running unattended automations that
# legitimately need to send without per-message human approval.
# Set CLAUDE_AUTOPILOT_SESSION=1 or run inside a tmux session whose name
# starts with "autopilot" to opt in.
if [[ "${CLAUDE_AUTOPILOT_SESSION:-0}" == "1" ]]; then
  exit 0
fi

if command -v tmux >/dev/null 2>&1; then
  TMUX_SESS="$(tmux display-message -p '#S' 2>/dev/null || echo '')"
  if [[ "$TMUX_SESS" == autopilot* ]]; then
    exit 0
  fi
fi

# Check the approval flag.
if [[ ! -f "$FLAG" ]]; then
  cat >&2 <<EOF
🛑 send-gate: blocked.

No /pre-send approval found at $FLAG.

To send, run /pre-send first — it shows the final draft, requires explicit
"send it" confirmation, and creates the approval flag with a ${TTL_SECONDS}s TTL.

This hook structurally enforces "never send without explicit approval".
EOF
  exit 2
fi

# Check TTL — flag must be fresh.
NOW="$(date +%s)"
FLAG_MTIME="$(stat -f %m "$FLAG" 2>/dev/null || stat -c %Y "$FLAG" 2>/dev/null || echo 0)"
AGE=$((NOW - FLAG_MTIME))

if (( AGE > TTL_SECONDS )); then
  cat >&2 <<EOF
🛑 send-gate: blocked (stale approval).

Approval flag is ${AGE}s old; TTL is ${TTL_SECONDS}s. Re-run /pre-send to
re-approve the current draft (re-confirming after edits is the whole point).
EOF
  rm -f "$FLAG"
  exit 2
fi

# Approval is fresh — consume the flag (single-use) and allow.
# Single-use prevents one /pre-send approval from cascading into multiple sends.
rm -f "$FLAG"
exit 0
