#!/usr/bin/env bash
# extract-handoff.sh — read a session JSONL, produce handoff.md via OPUS subagent.
#
# Usage:
#   extract-handoff.sh <jsonl_path> <cwd> <out_handoff_md> [<git_status_summary>]
#
# Truncates input to last 50 message entries (~30k tokens) to keep prompt size
# bounded. Invokes `claude -p` in print mode under OPUS for high-stakes extraction
# (handoff is load-bearing — a confabulated next_step means waking to wrong context).
#
# Output schema (rendered as markdown in <out_handoff_md>):
#   # Session handoff: <one-line summary>
#
#   ## Last action
#   <what we just did in the last few exchanges>
#
#   ## Next step
#   <concrete first action on resume>
#
#   ## Files touched
#   - <paths>
#
#   ## Blockers / open questions
#   - <items>
#
#   ## Uncommitted intent
#   <if dirty: what these uncommitted changes are for, else "none">
#
#   ## Was busy at capture
#   <true | false>
#
#   ## Transcript (full)
#   <abs path to JSONL>
#
# Exit codes:
#   0 = handoff written
#   1 = bad args
#   2 = JSONL not readable
#   3 = subagent invocation failed (timeout, no output, error)

set -uo pipefail

JSONL="${1:?usage: extract-handoff.sh <jsonl_path> <cwd> <out_handoff_md> [<git_status_summary>]}"
CWD="${2:?missing cwd}"
OUT="${3:?missing output path}"
GIT_STATUS="${4:-}"

if [ ! -r "$JSONL" ]; then
    echo "ERROR: cannot read JSONL: $JSONL" >&2
    exit 2
fi

# Truncate JSONL to last 50 lines (each line is one message entry)
TRUNCATED=$(mktemp)
trap 'rm -f "$TRUNCATED"' EXIT
tail -n 50 "$JSONL" > "$TRUNCATED"

PROMPT=$(cat <<'EOF'
You are reading the tail of a Claude Code session transcript (JSONL). Extract a
handoff that will be the FIRST USER MESSAGE in a fresh Claude session after a
system reboot. The new Claude will have ZERO context — your handoff is the bridge.

Output a markdown file with EXACTLY this structure (no preamble, no commentary):

# Session handoff: <one-sentence summary of what this session is working on>

## Last action
<what was just done in the last few exchanges, ~2-3 sentences>

## Next step
<the concrete first action on resume — what should the new Claude do immediately?>

## Files touched
- <list of file paths mentioned/edited in recent exchanges, absolute paths preferred>
(or "- none" if no files touched)

## Blockers / open questions
- <anything waiting on user input, external state, or unresolved decisions>
(or "- none")

## Uncommitted intent
<if the git status summary below shows uncommitted work, explain what these changes
are for in 1-2 sentences. Otherwise write "none">

## Was busy at capture
<true if the session appeared to be mid-tool-call or mid-thought when captured, else false>

## Transcript (full)
<the absolute path of the JSONL provided>

---

CRITICAL RULES:
- Do NOT invent facts. If something is unclear from the transcript, mark it
  "unclear from transcript".
- Be terse. The new Claude session will read this as its first input — do not
  bury the lede in fluff.
- Preserve concrete identifiers: file paths, function names, IDs, URLs, error
  messages. Drop chatty narration.
- "Next step" must be actionable in 1-2 minutes. If the session was mid-decision,
  state both branches and let the user pick.
EOF
)

# Build the actual prompt for the subagent
FULL_PROMPT=$(cat <<EOF
$PROMPT

== SESSION CONTEXT ==
cwd: $CWD
JSONL path: $JSONL
git status summary:
${GIT_STATUS:-(no dirty changes)}

== TRANSCRIPT (last 50 entries) ==
$(cat "$TRUNCATED")
EOF
)

# Invoke claude -p with opus, capture output to OUT atomically
# Note: claude -p is the print mode (one-shot, no REPL).
# --model opus forces opus (handoff is high-stakes per goal constraint).
TMP_OUT=$(mktemp)
trap 'rm -f "$TRUNCATED" "$TMP_OUT"' EXIT

if ! printf '%s' "$FULL_PROMPT" | timeout 180 claude -p --model opus > "$TMP_OUT" 2>&1; then
    echo "ERROR: claude -p invocation failed or timed out (180s)" >&2
    cat "$TMP_OUT" >&2
    exit 3
fi

if [ ! -s "$TMP_OUT" ]; then
    echo "ERROR: subagent returned empty output" >&2
    exit 3
fi

# Validate output has expected headers (cheap sanity check)
if ! grep -q "^# Session handoff:" "$TMP_OUT" || ! grep -q "^## Next step" "$TMP_OUT"; then
    echo "WARN: subagent output missing expected headers — saving anyway" >&2
fi

# Atomic-write the handoff
mv "$TMP_OUT" "$OUT.tmp"
mv "$OUT.tmp" "$OUT"

LINES=$(wc -l < "$OUT")
echo "wrote ${LINES// /} lines to $OUT" >&2
exit 0
