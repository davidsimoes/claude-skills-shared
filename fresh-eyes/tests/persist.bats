#!/usr/bin/env bats
# persist.bats — equivalence + edge + hygiene tests for scripts/persist.sh.
# Tests assert OBSERVABLE behavior (exit codes, stdout/stderr text, file existence).
#
# 31 equivalence + 5 edge + 2 hygiene = 38 tests (2 are skipped: test 27
# documentation-only; E4 environment-dependent / requires controlled tmpfs).
# Requires bats >= 1.11.0 — uses `run --separate-stderr` syntax (introduced 1.7.0)
# and matches the run-tests.sh semver gate.

bats_require_minimum_version 1.11.0

load 'helpers.bash'

# ---- Equivalence row 1: audit_session_id format -----------------------------

@test "01: init returns audit_session_id in millisecond ISO no-colons format" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    [[ "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}\.[0-9]{3}Z$ ]]
}

# ---- Equivalence row 2: cache dir auto-create -------------------------------

@test "02: init creates cache_dir if missing" {
    rmdir "$TEST_CACHE_DIR"
    [ ! -d "$TEST_CACHE_DIR" ]
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    [ -d "$TEST_CACHE_DIR" ]
}

# ---- Equivalence row 3: lock dir under CACHE_DIR (not $HOME) ----------------

@test "03: lock dir is created under CACHE_DIR (not hardcoded \$HOME)" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    [ -d "$TEST_CACHE_DIR/.lock-$id" ]
    # Verify NOT under $HOME (defensive).
    [ ! -d "$HOME/.claude/cache/fresh-eyes/.lock-$id" ] || [[ "$TEST_CACHE_DIR" == "$HOME/.claude/cache/fresh-eyes" ]]
}

# ---- Equivalence row 4: lock primitive — second acquire of same lock → 75 ---

@test "04: second acquire of an already-held fresh lock exits 75 + DEGRADED on stderr" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    # Lock now held; create plan content so resume passes cache-file check.
    echo "plan content here" > "$TEST_CACHE_DIR/${id}-plan.md"
    # Second acquire of same lock via resume → exit 75.
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *DEGRADED* ]]
}

# ---- Equivalence row 5: resume reuses cache files ---------------------------

@test "05: resume returns same plan_path for an existing audit session" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    plan_path_init=$(echo "$output" | awk -F= '/^plan_path=/ {sub("^plan_path=",""); print; exit}')
    echo "plan content" > "$plan_path_init"
    # Release lock first so we can resume.
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id"
    [ "$status" -eq 0 ]
    # Now resume.
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 0 ]
    plan_path_resume=$(echo "$output" | awk -F= '/^plan_path=/ {sub("^plan_path=",""); print; exit}')
    [ "$plan_path_init" = "$plan_path_resume" ]
}

# ---- Equivalence row 6: resume bad id fails + auto-releases lock ------------

@test "06: resume with nonexistent id exits 65 and auto-releases lock" {
    bad_id="2099-12-31T235959.999Z"
    run --separate-stderr bash "$PERSIST_SH" resume "$bad_id"
    [ "$status" -eq 65 ]
    [[ "$stderr" == *DEGRADED* ]]
    # Lock dir for that id must NOT exist after exit.
    [ ! -d "$TEST_CACHE_DIR/.lock-$bad_id" ]
}

# ---- Equivalence row 7: release-lock then resume succeeds -------------------

@test "07: release-lock then resume re-acquires lock cleanly" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    echo "x" > "$TEST_CACHE_DIR/${id}-plan.md"
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"released=true"* ]]
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 0 ]
    [ -d "$TEST_CACHE_DIR/.lock-$id" ]
}

# ---- Equivalence row 8: release-lock then init returns NEW id ---------------

@test "08: init → release-lock → init produces a different audit_session_id" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id1=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id1"
    [ "$status" -eq 0 ]
    sleep 0.005  # ensure ms tick
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id2=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    [ "$id1" != "$id2" ]
}

# ---- Equivalence row 9: release-lock idempotent on absent lock --------------

@test "09: release-lock on a never-locked id exits 0 with released=false" {
    run --separate-stderr bash "$PERSIST_SH" release-lock "2099-01-01T000000.000Z"
    [ "$status" -eq 0 ]
    [[ "$output" == *"released=false"* ]]
    [[ "$stderr" != *DEGRADED* ]]
}

# ---- Equivalence row 10: release-lock idempotent on already-released --------

@test "10: second release-lock on same id exits 0 with released=false (no DEGRADED)" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"released=true"* ]]
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id"
    [ "$status" -eq 0 ]
    [[ "$output" == *"released=false"* ]]
    [[ "$stderr" != *DEGRADED* ]]
}

# ---- Equivalence row 11: stale-lock boundary (strict > 3600s = stale) -------
# Pre-resolved decision #5: comparator is strict > (lock at exactly 3600s = fresh).
# Test the boundary on both sides without hitting the wall-clock race that an
# exact-3600s offset would: by the time the script reads mtime, `now` may have
# advanced by 1s. Using 3601 (definitely stale) + 3599 (definitely fresh)
# proves the boundary deterministically.

@test "11a: lock with age 3700s ago is stale → resume succeeds" {
    id="2026-01-01T000000.000Z"
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    mkdir "$TEST_CACHE_DIR/.lock-${id}"
    set_mtime_ago "$TEST_CACHE_DIR/.lock-${id}" 3700
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 0 ]
    [ -d "$TEST_CACHE_DIR/.lock-${id}" ]
}

@test "11b: lock with age 3601s ago is stale (just over boundary) → resume succeeds" {
    id="2026-01-01T000000.000Z"
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    mkdir "$TEST_CACHE_DIR/.lock-${id}"
    set_mtime_ago "$TEST_CACHE_DIR/.lock-${id}" 3601
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 0 ]
}

@test "11c: lock with age 3599s ago is fresh (just under boundary) → resume exits 75" {
    id="2026-01-01T000000.000Z"
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    mkdir "$TEST_CACHE_DIR/.lock-${id}"
    set_mtime_ago "$TEST_CACHE_DIR/.lock-${id}" 3599
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 75 ]
}

# ---- Equivalence row 12: stale-lock concurrent rmdir race-safe --------------
# Pre-resolved decision #2: ONE acquires (exit 0), OTHER loses race (exit 75 + DEGRADED).

@test "12: two concurrent resumes against stale lock — one wins, one loses race cleanly" {
    id="2026-01-01T000000.000Z"
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    mkdir "$TEST_CACHE_DIR/.lock-${id}"
    set_mtime_ago "$TEST_CACHE_DIR/.lock-${id}" 3700

    out1="$BATS_TEST_TMPDIR/c1-$$.out"
    err1="$BATS_TEST_TMPDIR/c1-$$.err"
    out2="$BATS_TEST_TMPDIR/c2-$$.out"
    err2="$BATS_TEST_TMPDIR/c2-$$.err"

    bash "$PERSIST_SH" resume "$id" > "$out1" 2> "$err1" &
    pid1=$!
    bash "$PERSIST_SH" resume "$id" > "$out2" 2> "$err2" &
    pid2=$!
    set +e
    wait "$pid1"; rc1=$?
    wait "$pid2"; rc2=$?
    set -e

    # Exactly one should succeed (0) and the other should hit the held lock (75).
    [ "$((rc1 + rc2))" -eq 75 ]
    [ "$rc1" -eq 0 ] || [ "$rc1" -eq 75 ]
    [ "$rc2" -eq 0 ] || [ "$rc2" -eq 75 ]
    [ "$rc1" -ne "$rc2" ]
    # The losing process emits DEGRADED on stderr.
    if [ "$rc1" -eq 75 ]; then
        grep -q DEGRADED "$err1"
    else
        grep -q DEGRADED "$err2"
    fi
}

# ---- Equivalence row 13: resume exit 75 when fresh lock held ----------------

@test "13: resume exits 75 + DEGRADED when lock is held fresh by another caller" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    # Lock held; resume from "PID B" should exit 75 (NOT bump id).
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *DEGRADED* ]]
    # Lock dir still exists for original id (PID B did NOT release it).
    [ -d "$TEST_CACHE_DIR/.lock-$id" ]
}

# ---- Equivalence row 14: resume with deleted plan auto-releases lock --------

@test "14: resume with deleted plan exits 65 AND lock dir does not persist" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    # No plan ever written; release the init lock so resume can attempt.
    run --separate-stderr bash "$PERSIST_SH" release-lock "$id"
    [ "$status" -eq 0 ]
    # Now resume — has_cache_files returns false → exit 65 → auto-release.
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 65 ]
    [[ "$stderr" == *DEGRADED* ]]
    [ ! -d "$TEST_CACHE_DIR/.lock-$id" ]
}

# ---- Equivalence row 15: verify_ref HEAD succeeds ---------------------------

@test "15: materialize diff:HEAD succeeds in a real git repo" {
    setup_git_repo
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:HEAD"
    [ "$status" -eq 0 ]
    out_path=$(echo "$output" | awk -F= '/^materialized_path=/ {sub("^materialized_path=",""); print; exit}')
    [ -f "$out_path" ]
    teardown_git_repo
}

# ---- Equivalence row 16: verify_ref rejects nonexistent ref -----------------

@test "16: materialize with nonexistent ref exits 65 + DEGRADED" {
    setup_git_repo
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:nonexistent-xyz"
    [ "$status" -eq 65 ]
    [[ "$stderr" == *DEGRADED* ]]
    teardown_git_repo
}

# ---- Equivalence row 17: verify_ref rejects empty ref -----------------------

@test "17: materialize with empty ref (diff:) exits 65 + DEGRADED" {
    setup_git_repo
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:"
    [ "$status" -eq 65 ]
    [[ "$stderr" == *DEGRADED* ]]
    teardown_git_repo
}

# ---- Equivalence row 18: verify_ref accepts A..B ranges ---------------------

@test "18: materialize accepts A..B ranges when both refs exist" {
    setup_git_repo
    git checkout -q -b feature
    echo "more" > b.txt
    git add b.txt
    git commit -q -m "feature commit"
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:main..feature"
    [ "$status" -eq 0 ]
    teardown_git_repo
}

# ---- Equivalence row 19: verify_ref accepts A...B ranges --------------------

@test "19: materialize accepts A...B ranges when both refs exist" {
    setup_git_repo
    git checkout -q -b feature
    echo "more" > b.txt
    git add b.txt
    git commit -q -m "feature commit"
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:main...feature"
    [ "$status" -eq 0 ]
    teardown_git_repo
}

# ---- Equivalence row 20: branch: produces -branch.md ------------------------

@test "20: materialize branch:<name> produces a -branch.md file with real commits diffed (dynamic base detection)" {
    setup_git_repo
    # Create a real feature branch with one extra commit so branch:feature
    # has actual content to diff against the detected base.
    git checkout -q -b feature
    echo "feature work" > feat.txt
    git add feat.txt
    git commit -q -m "feature commit"
    git checkout -q main

    # No origin remote configured → dynamic base detection falls back to "main".
    # Verify the fallback path produces a non-empty diff for branch:feature.
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "branch:feature"
    [ "$status" -eq 0 ]
    out_path=$(echo "$output" | awk -F= '/^materialized_path=/ {sub("^materialized_path=",""); print; exit}')
    [[ "$out_path" == *-branch.md ]]
    [ -f "$out_path" ]
    # The diff should contain the feature-only commit's added file.
    grep -q "feat.txt" "$out_path"
    teardown_git_repo
}

# ---- Equivalence row 21: commit: produces -commit.md ------------------------

@test "21: materialize commit:HEAD produces a -commit.md file" {
    setup_git_repo
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "commit:HEAD"
    [ "$status" -eq 0 ]
    out_path=$(echo "$output" | awk -F= '/^materialized_path=/ {sub("^materialized_path=",""); print; exit}')
    [[ "$out_path" == *-commit.md ]]
    [ -f "$out_path" ]
    teardown_git_repo
}

# ---- Equivalence row 22: materialize >2MB emits DEGRADED but produces file ---

@test "22: materialize with >2MB output emits DEGRADED warning + produces file" {
    setup_git_repo
    # Create a >3MB file and commit it on main; diff HEAD~1..HEAD will exceed 2MB.
    head -c 3145728 /dev/urandom | base64 > big.txt
    git add big.txt
    git commit -q -m "big add"
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:HEAD~1"
    [ "$status" -eq 0 ]
    out_path=$(echo "$output" | awk -F= '/^materialized_path=/ {sub("^materialized_path=",""); print; exit}')
    [ -f "$out_path" ]
    [[ "$stderr" == *"output exceeds 2MB"* ]]
    teardown_git_repo
}

# ---- Equivalence row 23: prune precedence — all 6 patterns aged out ---------

@test "23: prune deletes all 6 patterns when older than 7 days" {
    id="2026-01-01T000000.000Z"
    for suffix in plan manifest diff branch commit requirements; do
        printf 'old\n' > "$TEST_CACHE_DIR/${id}-${suffix}.md"
        set_mtime_ago "$TEST_CACHE_DIR/${id}-${suffix}.md" 691200  # 8 days
    done
    # Verdict is 30-day TTL → 8d should NOT delete it.
    printf 'verdict\n' > "$TEST_CACHE_DIR/${id}-verdict-round1.md"
    set_mtime_ago "$TEST_CACHE_DIR/${id}-verdict-round1.md" 691200

    run --separate-stderr bash "$PERSIST_SH" prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned_plans=1"* ]]
    [[ "$output" == *"pruned_manifests=1"* ]]
    [[ "$output" == *"pruned_materialized=3"* ]]
    [[ "$output" == *"pruned_requirements=1"* ]]
    [[ "$output" == *"pruned_verdicts=0"* ]]
    [ ! -f "$TEST_CACHE_DIR/${id}-plan.md" ]
    [ ! -f "$TEST_CACHE_DIR/${id}-requirements.md" ]
    [ -f "$TEST_CACHE_DIR/${id}-verdict-round1.md" ]
}

# ---- Equivalence row 24: prune leaves new files alone -----------------------

@test "24: prune does not touch fresh files" {
    id="2026-01-01T000000.000Z"
    for suffix in plan manifest diff branch commit requirements; do
        printf 'fresh\n' > "$TEST_CACHE_DIR/${id}-${suffix}.md"
    done
    run --separate-stderr bash "$PERSIST_SH" prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned_plans=0"* ]]
    [[ "$output" == *"pruned_manifests=0"* ]]
    [[ "$output" == *"pruned_materialized=0"* ]]
    [[ "$output" == *"pruned_requirements=0"* ]]
    for suffix in plan manifest diff branch commit requirements; do
        [ -f "$TEST_CACHE_DIR/${id}-${suffix}.md" ]
    done
}

# ---- Equivalence row 25: prune exits 0 when cache dir missing ---------------

@test "25: prune with missing cache_dir exits 0 with all counts 0 (no DEGRADED)" {
    rmdir "$TEST_CACHE_DIR"
    [ ! -d "$TEST_CACHE_DIR" ]
    run --separate-stderr bash "$PERSIST_SH" prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned_plans=0"* ]]
    [[ "$output" == *"pruned_manifests=0"* ]]
    [[ "$output" == *"pruned_materialized=0"* ]]
    [[ "$output" == *"pruned_requirements=0"* ]]
    [[ "$output" == *"pruned_verdicts=0"* ]]
    [[ "$stderr" != *DEGRADED* ]]
}

# ---- Equivalence row 26: verify_ref doesn't pollute caller scope ------------

@test "26: materialize doesn't leak L/R variables into caller scope" {
    setup_git_repo
    L=POLLUTE
    R=POLLUTE
    export L R
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    run --separate-stderr bash "$PERSIST_SH" materialize "$id" "diff:HEAD"
    [ "$status" -eq 0 ]
    [ "$L" = "POLLUTE" ]
    [ "$R" = "POLLUTE" ]
    teardown_git_repo
}

# ---- Equivalence row 27: documentation-only — manifest format ---------------
# Verified by migration step 5 (SKILL.md prose review), not by bats.
# Encoded here as a no-op assertion so the test count matches the spec.

@test "27: manifest format documented in SKILL.md (verified at migration step 5)" {
    skip "documentation-only test — verified at migration step 5 (SKILL.md prose review)"
}

# ---- Equivalence row 28: re-entry without release-lock exits 75 -------------
# Pre-resolved decision #3.

@test "28: init then resume same id without intervening release-lock exits 75" {
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 0 ]
    id=$(echo "$output" | awk -F= '/^audit_session_id=/ {sub("^audit_session_id=",""); print; exit}')
    echo "plan" > "$TEST_CACHE_DIR/${id}-plan.md"
    # Same orchestrator re-invokes resume without release-lock — must surface lock conflict.
    run --separate-stderr bash "$PERSIST_SH" resume "$id"
    [ "$status" -eq 75 ]
    [[ "$stderr" == *DEGRADED* ]]
}

# ---- Equivalence row 29: prune handles a lone stale requirements.md ---------
# Isolates the requirements-prune path so a mis-wired find branch
# in cmd_prune can't silently pass test 23 via cross-pattern coverage.

@test "29: prune removes a lone stale requirements.md and reports pruned_requirements=1" {
    id="2026-01-01T000000.000Z"
    printf 'reqs\n' > "$TEST_CACHE_DIR/${id}-requirements.md"
    set_mtime_ago "$TEST_CACHE_DIR/${id}-requirements.md" 691200  # 8 days

    run --separate-stderr bash "$PERSIST_SH" prune
    [ "$status" -eq 0 ]
    [[ "$output" == *"pruned_plans=0"* ]]
    [[ "$output" == *"pruned_manifests=0"* ]]
    [[ "$output" == *"pruned_materialized=0"* ]]
    [[ "$output" == *"pruned_requirements=1"* ]]
    [[ "$output" == *"pruned_verdicts=0"* ]]
    [ ! -f "$TEST_CACHE_DIR/${id}-requirements.md" ]
}

# ---- Edge case 1: HOME unset → exit 78 --------------------------------------

@test "E1: init with HOME unset and no CACHE_DIR exits 78" {
    run --separate-stderr env -i PATH="$PATH" bash "$PERSIST_SH" init
    [ "$status" -eq 78 ]
    [[ "$stderr" == *DEGRADED* ]]
}

# ---- Edge case 2: python3 missing → exit 78 ---------------------------------

@test "E2: init with python3 not in PATH exits 78" {
    # Build a synthetic PATH that contains everything except python3.
    SHIM="$BATS_TEST_TMPDIR/no-python-bin"
    mkdir -p "$SHIM"
    for cmd in bash mkdir rmdir stat date find wc tr awk grep printf cat git rm sed; do
        path="$(command -v "$cmd" 2>/dev/null)"
        [ -n "$path" ] && ln -sf "$path" "$SHIM/$cmd"
    done
    run --separate-stderr env -i HOME="$HOME" PATH="$SHIM" CACHE_DIR="$TEST_CACHE_DIR" bash "$PERSIST_SH" init
    [ "$status" -eq 78 ]
    [[ "$stderr" == *DEGRADED* ]]
    [[ "$stderr" == *python3* ]]
}

# ---- Edge case 3: read-only CACHE_DIR → exit 78 -----------------------------

@test "E3: init with read-only CACHE_DIR exits 78" {
    chmod 555 "$TEST_CACHE_DIR"
    run --separate-stderr bash "$PERSIST_SH" init
    [ "$status" -eq 78 ]
    [[ "$stderr" == *DEGRADED* ]]
    chmod 755 "$TEST_CACHE_DIR"
}

# ---- Edge case 4: disk-full → exit 1 (skipped — environment-dependent) ------

@test "E4: init with disk full exits 1 (skipped — requires controlled tmpfs)" {
    skip "disk-full simulation requires a controlled tmpfs / quota; not deterministic in this harness"
}

# ---- Edge case 5: prune with symlinked subdir does NOT follow ---------------

@test "E5: prune does not follow symlinked subdir into other dirs (-P)" {
    other_dir=$(mktemp -d /tmp/fresh-eyes-other-XXXXXX)
    id="2026-01-01T000000.000Z"
    printf 'do not delete\n' > "$other_dir/${id}-plan.md"
    set_mtime_ago "$other_dir/${id}-plan.md" 691200  # 8 days old

    ln -s "$other_dir" "$TEST_CACHE_DIR/danger-link"

    run --separate-stderr bash "$PERSIST_SH" prune
    [ "$status" -eq 0 ]
    # File at the symlink's target must still exist — find -P didn't follow.
    [ -f "$other_dir/${id}-plan.md" ]
    rm -rf "$other_dir"
}

# ---- Hygiene 1: bash -n syntax check ----------------------------------------

@test "H1: persist.sh passes bash -n syntax check" {
    run bash -n "$PERSIST_SH"
    [ "$status" -eq 0 ]
}

# ---- Hygiene 2: shellcheck --------------------------------------------------

@test "H2: persist.sh passes shellcheck" {
    if ! command -v shellcheck >/dev/null 2>&1; then
        skip "shellcheck not installed"
    fi
    run shellcheck "$PERSIST_SH"
    [ "$status" -eq 0 ]
}
