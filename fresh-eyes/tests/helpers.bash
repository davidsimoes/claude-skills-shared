#!/usr/bin/env bash
# Shared test helpers for persist.bats.

# shellcheck disable=SC2034  # variables are exported and consumed by bats / persist.sh

PERSIST_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/persist.sh"

setup() {
    # Explicit /tmp/ template — bypasses macOS's $TMPDIR redirection to /var/folders/...
    TEST_CACHE_DIR=$(mktemp -d /tmp/fresh-eyes-test-XXXXXX)
    export TEST_CACHE_DIR
    export CACHE_DIR="$TEST_CACHE_DIR"

    # Sanity gate: refuse to continue if mktemp slipped outside /tmp/.
    if [[ "$TEST_CACHE_DIR" != /tmp/* ]]; then
        echo "FATAL: TEST_CACHE_DIR ($TEST_CACHE_DIR) is not under /tmp/ — refusing to run" >&2
        exit 1
    fi

    # Clean PATH-shim staging area for tests that need to mock git.
    TEST_SHIM_DIR=$(mktemp -d /tmp/fresh-eyes-shim-XXXXXX)
    export TEST_SHIM_DIR
}

teardown() {
    if [[ -n "${TEST_CACHE_DIR:-}" && "$TEST_CACHE_DIR" == /tmp/* ]]; then
        rm -rf "$TEST_CACHE_DIR"
    fi
    if [[ -n "${TEST_SHIM_DIR:-}" && "$TEST_SHIM_DIR" == /tmp/* ]]; then
        rm -rf "$TEST_SHIM_DIR"
    fi
}

# Run persist.sh; output captured by bats $output / $status.
run_persist() {
    run bash "$PERSIST_SH" "$@"
}

# Parse a key=value line from $output. Echoes the value or empty if not found.
# shellcheck disable=SC2154  # $output is set by bats `run`
get_value() {
    local key="$1"
    echo "$output" | awk -F= -v k="$key" '$0 ~ "^"k"=" {sub("^"k"=",""); print; exit}'
}

# Set the mtime of a path to N seconds ago.
set_mtime_ago() {
    local path="$1" seconds_ago="$2"
    local now ts
    now=$(date +%s)
    ts=$((now - seconds_ago))
    # Cross-platform touch with epoch input.
    if touch -t "$(date -r "$ts" '+%Y%m%d%H%M.%S')" "$path" 2>/dev/null; then
        return 0
    fi
    # GNU fallback
    touch -d "@$ts" "$path"
}

# Set up a minimal real git repo in a temp dir and cd into it.
setup_git_repo() {
    GIT_REPO_DIR=$(mktemp -d /tmp/fresh-eyes-git-XXXXXX)
    export GIT_REPO_DIR
    cd "$GIT_REPO_DIR" || exit 1
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "test"
    echo "hello" > README.md
    git add README.md
    git commit -q -m "initial"
}

teardown_git_repo() {
    if [[ -n "${GIT_REPO_DIR:-}" && "$GIT_REPO_DIR" == /tmp/* ]]; then
        rm -rf "$GIT_REPO_DIR"
    fi
}
