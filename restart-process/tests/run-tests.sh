#!/usr/bin/env bash
# run-tests.sh — wrapper that does bash -n + shellcheck + bats for /restart-process.

set -uo pipefail

cd "$(dirname "$0")/.."
SKILL_DIR="$(pwd)"

echo "=== bash -n (syntax check all .sh) ==="
fail=0
for f in scripts/*.sh; do
    if bash -n "$f"; then
        echo "  OK: $f"
    else
        echo "  FAIL: $f"
        fail=1
    fi
done

echo ""
echo "=== python -c py_compile (syntax check all .py) ==="
for f in scripts/*.py; do
    if python3 -c "import py_compile; py_compile.compile('$f', doraise=True)" 2>/dev/null; then
        echo "  OK: $f"
    else
        echo "  FAIL: $f"
        fail=1
    fi
done

echo ""
if command -v shellcheck >/dev/null 2>&1; then
    echo "=== shellcheck (warn-level) ==="
    for f in scripts/*.sh; do
        # SC1091 = source-not-found (we use absolute paths anyway)
        # SC2086 = word-splitting concerns (we deliberately split some pid lists)
        # SC2034 = unused vars (some intentional placeholders)
        # SC1083 = @{u} is real git syntax (upstream ref), false positive
        # SC2155 = declare+assign on same line (cosmetic)
        shellcheck -S warning -e SC1091,SC2086,SC2034,SC1083,SC2155 "$f" && echo "  OK: $f" || { echo "  warnings in $f"; fail=1; }
    done
else
    echo "(shellcheck not installed, skipping)"
fi

echo ""
if command -v bats >/dev/null 2>&1; then
    echo "=== bats tests ==="
    bats tests/*.bats || fail=1
else
    echo "(bats not installed, skipping — install: brew install bats-core)"
fi

echo ""
if [ "$fail" = "0" ]; then
    echo "✅ all checks passed"
    exit 0
else
    echo "❌ some checks failed"
    exit 1
fi
