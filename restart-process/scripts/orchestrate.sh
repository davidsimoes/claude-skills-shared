#!/usr/bin/env bash
# orchestrate.sh — top-level driver for /restart-process.
#
# Runs the full capture pipeline (phases A → F) and prints final handoff. Does NOT
# kill the orchestrator's own claude session — the user handles reboot themselves,
# which kills everything including this pane.
#
# Usage:
#   orchestrate.sh [--dry-run] [--skip-updates] [--skip-precommit]
#
# Phases (each writes to log; abort on any failure before kill phase F):
#   PRE   — acquire lock, self-locate, prune old dirs
#   A     — Inventory (snapshot.sh --phase=1)
#   A0    — Non-tmux Claude detection (pgrep -af claude minus tmux-discovered set)
#   B     — Handoff extraction (extract-handoff.sh per claude pane, parallel batches)
#           B-self captures self handoff from current JSONL inline
#   C     — Pre-commit (precommit.sh --auto)
#   D     — Write launchers, then write manifest (atomic, checksummed)
#   E     — Updates: claude --upgrade + brew upgrade --quiet
#   F     — Kill phase: SIGTERM 10s grace → SIGKILL stragglers (ALL claude PIDs except self)
#   FINAL — Print handoff for the user
#
# Exit codes:
#   0 = capture complete, ready for reboot
#   1 = bad args / pre-flight failure
#   2 = abort in capture phases A-D (no work destroyed)
#   3 = partial failure in updates/kill phases E-F (manifest still valid)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# All helper scripts now live alongside this one (no external skill dependency).
HELPER_SCRIPTS="$SCRIPT_DIR"
# Root for archive dirs + per-run logs. Override via RESTART_HANDOFFS_DIR env var.
HANDOFFS_ROOT="${RESTART_HANDOFFS_DIR:-$HOME/.cache/claude-restart}"
TS="$(date -u +%Y-%m-%dT%H%M%SZ)"
RUN_DIR="$HANDOFFS_ROOT/$TS"
LOG_DIR="$HANDOFFS_ROOT/logs"
LOG="$LOG_DIR/run-$TS.log"
LOCKDIR="/tmp/restart-process.lock.d"
mkdir -p "$RUN_DIR" "$LOG_DIR"

# Modes
DRY_RUN=0
SKIP_UPDATES=0
SKIP_PRECOMMIT=0
SELF_HANDOFF_SOURCE_INPUT=""

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --skip-updates) SKIP_UPDATES=1; shift ;;
        --skip-precommit) SKIP_PRECOMMIT=1; shift ;;
        --self-handoff) SELF_HANDOFF_SOURCE_INPUT="$2"; shift 2 ;;
        *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
    esac
done

# Validate --self-handoff if provided
if [ -n "$SELF_HANDOFF_SOURCE_INPUT" ] && [ ! -r "$SELF_HANDOFF_SOURCE_INPUT" ]; then
    echo "ERROR: --self-handoff file not readable: $SELF_HANDOFF_SOURCE_INPUT" >&2
    exit 1
fi

# Logging helpers
mkdir -p "$(dirname "$LOG")"
log() {
    local msg="[$(date -u +%H:%M:%SZ)] $*"
    echo "$msg" | tee -a "$LOG" >&2
}
die() {
    log "FATAL: $*"
    exit "${2:-1}"
}

log "=== /restart-process starting (dry_run=$DRY_RUN, skip_updates=$SKIP_UPDATES, skip_precommit=$SKIP_PRECOMMIT) ==="
log "log: $LOG"
log "run dir: $RUN_DIR"

# ============================================================
# PRE: Lock, self-locate, prune
# ============================================================
log "PRE: acquiring lock"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
    if [ -f "$LOCKDIR/pid" ] && kill -0 "$(cat "$LOCKDIR/pid" 2>/dev/null)" 2>/dev/null; then
        die "another /restart-process running (pid $(cat "$LOCKDIR/pid"))"
    fi
    log "WARN: stale lock, stealing"
    rm -rf "$LOCKDIR"
    mkdir "$LOCKDIR"
fi
echo $$ > "$LOCKDIR/pid"
# shellcheck disable=SC2064  # $LOCKDIR resolved at trap-install time intentionally
trap "rm -rf '$LOCKDIR'" EXIT

# Self-locate
if [ -z "${TMUX:-}" ]; then
    die "not running inside tmux — /restart-process requires a tmux session"
fi
OWN_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}')
OWN_WINDOW=$(tmux display-message -p '#{session_name}:#{window_index}')
OWN_CWD=$(tmux display-message -p '#{pane_current_path}')
CLAUDE_BIN=$(command -v claude || die "claude binary not in PATH")
log "self: pane=$OWN_PANE cwd=$OWN_CWD claude=$CLAUDE_BIN"

# Prune old runs (background, non-blocking)
log "PRE: pruning old handoff dirs (>30d)"
"$SCRIPT_DIR/prune.sh" 2>&1 | tee -a "$LOG" > /dev/null || true

mkdir -p "$RUN_DIR"
log "PRE: created $RUN_DIR"

# ============================================================
# A: Inventory
# ============================================================
log "PHASE A: inventory (via snapshot.sh)"
INVENTORY_JSON="$RUN_DIR/inventory.json"
if ! "$HELPER_SCRIPTS/snapshot.sh" --phase=1 > "$INVENTORY_JSON" 2>>"$LOG"; then
    die "inventory failed — see log" 2
fi

# Sanity-check inventory schema BEFORE downstream consumption — snapshot.sh
# is shared infra and may be modified by other workflows. If required fields are missing,
# fail loud + early rather than silently breaking downstream Phase B / D logic.
if ! python3 - "$INVENTORY_JSON" <<'PYEOF'
import json, sys
inv = json.load(open(sys.argv[1]))
errors = []
if 'windows' not in inv or not isinstance(inv['windows'], list):
    errors.append("missing or non-list 'windows' field")
for i, w in enumerate(inv.get('windows', [])):
    for k in ('session', 'window_index', 'window_name', 'window_layout', 'panes'):
        if k not in w:
            errors.append(f"window[{i}] missing required field '{k}'")
    for j, p in enumerate(w.get('panes', [])):
        for k in ('pane_index', 'pane_pid', 'pane_path'):
            if k not in p:
                errors.append(f"window[{i}].panes[{j}] missing required field '{k}'")
if errors:
    print("INVENTORY SCHEMA MISMATCH:", file=sys.stderr)
    for e in errors[:10]:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(2)
PYEOF
then
    die "snapshot.sh output schema validation failed — see log" 2
fi

N_WINDOWS=$(python3 -c "import json; print(len(json.load(open('$INVENTORY_JSON'))['windows']))")
N_CLAUDE=$(python3 -c "
import json
inv = json.load(open('$INVENTORY_JSON'))
n = sum(1 for w in inv['windows'] for p in w['panes'] if p.get('claude_pid'))
print(n)
")
log "PHASE A: found $N_WINDOWS windows, $N_CLAUDE claude panes"

# ============================================================
# A0: Non-tmux Claude detection
# ============================================================
log "PHASE A0: non-tmux claude scan"
TMUX_CLAUDE_PIDS=$(python3 -c "
import json
inv = json.load(open('$INVENTORY_JSON'))
pids = set()
for w in inv['windows']:
    for p in w['panes']:
        if p.get('claude_pid'):
            pids.add(p['claude_pid'])
print(' '.join(str(x) for x in pids))
")
# pgrep all claude PIDs system-wide
ALL_CLAUDE_PIDS=$(pgrep -f '(^|/)claude($| )' 2>/dev/null | tr '\n' ' ' || echo "")
EXTRAS=""
for pid in $ALL_CLAUDE_PIDS; do
    # skip our own pid + ancestors
    [ "$pid" = "$$" ] && continue
    # skip if already in tmux set
    if ! echo " $TMUX_CLAUDE_PIDS " | grep -q " $pid "; then
        # also skip ourselves (orchestrator process)
        EXTRAS="$EXTRAS $pid"
    fi
done
if [ -n "$EXTRAS" ]; then
    log "WARN: non-tmux claude processes detected: $EXTRAS"
    log "      (these will NOT be captured — close them manually after reboot if needed)"
fi

# ============================================================
# B: Handoff extraction (parallel batches)
# ============================================================
log "PHASE B: extracting handoffs (Opus subagents, parallel batches of 4)"

# Helper to compute pane_key (matches write-manifest.py)
pane_key() {
    local session="$1"; local wi="$2"; local pi="$3"
    local safe
    safe=$(echo "$session" | sed 's|/|-|g; s| |_|g')
    echo "${safe}-${wi}-${pi}"
}

# Identify orchestrator pane and skip extracting handoff via subagent for self
# (we'll write self handoff inline from this orchestrator's own context)

# Extract per pane (non-self)
python3 - "$INVENTORY_JSON" "$RUN_DIR" "$OWN_PANE" "$LOG" <<'PYEOF' > "$RUN_DIR/handoff-tasks.txt"
import json, sys
inv_path, run_dir, own_pane, log = sys.argv[1:]
inv = json.load(open(inv_path))
for w in inv['windows']:
    for p in w['panes']:
        if not p.get('claude_pid'):
            continue
        session = w['session']
        wi = w['window_index']
        pi = p['pane_index']
        target = f"{session}:{wi}.{pi}"
        if target == own_pane:
            continue  # self - handled inline
        safe = session.replace('/', '-').replace(' ', '_')
        key = f"{safe}-{wi}-{pi}"
        jsonl_dir = ""
        cwd = p.get('cwd') or p.get('pane_path') or ''
        # We'll let extract-handoff.sh resolve JSONL via escape-cwd.py
        sid = p.get('sessionId', '')
        print(f"{target}|{key}|{cwd}|{sid}")
PYEOF

# For each (target|key|cwd|sessionId), find JSONL and call extract-handoff
BATCH_SIZE=4
running=0
pids=()

while IFS='|' read -r target key cwd sid; do
    [ -z "$target" ] && continue
    # Find JSONL: ~/.claude*/projects/<escaped-cwd>/<sid>.jsonl
    ESCAPED=$(python3 "$HELPER_SCRIPTS/escape-cwd.py" "$cwd")
    JSONL=""
    # Build candidate Claude config dirs: $CLAUDE_CONFIG_DIR (or ~/.claude) plus
    # any colon-separated entries in $CLAUDE_CONFIG_DIRS (multi-profile setups).
    CANDIDATE_DIRS=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}")
    if [ -n "${CLAUDE_CONFIG_DIRS:-}" ]; then
        IFS=':' read -ra extra <<< "$CLAUDE_CONFIG_DIRS"
        CANDIDATE_DIRS+=("${extra[@]}")
    fi
    for cd in "${CANDIDATE_DIRS[@]}"; do
        candidate="$cd/projects/$ESCAPED/$sid.jsonl"
        if [ -r "$candidate" ]; then
            JSONL="$candidate"
            break
        fi
    done
    if [ -z "$JSONL" ]; then
        # Fallback: glob newest .jsonl in escaped dir
        for cd in "${CANDIDATE_DIRS[@]}"; do
            candidate=$(ls -t "$cd/projects/$ESCAPED/"*.jsonl 2>/dev/null | head -1)
            if [ -n "$candidate" ] && [ -r "$candidate" ]; then
                JSONL="$candidate"
                log "WARN: $target — sessionId match not found, using newest mtime: $JSONL"
                break
            fi
        done
    fi
    if [ -z "$JSONL" ]; then
        log "ERROR: $target — could not locate JSONL (escaped=$ESCAPED, sid=$sid)"
        # Write a placeholder handoff so write-manifest doesn't fail
        cat > "$RUN_DIR/handoff-$key.md" <<EOF
# Session handoff: extraction failed

## Last action
Unable to locate session JSONL for cwd: $cwd (escaped: $ESCAPED, sessionId: $sid).

## Next step
Re-establish context manually — read recent git log + open files in $cwd.

## Files touched
- unknown

## Blockers / open questions
- handoff extraction failed during capture

## Uncommitted intent
unknown

## Was busy at capture
unknown

## Transcript (full)
not found
EOF
        continue
    fi

    # Git status for this cwd
    GIT_STATUS=$(cd "$cwd" && git status --porcelain 2>/dev/null | head -20 || echo "(not a git repo)")

    # Spawn extract-handoff in background
    (
        "$SCRIPT_DIR/extract-handoff.sh" "$JSONL" "$cwd" "$RUN_DIR/handoff-$key.md" "$GIT_STATUS" 2>>"$LOG"
    ) &
    pids+=($!)
    running=$((running + 1))
    if [ $running -ge $BATCH_SIZE ]; then
        wait "${pids[@]}"
        pids=()
        running=0
    fi
done < "$RUN_DIR/handoff-tasks.txt"

# Wait for remaining
if [ ${#pids[@]} -gt 0 ]; then
    wait "${pids[@]}"
fi
log "PHASE B: handoff extraction complete"

# B-self: write orchestrator handoff inline
SELF_KEY=$(python3 - "$OWN_PANE" <<'PYEOF'
import sys
own = sys.argv[1]
session, wp = own.split(':')
wi, pi = wp.split('.')
safe = session.replace('/', '-').replace(' ', '_')
print(f"{safe}-{wi}-{pi}")
PYEOF
)
log "PHASE B-self: orchestrator pane_key=$SELF_KEY"
# Orchestrator handoff comes from --self-handoff <path> (preferred) OR
# from $RUN_DIR/self-handoff-source.md (legacy marker file pattern).
# The SKILL.md flow should ALWAYS pass --self-handoff <path> — placeholder is just a safety net.
SELF_HANDOFF_SOURCE="${SELF_HANDOFF_SOURCE_INPUT:-$RUN_DIR/self-handoff-source.md}"
if [ -r "$SELF_HANDOFF_SOURCE" ]; then
    cp "$SELF_HANDOFF_SOURCE" "$RUN_DIR/handoff-$SELF_KEY.md"
    log "PHASE B-self: copied self handoff from $SELF_HANDOFF_SOURCE"
else
    # Fall back to a placeholder
    cat > "$RUN_DIR/handoff-$SELF_KEY.md" <<EOF
# Session handoff: orchestrator (placeholder)

## Last action
Ran /restart-process to capture all sessions for reboot.

## Next step
Verify /restart-resume completed successfully. Check that all sessions respawned with handoffs as first message.

## Files touched
- ~/.claude/skills/restart-process/
- ~/.claude/skills/restart-resume/

## Blockers / open questions
- none

## Uncommitted intent
Check git status if anything dirty.

## Was busy at capture
false

## Transcript (full)
This was the orchestrator — full transcript in current session JSONL.
EOF
fi

# ============================================================
# C: Pre-commit
# ============================================================
if [ "$SKIP_PRECOMMIT" = "1" ]; then
    log "PHASE C: SKIPPED (--skip-precommit)"
else
    log "PHASE C: pre-committing dirty repos (--auto, WIP messages)"
    if [ "$DRY_RUN" = "1" ]; then
        < "$INVENTORY_JSON" "$SCRIPT_DIR/precommit.sh" --dry-run 2>&1 | tee -a "$LOG" > "$RUN_DIR/precommit-results.ndjson"
    else
        < "$INVENTORY_JSON" "$SCRIPT_DIR/precommit.sh" --auto 2>&1 | tee -a "$LOG" > "$RUN_DIR/precommit-results.ndjson"
    fi
    log "PHASE C: results in $RUN_DIR/precommit-results.ndjson"
fi

# ============================================================
# D: Write launchers + manifest
# ============================================================
log "PHASE D1: writing per-pane launchers"
if ! "$SCRIPT_DIR/write-launchers.sh" "$RUN_DIR" "$INVENTORY_JSON" "$CLAUDE_BIN" >> "$LOG" 2>&1; then
    die "write-launchers failed — see log" 2
fi

log "PHASE D2: writing manifest (atomic, checksummed)"
CAPTURED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MANIFEST_RESULT=$(< "$INVENTORY_JSON" "$SCRIPT_DIR/write-manifest.py" \
    --manifest-dir "$RUN_DIR" \
    --orchestrator-pane "$OWN_PANE" \
    --orchestrator-cwd "$OWN_CWD" \
    --captured-at "$CAPTURED_AT" \
    --claude-binary-path "$CLAUDE_BIN" \
    --resume-orchestrator-cwd "$HOME/.claude" 2>>"$LOG") || die "write-manifest failed" 2

echo "$MANIFEST_RESULT" | tee -a "$LOG"

# Update `latest` symlink
ln -sfn "$TS" "$HANDOFFS_ROOT/latest"
log "PHASE D: latest → $TS"

if [ "$DRY_RUN" = "1" ]; then
    log "DRY RUN — stopping before updates and kill phases"
    log "Manifest at $RUN_DIR/manifest.json"
    exit 0
fi

# ============================================================
# E: Updates
# ============================================================
if [ "$SKIP_UPDATES" = "1" ]; then
    log "PHASE E: SKIPPED (--skip-updates)"
else
    log "PHASE E1: claude --upgrade"
    if ! claude --upgrade 2>&1 | tee -a "$LOG"; then
        log "WARN: claude --upgrade failed — continuing"
    fi

    log "PHASE E2: brew upgrade (may take a few minutes)"
    if command -v brew >/dev/null 2>&1; then
        if ! brew upgrade --quiet 2>&1 | tee -a "$LOG"; then
            log "WARN: brew upgrade had issues — continuing"
        fi
    else
        log "WARN: brew not in PATH, skipping"
    fi
fi

# ============================================================
# F: Graceful close per pane (tmux send-keys /close + auto-exit), kill fallback
# ============================================================
log "PHASE F: graceful /close per pane (with SIGTERM+SIGKILL fallback for stragglers)"
SELF_PID=$$
# Find ancestor claude PID (the one running THIS script) so we never kill ourselves
ORCHESTRATOR_CLAUDE_PID=""
p=$$
while [ "$p" != "1" ] && [ -n "$p" ]; do
    cmd=$(ps -o command= -ww -p "$p" 2>/dev/null || echo "")
    if echo "$cmd" | grep -Eq '(^|/)claude($| )'; then
        ORCHESTRATOR_CLAUDE_PID="$p"
        break
    fi
    p=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [ -z "$p" ] && break
done
log "orchestrator's own claude PID: ${ORCHESTRATOR_CLAUDE_PID:-(none, not inside claude?)}"

# Build list of (tmux_pane_target, claude_pid) for every claude pane EXCEPT self
PANES_TO_CLOSE=$(python3 - "$INVENTORY_JSON" "${ORCHESTRATOR_CLAUDE_PID:-0}" "$OWN_PANE" <<'PYEOF'
import json, sys
inv = json.load(open(sys.argv[1]))
self_pid = int(sys.argv[2])
own_pane = sys.argv[3]
for w in inv['windows']:
    for p in w['panes']:
        cpid = p.get('claude_pid')
        if not cpid or cpid == self_pid:
            continue
        target = f"{w['session']}:{w['window_index']}.{p['pane_index']}"
        if target == own_pane:
            continue
        print(f"{target}|{cpid}")
PYEOF
)

if [ -z "$PANES_TO_CLOSE" ]; then
    log "PHASE F: no other claude panes to close"
else
    log "PHASE F: gracefully closing $(echo "$PANES_TO_CLOSE" | wc -l | tr -d ' ') panes via /close + /exit"

    # Step 1: send /close to each pane in parallel (it's a per-pane skill, no cross-pane contention)
    echo "$PANES_TO_CLOSE" | while IFS='|' read -r target cpid; do
        [ -z "$target" ] && continue
        log "  /close → $target (pid $cpid)"
        # Clear any in-flight input first (C-u clears the line)
        tmux send-keys -t "$target" C-u 2>/dev/null || true
        sleep 0.2
        tmux send-keys -t "$target" "/close" Enter 2>/dev/null || log "    WARN: send-keys /close failed for $target"
    done

    # Step 2: wait up to 90s for graceful exits (poll PID death)
    log "PHASE F: waiting up to 90s for /close completions (polling every 5s)"
    WAITED=0
    while [ "$WAITED" -lt 90 ]; do
        sleep 5
        WAITED=$((WAITED + 5))
        # Count survivors
        SURVIVORS=""
        while IFS='|' read -r target cpid; do
            [ -z "$target" ] && continue
            if kill -0 "$cpid" 2>/dev/null; then
                SURVIVORS="$SURVIVORS $cpid"
            fi
        done <<< "$PANES_TO_CLOSE"
        N=$(echo "$SURVIVORS" | wc -w | tr -d ' ')
        log "  ${WAITED}s elapsed — $N panes still alive"
        [ "$N" = "0" ] && break
    done

    # Step 3: for stragglers, send /exit (claude's hard-exit slash command)
    REMAINING=""
    while IFS='|' read -r target cpid; do
        [ -z "$target" ] && continue
        if kill -0 "$cpid" 2>/dev/null; then
            REMAINING="$REMAINING $target|$cpid\n"
            log "  /exit → $target (still alive after 90s)"
            tmux send-keys -t "$target" C-u 2>/dev/null || true
            sleep 0.2
            tmux send-keys -t "$target" "/exit" Enter 2>/dev/null || true
        fi
    done <<< "$PANES_TO_CLOSE"

    if [ -n "$REMAINING" ]; then
        log "PHASE F: sleeping 15s for /exit to take effect"
        sleep 15

        # Step 4: SIGTERM stragglers
        while IFS='|' read -r target cpid; do
            [ -z "$target" ] && continue
            if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null; then
                log "  SIGTERM → $target (pid $cpid) after /exit failed"
                kill -TERM "$cpid" 2>/dev/null || true
            fi
        done <<< "$(printf '%b' "$REMAINING")"
        sleep 10

        # Step 5: SIGKILL final stragglers
        while IFS='|' read -r target cpid; do
            [ -z "$target" ] && continue
            if [ -n "$cpid" ] && kill -0 "$cpid" 2>/dev/null; then
                log "  SIGKILL → $target (pid $cpid) — graceful close failed entirely"
                kill -KILL "$cpid" 2>/dev/null || true
            fi
        done <<< "$(printf '%b' "$REMAINING")"
    fi

    log "PHASE F: close complete"
fi

# ============================================================
# FINAL
# ============================================================
N_SESSIONS=$(python3 -c "
import json
inv = json.load(open('$INVENTORY_JSON'))
sessions = set(w['session'] for w in inv['windows'])
print(len(sessions))
")
N_CAPTURED=$N_CLAUDE
CHECKSUM=$(python3 -c "import json; print(json.load(open('$RUN_DIR/manifest.json'))['checksum'])")

log "=== /restart-process complete ==="
log "captured: $N_CAPTURED claude panes across $N_SESSIONS tmux sessions"
log "manifest: $RUN_DIR/manifest.json"
log "checksum: $CHECKSUM"
log "latest:   $HANDOFFS_ROOT/latest -> $TS"

cat <<EOF

✅ Captured $N_CAPTURED claude panes across $N_SESSIONS tmux sessions.
   Manifest: $RUN_DIR/manifest.json
   Updates:  $([ "$SKIP_UPDATES" = "1" ] && echo "skipped" || echo "claude --upgrade + brew upgrade ran")

🔄 Your turn: type \`sudo reboot\` (or \`reboot\` if no sudo needed) in any terminal.

🆕 Post-reboot: open a fresh terminal, then:
     cd ~/.claude && claude
   The SessionStart hook will detect the pending manifest and auto-invoke /restart-resume.
   Every session respawns under a fresh claude process with its handoff as first user message.

EOF

exit 0
