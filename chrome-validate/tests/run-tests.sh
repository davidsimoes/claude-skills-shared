#!/usr/bin/env bash
# run-tests.sh — wrapper that runs static checks then bats.
# Per ~/.claude/rules/script-extraction-discipline.md:
#   "Add a tests/run-tests.sh wrapper that runs `bash -n`, `shellcheck`,
#    then `bats tests/`."

set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$DIR/.." && pwd)"
SCRIPTS_DIR="$SKILL_DIR/scripts"

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
blue()  { printf '\033[34m%s\033[0m\n' "$*"; }

blue "== bash -n (syntax check) =="
for f in "$SCRIPTS_DIR"/*.sh; do
  bash -n "$f" && green "OK $(basename "$f")"
done

blue ""
blue "== shellcheck =="
if command -v shellcheck >/dev/null 2>&1; then
  shellcheck "$SCRIPTS_DIR"/*.sh && green "shellcheck OK"
else
  red "shellcheck not installed — skipping (install via: brew install shellcheck)"
fi

blue ""
blue "== bats tests =="
if command -v bats >/dev/null 2>&1; then
  bats "$DIR"/*.bats
else
  red "bats not installed — install via: brew install bats-core"
  exit 3
fi
