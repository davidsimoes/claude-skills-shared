#!/usr/bin/env bash
# snapshot.sh — Phases 0+1: lock, self-locate, enumerate panes, build inventory
# Outputs JSON inventory to stdout.

set -uo pipefail

PHASE="${1:-all}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCKDIR="/tmp/restart-process.lock.d"

# --- Phase 0 ---

acquire_lock() {
    if mkdir "$LOCKDIR" 2>/dev/null; then
        echo $$ > "$LOCKDIR/pid"
    else
        if [ -f "$LOCKDIR/pid" ] && kill -0 "$(cat "$LOCKDIR/pid" 2>/dev/null)" 2>/dev/null; then
            echo "ERROR: another /restart-process is running (pid $(cat "$LOCKDIR/pid")). Refusing to start." >&2
            exit 1
        else
            echo "WARN: stale lock found (owner pid $(cat "$LOCKDIR/pid" 2>/dev/null) dead). Stealing." >&2
            rm -rf "$LOCKDIR"
            mkdir "$LOCKDIR"
            echo $$ > "$LOCKDIR/pid"
        fi
    fi
    trap 'rm -rf "$LOCKDIR"' EXIT HUP INT TERM
}

self_locate() {
    # Use $TMUX_PANE env var (set by tmux for any process running inside a pane)
    # to identify the calling pane reliably. `tmux display-message -p` without -t
    # resolves to whichever pane tmux considers focused — which may be a different
    # pane than the one running this subprocess when invoked from a non-attached
    # context (e.g. via `tmux send-keys` from another pane). Caught 2026-05-25
    # when a parent-poll context made own_window detection flip-flop between
    # caller's pane and parent's pane across separate invocations.
    if [ -n "${TMUX_PANE:-}" ]; then
        OWN_PANE=$(tmux display-message -t "$TMUX_PANE" -p "#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null || echo "NONE")
        OWN_WINDOW=$(tmux display-message -t "$TMUX_PANE" -p "#{session_name}:#{window_index}" 2>/dev/null || echo "NONE")
    else
        OWN_PANE=$(tmux display-message -p "#{session_name}:#{window_index}.#{pane_index}" 2>/dev/null || echo "NONE")
        OWN_WINDOW=$(tmux display-message -p "#{session_name}:#{window_index}" 2>/dev/null || echo "NONE")
    fi
    TARGET_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
    TARGET_VERSION=$(claude --version 2>/dev/null || echo "UNKNOWN")

    if [ ! -d "$TARGET_DIR" ]; then
        echo "ERROR: target CLAUDE_CONFIG_DIR=$TARGET_DIR does not exist" >&2
        exit 1
    fi

    # Walk process tree upward to detect if we're inside a claude session
    pid=$$
    found_claude=""
    while [ "$pid" != "1" ] && [ "$pid" != "0" ] && [ -n "$pid" ]; do
        cmd=$(ps -o command= -ww -p "$pid" 2>/dev/null || echo "")
        if echo "$cmd" | grep -Eq '(^|/)claude($| )'; then
            found_claude="$pid: $cmd"
            break
        fi
        pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
        [ -z "$pid" ] && break
    done

    cat <<EOF >&2
=== /restart-process Phase 0 ===
Lock acquired: $LOCKDIR (pid $$)
Own pane:     $OWN_PANE
Own window:   $OWN_WINDOW (will be excluded from capture)
Target dir:   $TARGET_DIR
Target ver:   $TARGET_VERSION
EOF

    if [ -n "$found_claude" ]; then
        cat <<EOF >&2

WARNING: /restart-process is running inside a claude session ($found_claude).
This window's claude IS the orchestrator and will not appear in the captured inventory.
That's expected if you're invoking /restart-process from inside a Claude session —
proceed. If you wanted a fresh terminal, abort and start over.

Proceed? [y/N]
EOF
        if [ -t 0 ]; then
            read -r ans
            [[ "$ans" == "y" || "$ans" == "Y" ]] || { echo "Aborted by user." >&2; exit 1; }
        else
            echo "(non-interactive — assuming proceed)" >&2
        fi
    fi
}

# --- Phase 1 ---

build_inventory() {
    # Defaults if Phase 0 didn't run (standalone --phase=1 invocation).
    # OWN_WINDOW must fall back to live tmux detection — without this, the calling pane
    # appears in the inventory as a migration target, which is wrong (caught 2026-05-07
    # when verification child saw itself).
    if [ -z "${OWN_WINDOW:-}" ] || [ "${OWN_WINDOW:-NONE}" = "NONE" ]; then
        # Use $TMUX_PANE if set (see self_locate above for rationale).
        if [ -n "${TMUX_PANE:-}" ]; then
            OWN_WINDOW=$(tmux display-message -t "$TMUX_PANE" -p "#{session_name}:#{window_index}" 2>/dev/null || echo "NONE")
        else
            OWN_WINDOW=$(tmux display-message -p "#{session_name}:#{window_index}" 2>/dev/null || echo "NONE")
        fi
    fi
    TARGET_DIR="${TARGET_DIR:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}}"
    TARGET_VERSION="${TARGET_VERSION:-$(claude --version 2>/dev/null || echo UNKNOWN)}"

    # Output: JSON array of windows, each with panes
    # Group by session:window (since we recreate per-window)

    local tmp=$(mktemp)
    # Format: session|win|pane|name|pane_pid|pane_path|window_layout|active
    tmux list-panes -a -F "#{session_name}|#{window_index}|#{pane_index}|#{window_name}|#{pane_pid}|#{pane_current_path}|#{window_layout}|#{pane_active}" > "$tmp"

    python3 <<PYEOF
import json, os, subprocess, sys, re

# Read panes
panes_raw = open("$tmp").read().splitlines()
own_window = "$OWN_WINDOW"

# Group by session:window
windows = {}
for line in panes_raw:
    if not line.strip():
        continue
    parts = line.split('|')
    if len(parts) < 8:
        continue
    sess, win_idx, pane_idx, win_name, pane_pid, pane_path, win_layout, active = parts[:8]
    key = f"{sess}:{win_idx}"
    if key == own_window:
        continue  # skip the skill's own window entirely
    if key not in windows:
        windows[key] = {
            "tmux_target": key,
            "session": sess,
            "window_index": int(win_idx),
            "window_name": win_name,
            "window_layout": win_layout,
            "panes": []
        }
    windows[key]["panes"].append({
        "pane_index": int(pane_idx),
        "pane_pid": int(pane_pid),
        "pane_path": pane_path,
        "active": active == "1"
    })

# For each pane, find claude PID. BSD pgrep -P has session restrictions and may miss
# children visible via ps. Use ps -ax + awk to enumerate children reliably.
def find_claude_pid(pane_pid):
    # Check pane_pid itself first (handles tmux new-window 'claude ...' case)
    try:
        cmd = subprocess.run(['ps', '-o', 'command=', '-ww', '-p', str(pane_pid)],
                            capture_output=True, text=True, timeout=5).stdout.strip()
        if re.search(r'(^|/)claude($| )', cmd):
            return pane_pid, cmd
    except Exception:
        pass
    # Enumerate children via full ps scan (more reliable than pgrep -P on macOS)
    try:
        out = subprocess.run(['ps', '-ax', '-o', 'pid=,ppid=,command='],
                            capture_output=True, text=True, timeout=10).stdout
        for line in out.splitlines():
            parts = line.strip().split(None, 2)
            if len(parts) < 3:
                continue
            pid_s, ppid_s, ccmd = parts
            try:
                if int(ppid_s) == pane_pid and re.search(r'(^|/)claude($| )', ccmd):
                    return int(pid_s), ccmd
            except ValueError:
                continue
    except Exception:
        pass
    return None, None

# Skip non-session claude
def is_session_claude(cmd):
    if not cmd:
        return False
    # Skip auth, -p, --print, --version, --help
    if re.search(r'(^|\s)(auth|--print|--version|--help)(\s|$)', cmd):
        return False
    if re.search(r'\s-p\s', cmd):
        return False
    return True

# Build per-pane claude metadata
skill_dir = os.path.dirname(os.path.realpath("$SKILL_DIR/snapshot.sh"))
non_session_count = 0

for key, w in windows.items():
    for p in w["panes"]:
        cpid, cmd = find_claude_pid(p["pane_pid"])
        if cpid is None:
            p["claude_pid"] = None
            p["non_claude"] = True
            continue
        if not is_session_claude(cmd):
            p["claude_pid"] = None
            p["non_session_claude"] = True
            p["cmd"] = cmd
            non_session_count += 1
            continue
        p["claude_pid"] = cpid
        p["cmd"] = cmd
        # Lookup session
        try:
            r = subprocess.run([f'{skill_dir}/lookup-session.sh', str(cpid)],
                              capture_output=True, text=True, timeout=10)
            if r.returncode == 0 and r.stdout.strip():
                meta = json.loads(r.stdout.strip())
                p.update(meta)
            else:
                p["lookup_failed"] = True
                p["lookup_stderr"] = r.stderr.strip()
        except Exception as e:
            p["lookup_failed"] = True
            p["lookup_error"] = str(e)

# Detect duplicate UUIDs (defensive)
seen_uuids = {}
for key, w in windows.items():
    for p in w["panes"]:
        sid = p.get("sessionId")
        if sid:
            if sid in seen_uuids:
                p["duplicate_of"] = seen_uuids[sid]
            else:
                seen_uuids[sid] = f"{key}.{p['pane_index']}"

# Emit final inventory
inventory = {
    "windows": list(windows.values()),
    "own_window": own_window,
    "target_dir": "$TARGET_DIR",
    "target_version": "$TARGET_VERSION",
    "non_session_count": non_session_count,
}

print(json.dumps(inventory, indent=2))
PYEOF

    rm -f "$tmp"
}

# --- Main ---
case "$PHASE" in
    --phase=0|0)
        acquire_lock
        self_locate
        ;;
    --phase=1|1)
        build_inventory
        ;;
    all|"")
        acquire_lock
        self_locate
        build_inventory
        ;;
    *)
        echo "usage: snapshot.sh [--phase=0|--phase=1|all]" >&2
        exit 2
        ;;
esac
