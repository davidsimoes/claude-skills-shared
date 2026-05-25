#!/usr/bin/env bash
# persist.sh — /fresh-eyes Step 0 cache + lock + git materialization helpers
#
# Subcommands: init, resume <id>, materialize <id> <target>, release-lock <id>, prune
#
# I/O contract:
#   stdout: key=value lines (parse on FIRST '=' per line; blank/# ignored)
#   stderr: DEGRADED:/error messages (never on stdout)
#
# Exit codes:
#   0   success
#   1   generic failure (transient I/O, disk full)
#   65  data error (malformed input, bad ref, missing cache files)
#   70  internal error (bug in this script)
#   75  lock conflict (init: bump+retry; resume: surface to user)
#   78  config error ($HOME unset, python3 missing, read-only $CACHE_DIR)
#
# Public contract: prune subcommand can also be invoked from other skills as a backstop.

set -u

# ---- Pre-checks (config gate) -----------------------------------------------

if [[ -z "${CACHE_DIR:-}" ]]; then
    if [[ -z "${HOME:-}" ]]; then
        echo "DEGRADED: HOME is unset and CACHE_DIR not provided" >&2
        exit 78
    fi
    CACHE_DIR="$HOME/.claude/cache/fresh-eyes"
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "DEGRADED: python3 not found in PATH (required for ms-precision audit_session_id)" >&2
    exit 78
fi

if ! python3 -c "import sys; sys.exit(0 if sys.version_info >= (3,6) else 1)" 2>/dev/null; then
    echo "DEGRADED: python3 too old (need >= 3.6 for f-strings)" >&2
    exit 78
fi

STALE_LOCK_SECONDS=3600

# ---- Helpers ----------------------------------------------------------------

# Generate millisecond-precision ISO timestamp, no colons. Format:
#   YYYY-MM-DDTHHMMSS.mmmZ  e.g.  2026-05-07T070812.242Z
gen_audit_id() {
    python3 -c "
from datetime import datetime, timezone
n = datetime.now(timezone.utc)
print(n.strftime('%Y-%m-%dT%H%M%S.') + f'{n.microsecond//1000:03d}Z')
"
}

# Cross-platform mtime-in-seconds for a given path.
mtime_epoch() {
    local path="$1"
    if stat -f %m "$path" >/dev/null 2>&1; then
        # BSD stat (macOS)
        stat -f %m "$path"
    else
        # GNU stat (Linux)
        stat -c %Y "$path"
    fi
}

# Ensure cache dir exists. Exit 78 if read-only or unwritable.
ensure_cache_dir() {
    if ! mkdir -p "$CACHE_DIR" 2>/dev/null; then
        echo "DEGRADED: cannot create cache dir $CACHE_DIR (read-only or no permission)" >&2
        exit 78
    fi
    if [[ ! -w "$CACHE_DIR" ]]; then
        echo "DEGRADED: cache dir $CACHE_DIR is not writable" >&2
        exit 78
    fi
}

# Attempt to remove a stale lock dir if its mtime is older than the threshold.
# strict-greater-than: a lock with age == STALE_LOCK_SECONDS is still considered fresh.
# rmdir returning ENOENT (lock already cleaned by another caller) is treated as success.
maybe_reap_stale_lock() {
    local lock="$1"
    [[ -d "$lock" ]] || return 0
    local mtime now age
    mtime=$(mtime_epoch "$lock" 2>/dev/null) || return 0
    now=$(date +%s)
    age=$((now - mtime))
    if (( age > STALE_LOCK_SECONDS )); then
        if rmdir "$lock" 2>/dev/null; then
            return 0
        fi
        # ENOENT (already-cleaned race) treated as success; any other failure is non-fatal here.
        if [[ ! -d "$lock" ]]; then
            return 0
        fi
    fi
    return 0
}

# Validate a single git revision OR a range (A..B / A...B).
# Returns 0 on success, 65 on bad ref / empty ref.
verify_ref() {
    local ref="$1" label="$2" left right
    if [[ -z "$ref" ]]; then
        echo "DEGRADED: $label is empty" >&2
        return 65
    fi
    case "$ref" in
        *...*)
            left="${ref%%...*}"
            right="${ref##*...}"
            ;;
        *..*)
            left="${ref%%..*}"
            right="${ref##*..}"
            ;;
        *)
            left="$ref"
            right=""
            ;;
    esac
    if ! git rev-parse --verify "$left" >/dev/null 2>&1; then
        echo "DEGRADED: $label '$left' not found" >&2
        return 65
    fi
    if [[ -n "$right" ]]; then
        if ! git rev-parse --verify "$right" >/dev/null 2>&1; then
            echo "DEGRADED: $label '$right' not found" >&2
            return 65
        fi
    fi
    return 0
}

# Acquire lock atomically via mkdir.
# Side effects: stale-lock recovery before mkdir.
# Returns 0 on success, 75 on EEXIST (lock held), 1 on other failure.
acquire_lock() {
    local lock="$1"
    maybe_reap_stale_lock "$lock"
    if mkdir "$lock" 2>/dev/null; then
        return 0
    fi
    if [[ -d "$lock" ]]; then
        return 75
    fi
    return 1
}

# Release a lock idempotently. ENOENT treated as success.
# Sets RELEASED=true|false in caller scope.
release_lock_idempotent() {
    local lock="$1"
    if [[ -d "$lock" ]]; then
        if rmdir "$lock" 2>/dev/null; then
            RELEASED=true
            return 0
        fi
        # rmdir ENOENT (race with concurrent stale-recovery) → already released.
        if [[ ! -d "$lock" ]]; then
            RELEASED=false
            return 0
        fi
        return 1
    fi
    RELEASED=false
    return 0
}

# Check if at least one cache file exists for a given audit_session_id.
# A "cache file" is any of plan/manifest/diff/branch/commit with size > 0.
has_cache_files() {
    local id="$1" suffix path
    for suffix in plan manifest diff branch commit; do
        path="$CACHE_DIR/${id}-${suffix}.md"
        if [[ -s "$path" ]]; then
            return 0
        fi
    done
    return 1
}

# Validate that an audit_session_id matches the expected ISO format.
# Prevents path traversal and odd inputs from poisoning lock paths.
validate_audit_id() {
    local id="$1"
    if [[ ! "$id" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}\.[0-9]{3}Z$ ]]; then
        echo "DEGRADED: invalid audit_session_id format: $id" >&2
        return 65
    fi
    return 0
}

# ---- Subcommand: init -------------------------------------------------------

cmd_init() {
    ensure_cache_dir
    local id lock plan_path
    id=$(gen_audit_id)
    if [[ -z "$id" ]]; then
        echo "DEGRADED: failed to generate audit_session_id" >&2
        exit 70
    fi
    lock="$CACHE_DIR/.lock-${id}"
    plan_path="$CACHE_DIR/${id}-plan.md"
    local rc=0
    acquire_lock "$lock" || rc=$?
    if (( rc == 75 )); then
        echo "DEGRADED: lock already held for $id (millisecond collision; bump and retry)" >&2
        exit 75
    fi
    if (( rc != 0 )); then
        echo "DEGRADED: failed to acquire lock $lock (rc=$rc)" >&2
        exit 1
    fi
    printf 'audit_session_id=%s\n' "$id"
    printf 'cache_dir=%s\n' "$CACHE_DIR"
    printf 'lock=%s\n' "$lock"
    printf 'plan_path=%s\n' "$plan_path"
}

# ---- Subcommand: resume <id> ------------------------------------------------

cmd_resume() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        echo "DEGRADED: resume requires <audit_session_id>" >&2
        exit 65
    fi
    validate_audit_id "$id" || exit 65
    ensure_cache_dir
    local lock="$CACHE_DIR/.lock-${id}"
    local plan_path="$CACHE_DIR/${id}-plan.md"

    # Acquire lock FIRST. Stale-recovery handled inside acquire_lock.
    local rc=0
    acquire_lock "$lock" || rc=$?
    if (( rc == 75 )); then
        echo "DEGRADED: lock for $id is held fresh by another caller — surface to user, do not retry" >&2
        exit 75
    fi
    if (( rc != 0 )); then
        echo "DEGRADED: failed to acquire lock $lock (rc=$rc)" >&2
        exit 1
    fi

    # We now hold the lock. Verify cache files exist.
    if ! has_cache_files "$id"; then
        # Auto-release lock before exiting 65 (no leaked lock for stale-recovery to deal with).
        local _ignored=true
        RELEASED=false
        release_lock_idempotent "$lock" || _ignored=false
        echo "DEGRADED: no cache files (plan/manifest/diff/branch/commit, size > 0) found for $id" >&2
        exit 65
    fi

    printf 'audit_session_id=%s\n' "$id"
    printf 'cache_dir=%s\n' "$CACHE_DIR"
    printf 'lock=%s\n' "$lock"
    printf 'plan_path=%s\n' "$plan_path"
}

# ---- Subcommand: materialize <id> <target> ----------------------------------

cmd_materialize() {
    local id="${1:-}" target="${2:-}"
    if [[ -z "$id" || -z "$target" ]]; then
        echo "DEGRADED: materialize requires <audit_session_id> <target>" >&2
        exit 65
    fi
    validate_audit_id "$id" || exit 65
    ensure_cache_dir

    if ! git -C "$PWD" rev-parse --git-dir >/dev/null 2>&1; then
        echo "DEGRADED: cwd '$PWD' is not a git repo" >&2
        exit 65
    fi

    local kind ref out_path
    case "$target" in
        diff:*)
            kind="diff"
            ref="${target#diff:}"
            out_path="$CACHE_DIR/${id}-diff.md"
            ;;
        branch:*)
            kind="branch"
            ref="${target#branch:}"
            out_path="$CACHE_DIR/${id}-branch.md"
            ;;
        commit:*)
            kind="commit"
            ref="${target#commit:}"
            out_path="$CACHE_DIR/${id}-commit.md"
            ;;
        *)
            echo "DEGRADED: unrecognized target '$target' (expected diff:/branch:/commit:)" >&2
            exit 65
            ;;
    esac

    verify_ref "$ref" "$kind" || exit 65

    # Run the appropriate git command, write to file, then check size.
    case "$kind" in
        diff)
            git diff "$ref" > "$out_path" 2>/dev/null || {
                echo "DEGRADED: git diff '$ref' failed" >&2
                rm -f "$out_path"
                exit 1
            }
            ;;
        branch)
            # Detect the default base branch dynamically (origin/HEAD → main/master/etc.).
            # Falls back to "main" if no remote-tracking ref is set up.
            local base
            base=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
            base="${base:-main}"
            git log "${base}..${ref}" --stat -p > "$out_path" 2>/dev/null || {
                echo "DEGRADED: git log '${base}..${ref}' failed" >&2
                rm -f "$out_path"
                exit 1
            }
            ;;
        commit)
            git show "$ref" --stat > "$out_path" 2>/dev/null || {
                echo "DEGRADED: git show '$ref' failed" >&2
                rm -f "$out_path"
                exit 1
            }
            ;;
    esac

    # Check size; warn but produce file if > 2MB.
    local size
    if [[ -f "$out_path" ]]; then
        size=$(wc -c < "$out_path" | tr -d ' ')
        if (( size > 2097152 )); then
            echo "DEGRADED: output exceeds 2MB ($size bytes) — subagents may hit context truncation" >&2
        fi
    fi

    printf 'materialized_path=%s\n' "$out_path"
}

# ---- Subcommand: release-lock <id> ------------------------------------------

cmd_release_lock() {
    local id="${1:-}"
    if [[ -z "$id" ]]; then
        echo "DEGRADED: release-lock requires <audit_session_id>" >&2
        exit 65
    fi
    validate_audit_id "$id" || exit 65
    ensure_cache_dir
    local lock="$CACHE_DIR/.lock-${id}"
    RELEASED=false
    release_lock_idempotent "$lock" || {
        echo "DEGRADED: failed to release lock $lock" >&2
        exit 1
    }
    printf 'released=%s\n' "$RELEASED"
}

# ---- Subcommand: prune ------------------------------------------------------

cmd_prune() {
    local plans=0 manifests=0 materialized=0 requirements=0 verdicts=0
    if [[ ! -d "$CACHE_DIR" ]]; then
        printf 'pruned_plans=0\n'
        printf 'pruned_manifests=0\n'
        printf 'pruned_materialized=0\n'
        printf 'pruned_requirements=0\n'
        printf 'pruned_verdicts=0\n'
        return 0
    fi

    # 7-day TTL: plans, manifests, diffs, branches, commits, requirements.
    plans=$(find -P "$CACHE_DIR" -type f -name '*-plan.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
    manifests=$(find -P "$CACHE_DIR" -type f -name '*-manifest.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
    local diffs branches commits
    diffs=$(find -P "$CACHE_DIR" -type f -name '*-diff.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
    branches=$(find -P "$CACHE_DIR" -type f -name '*-branch.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
    commits=$(find -P "$CACHE_DIR" -type f -name '*-commit.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')
    materialized=$((diffs + branches + commits))
    # ESCALATE Branch B writes <id>-requirements.md; same TTL as plans.
    requirements=$(find -P "$CACHE_DIR" -type f -name '*-requirements.md' -mtime +7 -print -delete 2>/dev/null | wc -l | tr -d ' ')

    # 30-day TTL: verdicts.
    verdicts=$(find -P "$CACHE_DIR" -type f -name '*-verdict-round*.md' -mtime +30 -print -delete 2>/dev/null | wc -l | tr -d ' ')

    printf 'pruned_plans=%s\n' "$plans"
    printf 'pruned_manifests=%s\n' "$manifests"
    printf 'pruned_materialized=%s\n' "$materialized"
    printf 'pruned_requirements=%s\n' "$requirements"
    printf 'pruned_verdicts=%s\n' "$verdicts"
}

# ---- Dispatch ---------------------------------------------------------------

usage() {
    cat >&2 <<'EOF'
Usage: persist.sh <subcommand> [args]

Subcommands:
  init                            Initialize a new audit session (generates audit_session_id, acquires lock).
  resume <audit_session_id>       Re-acquire lock for an existing audit session.
  materialize <id> <target>       Materialize a git target. target := diff:<ref>|diff:<A>..<B>|diff:<A>...<B>|branch:<name>|commit:<sha>.
  release-lock <id>               Release the lock for an audit session (idempotent).
  prune                           Delete stale cache files (plans/manifests/materialized > 7d; verdicts > 30d).

Environment:
  CACHE_DIR  override cache directory (default: $HOME/.claude/cache/fresh-eyes)

Public contract: prune subcommand can also be invoked from other skills as a backstop.
EOF
}

if [[ $# -lt 1 ]]; then
    usage
    exit 65
fi

sub="$1"
shift

case "$sub" in
    init)         cmd_init "$@" ;;
    resume)       cmd_resume "$@" ;;
    materialize)  cmd_materialize "$@" ;;
    release-lock) cmd_release_lock "$@" ;;
    prune)        cmd_prune "$@" ;;
    -h|--help)    usage; exit 0 ;;
    *)
        echo "DEGRADED: unknown subcommand '$sub'" >&2
        usage
        exit 65
        ;;
esac
