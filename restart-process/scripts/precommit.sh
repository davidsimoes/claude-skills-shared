#!/usr/bin/env bash
# precommit.sh — serialized central pre-commit of all dirty git repos before kill phase.
#
# Reads inventory JSON on stdin (output of snapshot.sh --phase=1) and:
#   1. Extracts unique git roots from each pane's cwd
#   2. For each root: checks `git status --porcelain` for dirty state
#   3. Optionally commits (gated by --auto or --interactive mode)
#   4. Optionally pushes (tolerates no-upstream — records state, continues)
#
# Done CENTRALLY here so the panes' claude processes don't need to commit themselves
# (eliminates the permission-prompt + mid-task class of failures from R1 audit).
#
# Usage:
#   cat inventory.json | precommit.sh --auto    # commit-all with WIP message
#   cat inventory.json | precommit.sh --dry-run # show what would be committed
#   cat inventory.json | precommit.sh --interactive  # ask per repo (not used by orchestrator)
#
# Output: NDJSON to stdout, one line per repo with action taken:
#   {"repo":"<path>","branch":"<branch>","action":"committed|pushed|skipped|clean|failed",
#    "n_files":N,"commit_sha":"...","push_status":"ok|no-upstream|failed:<reason>"}
#
# Exit codes:
#   0 = all repos handled (each line is OK or recorded failure)
#   1 = bad args / bad inventory
#   2 = catastrophic failure (some repo's git invocation hung)

set -uo pipefail

MODE="--auto"
if [ "$#" -ge 1 ]; then
    case "$1" in
        --auto|--dry-run|--interactive) MODE="$1" ;;
        *) echo "ERROR: bad mode: $1 (want --auto|--dry-run|--interactive)" >&2; exit 1 ;;
    esac
fi

# Read inventory from stdin
INVENTORY=$(cat)
if [ -z "$INVENTORY" ]; then
    echo "ERROR: no inventory on stdin" >&2
    exit 1
fi

# Extract unique git roots from each pane's cwd
ROOTS=$(echo "$INVENTORY" | python3 -c "
import json, os, sys, subprocess
inv = json.load(sys.stdin)
seen = set()
roots = []
for w in inv.get('windows', []):
    for p in w.get('panes', []):
        cwd = p.get('cwd') or p.get('pane_path')
        if not cwd or not os.path.isdir(cwd):
            continue
        try:
            r = subprocess.run(['git', '-C', cwd, 'rev-parse', '--show-toplevel'],
                              capture_output=True, text=True, timeout=5)
            if r.returncode == 0:
                root = r.stdout.strip()
                if root and root not in seen:
                    seen.add(root)
                    roots.append(root)
        except Exception:
            continue
print('\n'.join(roots))
")

if [ -z "$ROOTS" ]; then
    echo "(no git roots discovered in inventory)" >&2
    exit 0
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
COMMIT_MSG="WIP: pre-restart snapshot $TIMESTAMP"

echo "$ROOTS" | while IFS= read -r repo; do
    [ -z "$repo" ] && continue
    [ ! -d "$repo/.git" ] && continue

    branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "DETACHED")
    porcelain=$(git -C "$repo" status --porcelain 2>/dev/null || echo "")
    n_files=$(echo -n "$porcelain" | grep -c '^' || true)

    if [ -z "$porcelain" ]; then
        printf '{"repo":"%s","branch":"%s","action":"clean","n_files":0}\n' "$repo" "$branch"
        continue
    fi

    if [ "$MODE" = "--dry-run" ]; then
        printf '{"repo":"%s","branch":"%s","action":"would_commit","n_files":%d}\n' "$repo" "$branch" "$n_files"
        continue
    fi

    # Commit
    if ! git -C "$repo" add -A 2>/dev/null; then
        printf '{"repo":"%s","branch":"%s","action":"failed","n_files":%d,"reason":"git add failed"}\n' "$repo" "$branch" "$n_files"
        continue
    fi
    # Use --no-verify? NO — per CLAUDE.md, never skip hooks unless explicitly asked.
    if ! commit_out=$(git -C "$repo" commit -m "$COMMIT_MSG" 2>&1); then
        # Check if it's a pre-commit hook failure
        printf '{"repo":"%s","branch":"%s","action":"failed","n_files":%d,"reason":"commit failed: %s"}\n' \
            "$repo" "$branch" "$n_files" "$(echo "$commit_out" | head -3 | tr '\n' ' ' | sed 's/"/\\"/g')"
        continue
    fi
    sha=$(git -C "$repo" rev-parse HEAD 2>/dev/null || echo "unknown")

    # Push (tolerate no-upstream)
    push_status="ok"
    if ! git -C "$repo" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
        push_status="no-upstream"
    elif ! push_out=$(git -C "$repo" push 2>&1); then
        # Truncate push error for JSON safety
        push_status="failed:$(echo "$push_out" | head -2 | tr '\n' ' ' | head -c 200 | sed 's/"/\\"/g')"
    fi

    printf '{"repo":"%s","branch":"%s","action":"committed","n_files":%d,"commit_sha":"%s","push_status":"%s"}\n' \
        "$repo" "$branch" "$n_files" "$sha" "$push_status"
done

exit 0
