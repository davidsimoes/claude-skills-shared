#!/usr/bin/env bash
# restore.sh — the /restart-resume engine. Reads manifest and recreates every tmux
# session/window/pane, spawning fresh claude per claude pane with the captured handoff
# as first user message.
#
# Usage:
#   restore.sh <manifest_dir>
#
# Phases:
#   R1. Read manifest.json. Verify checksum + schema_version + per-pane file existence.
#   R2. For each session: tmux new-session -d -s <name> -c <first_cwd>. If exists, prompt.
#   R3. For each window: tmux new-window. (Skip window 0 already created with session.)
#   R4. For each pane (explicit order: split-windows first, select-layout second,
#       send-keys third — see plan v2.1 R4).
#       - Claude pane: send-keys "<absolute_path_to_launch-*.sh>" Enter
#       - Non-Claude pane: send-keys "<argv>" — NO Enter (user reviews)
#   R5. Orchestrator-pane handling: if is_orchestrator and current pane unassigned,
#       print "this pane is your new orchestrator; handoff at <path>" — don't respawn.
#   R6. Write restored_at marker inside manifest dir; remove `latest` symlink.
#
# Exit codes:
#   0 = restore complete
#   1 = bad args / missing manifest
#   2 = checksum / schema mismatch
#   3 = tmux command failed

set -uo pipefail

MANIFEST_DIR="${1:?usage: restore.sh <manifest_dir>}"

if [ ! -d "$MANIFEST_DIR" ]; then
    echo "ERROR: manifest dir not found: $MANIFEST_DIR" >&2
    exit 1
fi

MANIFEST="$MANIFEST_DIR/manifest.json"
if [ ! -r "$MANIFEST" ]; then
    echo "ERROR: manifest not readable: $MANIFEST" >&2
    exit 1
fi

# R1. Verify checksum + schema
python3 <<PYEOF
import hashlib, json, os, sys

manifest_path = "$MANIFEST"
with open(manifest_path) as f:
    m = json.load(f)

if m.get("schema_version") != 1:
    print(f"ERROR: schema_version mismatch: got {m.get('schema_version')}, want 1", file=sys.stderr)
    sys.exit(2)

stated = m.pop("checksum", None)
canonical = json.dumps(m, sort_keys=True, separators=(",", ":"))
computed = hashlib.sha256(canonical.encode("utf-8")).hexdigest()
if stated != computed:
    print(f"ERROR: checksum mismatch", file=sys.stderr)
    print(f"  stated:   {stated}", file=sys.stderr)
    print(f"  computed: {computed}", file=sys.stderr)
    sys.exit(2)

# Verify per-pane files
manifest_dir = os.path.dirname(manifest_path)
missing = []
for w in m["windows"]:
    for p in w["panes"]:
        if p.get("is_claude"):
            # Only handoff_path is load-bearing. restore.sh sends a claude command via
            # tmux send-keys to the pane's interactive zsh shell. launcher_path retained
            # in schema for backward-compat; presence not required.
            rel = p.get("handoff_path")
            if rel and not os.path.exists(os.path.join(manifest_dir, rel)):
                missing.append(f"{p.get('tmux_target_pane','?')}:handoff_path={rel}")
        else:
            rel = p.get("pane_state_path")
            if rel and not os.path.exists(os.path.join(manifest_dir, rel)):
                missing.append(f"{p.get('tmux_target_pane','?')}:pane_state={rel}")

if missing:
    print(f"ERROR: {len(missing)} referenced files missing:", file=sys.stderr)
    for x in missing[:10]:
        print(f"  {x}", file=sys.stderr)
    sys.exit(2)

print("OK: checksum + schema + per-pane files all verified", file=sys.stderr)
PYEOF
verify_rc=$?
if [ $verify_rc -ne 0 ]; then
    exit $verify_rc
fi

# R2-R4. Walk manifest and restore.
python3 - "$MANIFEST_DIR" <<'PYEOF'
import json
import os
import subprocess
import sys
import time

# Resolve symlinks BEFORE composing any send-keys command. The orchestrator typically
# invokes us with `<...>/restart-handoffs/latest` (a symlink), and R6 removes that
# symlink before all panes' shells have finished initializing. Without realpath here,
# slow-to-init panes evaluate `cat <symlink>/handoff-*.md` after the symlink is gone
# and silently boot Claude with no handoff. Resolving to the archive dir up-front
# decouples send-keys from R6's symlink cleanup.
manifest_dir = os.path.realpath(sys.argv[1])
manifest_path = os.path.join(manifest_dir, "manifest.json")
with open(manifest_path) as f:
    m = json.load(f)


def tmux(*args, check=True):
    """Run tmux command, return (rc, stdout)."""
    r = subprocess.run(["tmux", *args], capture_output=True, text=True)
    if check and r.returncode != 0:
        print(f"ERROR: tmux {' '.join(args)} → rc={r.returncode}", file=sys.stderr)
        print(f"  stderr: {r.stderr.strip()}", file=sys.stderr)
    return r.returncode, r.stdout.strip()


def session_exists(name):
    rc, _ = tmux("has-session", "-t", name, check=False)
    return rc == 0


# Self-locate: orchestrator-pane handling.
# RESTORE_OWN_PANE_OVERRIDE lets tests inject a target pane without actually attaching
# to tmux from the test harness. Production path uses display-message on the live client.
own_pane = ""
override = os.environ.get("RESTORE_OWN_PANE_OVERRIDE", "")
if override:
    own_pane = override
elif os.environ.get("TMUX"):
    rc, own_pane = tmux("display-message", "-p", "#{session_name}:#{window_index}.#{pane_index}",
                         check=False)

orchestrator_pane_manifest = m.get("orchestrator_pane", "")
print(f"manifest orchestrator was at: {orchestrator_pane_manifest}", file=sys.stderr)
print(f"this pane is at: {own_pane}", file=sys.stderr)

# Walk windows
restored_count = 0
skipped_count = 0
errors = []
# Track sessions we just created — only those have windows safe to rename
# (in pre-existing user sessions, window names may belong to user work).
freshly_created_sessions = set()

for w in m["windows"]:
    session = w["session"]
    win_idx = w["window_index"]
    win_name = w["window_name"]
    layout = w["window_layout"]
    panes = w["panes"]

    # R2. Ensure session
    if not session_exists(session):
        first_pane = panes[0] if panes else {}
        first_cwd = first_pane.get("cwd") or first_pane.get("pane_path") or os.path.expanduser("~")
        rc, _ = tmux("new-session", "-d", "-s", session, "-c", first_cwd, check=False)
        if rc != 0:
            errors.append(f"failed to create session {session}")
            continue
        freshly_created_sessions.add(session)
        print(f"created session: {session}", file=sys.stderr)

    # R3. Create window (or reuse if first window of session was auto-created).
    # Target the exact manifest window index so non-contiguous indices in the manifest
    # (e.g. session had windows {1,3,6} after some were closed) are preserved — otherwise
    # tmux auto-assigns sequential indices and subsequent send-keys to the manifest's
    # target_pane (e.g. session:3.1) hits the wrong pane (the new pane is at session:2.1).
    tmux_target_window = f"{session}:{win_idx}"
    rc_check, _ = tmux("list-windows", "-t", tmux_target_window, "-F", "#{window_index}", check=False)
    if rc_check != 0:
        first_pane = panes[0] if panes else {}
        first_cwd = first_pane.get("cwd") or first_pane.get("pane_path") or os.path.expanduser("~")
        rc, _ = tmux("new-window", "-t", tmux_target_window, "-n", win_name, "-c", first_cwd, check=False)
        if rc != 0:
            errors.append(f"failed to create window {tmux_target_window}")
            continue
    elif session in freshly_created_sessions and win_name:
        # Window already exists in a session we just created — that means tmux auto-created
        # this window when `new-session` ran (it always creates one window at base-index),
        # and it has a default name like "zsh" or "claude". Rename it to the manifest's name.
        # Skipped for pre-existing user sessions to avoid clobbering the user's window names.
        rc, _ = tmux("rename-window", "-t", tmux_target_window, win_name, check=False)
        if rc != 0:
            errors.append(f"failed to rename window {tmux_target_window} -> {win_name!r}")

    # R4. Create additional panes via split-window until pane count matches
    rc, current_panes_out = tmux("list-panes", "-t", tmux_target_window, "-F", "#{pane_index}",
                                  check=False)
    current_count = len(current_panes_out.splitlines()) if rc == 0 else 1
    needed = len(panes)
    while current_count < needed:
        # split horizontally by default
        rc, _ = tmux("split-window", "-t", tmux_target_window, "-c",
                     panes[current_count].get("cwd", os.path.expanduser("~")), check=False)
        if rc != 0:
            errors.append(f"failed to split-window in {tmux_target_window} (pane {current_count})")
            break
        current_count += 1

    # R4(ii). Apply layout string
    if layout:
        rc, _ = tmux("select-layout", "-t", tmux_target_window, layout, check=False)
        if rc != 0:
            # Layout failure is non-fatal — tmux falls back to default tiling
            print(f"WARN: select-layout failed for {tmux_target_window}: layout={layout!r}", file=sys.stderr)

    # Settle before send-keys
    time.sleep(0.3)

    # R4(iii). Per-pane send-keys
    for p in panes:
        pi = p["pane_index"]
        tmux_target_pane = f"{session}:{win_idx}.{pi}"

        # R5. Skip the pane that's running /restart-resume itself. Whichever pane invoked
        # the restore is the de facto orchestrator for this run — respawning Claude there
        # would blast keystrokes into the live Claude session that's executing restore.sh.
        # This applies whether or not it was the *original* orchestrator at capture time.
        if tmux_target_pane == own_pane:
            is_orig_orch = p.get("is_orchestrator", False)
            label = "original orchestrator" if is_orig_orch else "de facto orchestrator (you ran /restart-resume here)"
            print(f"NOTE: skipping respawn of {tmux_target_pane} — this pane is the {label}",
                  file=sys.stderr)
            handoff_rel = p.get("handoff_path")
            if handoff_rel:
                print(f"  handoff (unresumed) at: {os.path.join(manifest_dir, handoff_rel)}",
                      file=sys.stderr)
                print(f"  to resume manually: open a new window/pane and run\n"
                      f"    cd <cwd> && claude \"$(cat {os.path.join(manifest_dir, handoff_rel)})\"",
                      file=sys.stderr)
            skipped_count += 1
            continue

        if p.get("is_claude"):
            # Send `claude "$(cat <handoff>)"` directly to the interactive shell.
            # Running through the user's interactive shell (vs. invoking the binary via
            # a non-interactive bash launcher) is important if the user has a `claude`
            # shell function in their shell rc that binds credentials or env before
            # exec'ing the real binary. Bypassing it can land you at OAuth onboarding.
            handoff = os.path.join(manifest_dir, p["handoff_path"])
            # Build the command: cd <cwd> && claude "$(cat <handoff>)"
            cwd = p.get("cwd") or p.get("pane_path") or os.path.expanduser("~")
            import shlex
            cmd_str = f'cd {shlex.quote(cwd)} && claude "$(cat {shlex.quote(handoff)})"'
            rc, _ = tmux("send-keys", "-t", tmux_target_pane, cmd_str, "Enter", check=False)
            if rc != 0:
                errors.append(f"send-keys (claude) failed for {tmux_target_pane}")
                continue
            restored_count += 1
        else:
            # Non-claude pane: paste the captured command, NO Enter — user reviews
            cmd = p.get("cmd") or p.get("argv") or ""
            if cmd:
                rc, _ = tmux("send-keys", "-t", tmux_target_pane, cmd, check=False)
                if rc != 0:
                    errors.append(f"send-keys (non-claude argv) failed for {tmux_target_pane}")
            restored_count += 1

# R6. Mark manifest as restored (atomic: write to .tmp + fsync + rename)
marker = os.path.join(manifest_dir, "restored_at")
marker_tmp = marker + ".tmp"
with open(marker_tmp, "w") as f:
    f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
    f.flush()
    os.fsync(f.fileno())
os.rename(marker_tmp, marker)
print(f"wrote restored_at marker: {marker}", file=sys.stderr)

# Remove `latest` symlink to prevent re-firing the SessionStart banner
parent = os.path.dirname(manifest_dir)
latest = os.path.join(parent, "latest")
if os.path.islink(latest):
    try:
        os.unlink(latest)
        print(f"removed latest symlink: {latest}", file=sys.stderr)
    except Exception as e:
        print(f"WARN: failed to remove latest symlink: {e}", file=sys.stderr)

# Summary
print(json.dumps({
    "restored_panes": restored_count,
    "skipped_panes": skipped_count,
    "errors": errors,
    "manifest_dir": manifest_dir,
}))
PYEOF
