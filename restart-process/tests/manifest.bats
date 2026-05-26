#!/usr/bin/env bats
# manifest.bats — tests for write-manifest.py (atomic write, checksum, schema).
#
# Run via: tests/run-tests.sh

setup() {
    export TMPDIR_TEST="$(mktemp -d -t restart-process-bats-XXXXXX)"
    export SCRIPT="$BATS_TEST_DIRNAME/../scripts/write-manifest.py"
}

teardown() {
    rm -rf "$TMPDIR_TEST"
}

# Helper: produce a minimal-but-valid inventory JSON with N claude panes
make_inventory() {
    local n_claude="${1:-2}"
    local i=0
    local panes=""
    while [ $i -lt "$n_claude" ]; do
        [ -n "$panes" ] && panes="$panes,"
        panes="$panes{\"pane_index\":$i,\"pane_pid\":$((10000+i)),\"pane_path\":\"/tmp\",\"claude_pid\":$((20000+i)),\"cmd\":\"claude --resume foo$i\",\"sessionId\":\"sid-$i\",\"cwd\":\"/tmp\",\"version\":\"2.1.150\",\"source_config_dir\":\"/Users/x/.claude\"}"
        i=$((i+1))
    done
    cat <<EOF
{
  "windows": [
    {
      "tmux_target": "TestSession:0",
      "session": "TestSession",
      "window_index": 0,
      "window_name": "test",
      "window_layout": "abcd,200x50,0,0[200x25,0,0,1,200x24,0,26,2]",
      "panes": [$panes]
    }
  ],
  "own_window": "TestSession:9",
  "target_dir": "/Users/x/.claude",
  "target_version": "2.1.150"
}
EOF
}

# Helper: pre-create handoff files for N claude panes (matches write-manifest's pane_key)
make_handoff_files() {
    local n_claude="$1"
    local i=0
    while [ $i -lt "$n_claude" ]; do
        echo "# Session handoff: test pane $i" > "$TMPDIR_TEST/handoff-TestSession-0-$i.md"
        i=$((i+1))
    done
}

@test "write-manifest produces valid JSON" {
    make_handoff_files 2
    inventory=$(make_inventory 2)
    result=$(echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude")
    [ -f "$TMPDIR_TEST/manifest.json" ]
    # JSON parses
    python3 -c "import json; json.load(open('$TMPDIR_TEST/manifest.json'))"
}

@test "write-manifest checksum verifies (canonical re-serialize round trip)" {
    make_handoff_files 2
    inventory=$(make_inventory 2)
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    python3 <<PY
import hashlib, json
m = json.load(open("$TMPDIR_TEST/manifest.json"))
stated = m.pop("checksum")
canon = json.dumps(m, sort_keys=True, separators=(",", ":"))
computed = hashlib.sha256(canon.encode()).hexdigest()
assert stated == computed, f"checksum mismatch: stated={stated[:16]} computed={computed[:16]}"
PY
}

@test "write-manifest schema_version is 1" {
    make_handoff_files 1
    inventory=$(make_inventory 1)
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    version=$(python3 -c "import json; print(json.load(open('$TMPDIR_TEST/manifest.json'))['schema_version'])")
    [ "$version" = "1" ]
}

@test "write-manifest sets is_claude=true for claude panes" {
    make_handoff_files 2
    inventory=$(make_inventory 2)
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    n_claude=$(python3 -c "
import json
m = json.load(open('$TMPDIR_TEST/manifest.json'))
print(sum(1 for w in m['windows'] for p in w['panes'] if p.get('is_claude')))
")
    [ "$n_claude" = "2" ]
}

@test "write-manifest preserves window_layout string" {
    make_handoff_files 1
    inventory=$(make_inventory 1)
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    layout=$(python3 -c "
import json
m = json.load(open('$TMPDIR_TEST/manifest.json'))
print(m['windows'][0]['window_layout'])
")
    [ "$layout" = "abcd,200x50,0,0[200x25,0,0,1,200x24,0,26,2]" ]
}

@test "write-manifest fails (exit 3) when handoff file missing" {
    # Do NOT create handoff files
    inventory=$(make_inventory 1)
    run bash -c "echo '$inventory' | python3 '$SCRIPT' \
        --manifest-dir '$TMPDIR_TEST' \
        --orchestrator-pane 'TestSession:0.0' \
        --orchestrator-cwd '/tmp' \
        --captured-at '2026-05-25T22:00:00Z' \
        --claude-binary-path '/usr/local/bin/claude' \
        --resume-orchestrator-cwd '/Users/x/.claude'"
    [ "$status" -eq 3 ]
}

@test "write-manifest marks orchestrator pane correctly" {
    make_handoff_files 2
    inventory=$(make_inventory 2)
    # Mark pane 0 as orchestrator
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    orch=$(python3 -c "
import json
m = json.load(open('$TMPDIR_TEST/manifest.json'))
panes = m['windows'][0]['panes']
print(','.join(str(p.get('is_orchestrator', False)) for p in panes))
")
    [ "$orch" = "True,False" ]
}

@test "write-manifest atomic — no manifest.json.tmp left behind" {
    make_handoff_files 1
    inventory=$(make_inventory 1)
    echo "$inventory" | python3 "$SCRIPT" \
        --manifest-dir "$TMPDIR_TEST" \
        --orchestrator-pane "TestSession:0.0" \
        --orchestrator-cwd "/tmp" \
        --captured-at "2026-05-25T22:00:00Z" \
        --claude-binary-path "/usr/local/bin/claude" \
        --resume-orchestrator-cwd "/Users/x/.claude" > /dev/null

    [ -f "$TMPDIR_TEST/manifest.json" ]
    [ ! -f "$TMPDIR_TEST/manifest.json.tmp" ]
}
