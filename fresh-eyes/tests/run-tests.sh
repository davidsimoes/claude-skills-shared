#!/usr/bin/env bash
# run-tests.sh — wrapper for /fresh-eyes persist.sh test suite.
# Steps: bats version check (semver) → bash -n → shellcheck (if installed) → bats tests/.

set -u

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PERSIST_SH="$SKILL_DIR/scripts/persist.sh"
TESTS_DIR="$SKILL_DIR/tests"
HELPERS_BASH="$TESTS_DIR/helpers.bash"

MIN_BATS="1.11.0"

if ! command -v bats >/dev/null 2>&1; then
    echo "ERROR: bats not found. Install: brew install bats-core (minimum $MIN_BATS)" >&2
    echo "       https://github.com/bats-core/bats-core" >&2
    exit 1
fi

# Semver compare via sort -V (NOT lex).
bats_version=$(bats --version | awk '{print $NF}')
lowest=$(printf '%s\n%s\n' "$bats_version" "$MIN_BATS" | sort -V | head -n 1)
if [[ "$lowest" != "$MIN_BATS" ]]; then
    echo "ERROR: bats $bats_version is older than required minimum $MIN_BATS" >&2
    echo "       Upgrade: brew upgrade bats-core" >&2
    exit 1
fi

echo "→ bash -n $PERSIST_SH"
if ! bash -n "$PERSIST_SH"; then
    echo "ERROR: persist.sh failed bash -n syntax check" >&2
    exit 1
fi

if command -v shellcheck >/dev/null 2>&1; then
    echo "→ shellcheck $PERSIST_SH $HELPERS_BASH"
    if ! shellcheck "$PERSIST_SH" "$HELPERS_BASH"; then
        echo "ERROR: persist.sh / helpers.bash failed shellcheck" >&2
        exit 1
    fi
else
    echo "→ shellcheck not installed; skipping (optional)"
fi

echo "→ bats $TESTS_DIR"
exec bats "$TESTS_DIR"
