#!/usr/bin/env bats
# restore.bats — tests for restore.sh tmux-state restoration.
#
# Covers the three bug classes shipped in /restart-resume's first real-world run
# (2026-05-26) and locked down by commits bb0e5f5 + 984274d:
#   1. Non-contiguous window indices must be preserved (not auto-renumbered).
#   2. The pane invoking /restart-resume must be skipped unconditionally, not
#      only when it was the *original* orchestrator at capture time.
#   3. Auto-created first window of a freshly-created session must be renamed
#      to the manifest's window_name (otherwise it keeps tmux's default).
#   4. Pre-existing user sessions must NOT have their window names rewritten.
#
# Run via: tests/run-tests.sh

setup() {
    export TMPDIR_TEST="$(mktemp -d -t restart-bats-XXXXXX)"
    export SESS_PREFIX="_bats-restore-$$"
    export RESTORE_SH="$BATS_TEST_DIRNAME/../scripts/restore.sh"
}

teardown() {
    # Kill any tmux sessions this test created. Pattern-matched to the unique
    # PID-derived prefix so we never touch the user's real sessions.
    tmux list-sessions -F '#S' 2>/dev/null | grep "^${SESS_PREFIX}" | while read -r s; do
        tmux kill-session -t "$s" 2>/dev/null || true
    done
    rm -rf "$TMPDIR_TEST"
}

# Helper — write a valid manifest.json (with checksum + handoff files) from a
# windows-array literal. Returns 0 on success. Args:
#   $1 = manifest dir
#   $2 = JSON array of window objects (must include session, window_index,
#        window_name, window_layout, panes[])
make_manifest() {
    local manifest_dir="$1"
    local windows_json="$2"
    mkdir -p "$manifest_dir"

    MANIFEST_DIR="$manifest_dir" WINDOWS_JSON="$windows_json" python3 <<'PY'
import hashlib, json, os, pathlib

manifest_dir = os.environ["MANIFEST_DIR"]
windows = json.loads(os.environ["WINDOWS_JSON"])

# Generate a handoff file for every claude pane that doesn't supply one.
for w in windows:
    for p in w["panes"]:
        if p.get("is_claude") and "handoff_path" not in p:
            # Match write-manifest.py's filename scheme but keep it simple for tests.
            safe = w["session"].replace(" ", "_").replace("+", "_")
            p["handoff_path"] = f"handoff-{safe}-{w['window_index']}-{p['pane_index']}.md"
        if p.get("is_claude"):
            (pathlib.Path(manifest_dir) / p["handoff_path"]).write_text(
                f"# test handoff for {w['session']}:{w['window_index']}.{p['pane_index']}\n"
            )

m = {
    "schema_version": 1,
    "captured_at": "2026-05-26T00:00:00Z",
    "orchestrator_pane": "ignored:0.0",
    "windows": windows,
}
canon = json.dumps(m, sort_keys=True, separators=(",", ":"))
m["checksum"] = hashlib.sha256(canon.encode()).hexdigest()
(pathlib.Path(manifest_dir) / "manifest.json").write_text(json.dumps(m, indent=2))
PY
}

# Helper — extract a key from restore.sh's stdout JSON summary (last stdout line).
# Stderr is the chatty progress log; the JSON is the very last thing on stdout.
summary_key() {
    local key="$1"
    # $output is set by `run` and merges stdout+stderr; we grep for the JSON line.
    local json_line
    json_line=$(echo "$output" | grep -E '^\{.*"restored_panes"' | tail -1)
    [ -n "$json_line" ] || return 1
    echo "$json_line" | python3 -c "import json,sys; print(json.load(sys.stdin)['$key'])"
}

@test "restore preserves non-contiguous window indices from manifest" {
    local SESS="${SESS_PREFIX}-noncontig"
    local windows='[
        {"session":"'"$SESS"'","window_index":1,"window_name":"first",
         "window_layout":"deadbeef,80x24,0,0,1",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':1.1"}]},
        {"session":"'"$SESS"'","window_index":3,"window_name":"third",
         "window_layout":"deadbeef,80x24,0,0,2",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':3.1"}]},
        {"session":"'"$SESS"'","window_index":6,"window_name":"sixth",
         "window_layout":"deadbeef,80x24,0,0,3",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':6.1"}]}
    ]'
    make_manifest "$TMPDIR_TEST" "$windows"

    run bash "$RESTORE_SH" "$TMPDIR_TEST"
    [ "$status" -eq 0 ]

    # Indices must be exactly 1, 3, 6 — not 1, 2, 3.
    local indices
    indices=$(tmux list-windows -t "$SESS" -F '#{window_index}' | sort -n | paste -sd, -)
    [ "$indices" = "1,3,6" ]

    # And the manifest's window names must be on those indices, not on whatever
    # tmux would have auto-assigned.
    [ "$(tmux display-message -t "$SESS:1" -p '#{window_name}')" = "first" ]
    [ "$(tmux display-message -t "$SESS:3" -p '#{window_name}')" = "third" ]
    [ "$(tmux display-message -t "$SESS:6" -p '#{window_name}')" = "sixth" ]
}

@test "restore skips own_pane respawn even when not marked is_orchestrator" {
    local SESS="${SESS_PREFIX}-ownpane"
    # Two regular Claude panes. Neither has is_orchestrator=true. We override
    # own_pane to point at window 2 — that pane must still be skipped.
    local windows='[
        {"session":"'"$SESS"'","window_index":1,"window_name":"claude1",
         "window_layout":"deadbeef,80x24,0,0,1",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':1.1"}]},
        {"session":"'"$SESS"'","window_index":2,"window_name":"claude2",
         "window_layout":"deadbeef,80x24,0,0,2",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':2.1"}]}
    ]'
    make_manifest "$TMPDIR_TEST" "$windows"

    RESTORE_OWN_PANE_OVERRIDE="$SESS:2.1" run bash "$RESTORE_SH" "$TMPDIR_TEST"
    [ "$status" -eq 0 ]

    # JSON summary should show 1 restored, 1 skipped.
    [ "$(summary_key restored_panes)" = "1" ]
    [ "$(summary_key skipped_panes)" = "1" ]
}

@test "restore renames auto-created first window of a freshly-created session" {
    local SESS="${SESS_PREFIX}-autorename"
    # `tmux new-session -d -s X` always creates a window at base-index with a
    # default name (current command name). The patch makes restore rename it
    # to the manifest's window_name.
    local windows='[
        {"session":"'"$SESS"'","window_index":1,"window_name":"Comms",
         "window_layout":"deadbeef,80x24,0,0,1",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':1.1"}]}
    ]'
    make_manifest "$TMPDIR_TEST" "$windows"

    run bash "$RESTORE_SH" "$TMPDIR_TEST"
    [ "$status" -eq 0 ]
    [ "$(tmux display-message -t "$SESS:1" -p '#{window_name}')" = "Comms" ]
}

@test "restore does NOT rename windows in pre-existing user sessions" {
    local SESS="${SESS_PREFIX}-preexisting"
    # Simulate: user already has a session of the same name with a window they care
    # about. Restore must NOT clobber its name even if the manifest disagrees.
    tmux new-session -d -s "$SESS" -n "user-stuff" -c /tmp
    [ "$(tmux display-message -t "$SESS:1" -p '#{window_name}')" = "user-stuff" ]

    local windows='[
        {"session":"'"$SESS"'","window_index":1,"window_name":"manifest-name",
         "window_layout":"deadbeef,80x24,0,0,1",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':1.1"}]}
    ]'
    make_manifest "$TMPDIR_TEST" "$windows"

    run bash "$RESTORE_SH" "$TMPDIR_TEST"
    [ "$status" -eq 0 ]

    # User's window name is preserved.
    [ "$(tmux display-message -t "$SESS:1" -p '#{window_name}')" = "user-stuff" ]
}

@test "restore resolves manifest_dir symlinks before composing send-keys (latest/ race)" {
    # Regression test for the bug discovered 2026-05-26: orchestrator typically passes
    # `<...>/restart-handoffs/latest` (a symlink); R6 unlinks `latest` at the end; slow-
    # to-init panes then evaluate `cat <symlink>/handoff-*.md` AFTER the symlink is gone
    # and silently boot Claude with no handoff. Fix is os.path.realpath() up front.
    local SESS="${SESS_PREFIX}-realpath"
    local archive_dir="$TMPDIR_TEST/2026-05-26T000000Z"
    local latest_link="$TMPDIR_TEST/latest"

    local windows='[
        {"session":"'"$SESS"'","window_index":1,"window_name":"first",
         "window_layout":"deadbeef,80x24,0,0,1",
         "panes":[{"pane_index":1,"is_claude":true,"is_orchestrator":false,
                   "cwd":"/tmp","tmux_target_pane":"'"$SESS"':1.1"}]}
    ]'
    make_manifest "$archive_dir" "$windows"
    ln -s "$archive_dir" "$latest_link"

    # Invoke restore.sh with the SYMLINK path. With own_pane override, the
    # orchestrator-skip code path prints "handoff (unresumed) at: <path>" to stderr —
    # we can inspect that path to confirm it was resolved before composition.
    RESTORE_OWN_PANE_OVERRIDE="$SESS:1.1" run bash "$RESTORE_SH" "$latest_link"
    [ "$status" -eq 0 ]

    # The printed handoff path must contain the resolved archive_dir, not the symlink.
    [[ "$output" == *"$archive_dir/handoff-"* ]]
    ! [[ "$output" == *"$latest_link/handoff-"* ]]

    # And R6 must still successfully remove the `latest` symlink (the fix mustn't break it).
    [ ! -L "$latest_link" ]
}
