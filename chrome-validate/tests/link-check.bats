#!/usr/bin/env bats
# Tests for scripts/link-check.sh

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/link-check.sh"
}

# ---------- usage ----------

@test "no args prints usage and exits 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"Usage:"* ]]
}

@test "unknown subcommand exits 2" {
  run "$SCRIPT" bogus arg
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown subcommand"* ]]
}

@test "url with no arg exits 2" {
  run "$SCRIPT" url
  [ "$status" -eq 2 ]
}

@test "batch with no arg exits 2" {
  run "$SCRIPT" batch
  [ "$status" -eq 2 ]
}

# ---------- deterministic offline checks ----------
# 127.0.0.1 on a closed port returns status 000 (curl can't connect).
# This avoids flaky network deps.

@test "url on unreachable host fails (status 000)" {
  run "$SCRIPT" url "http://127.0.0.1:1/never-listens"
  [ "$status" -eq 1 ]
  [[ "$output" == *"000"* ]]
}

@test "batch reads file and reports per-line status" {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
http://127.0.0.1:1/a
http://127.0.0.1:1/b
EOF
  run "$SCRIPT" batch "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  # Two URL lines should be in output.
  local count
  count=$(echo "$output" | grep -c '127.0.0.1:1' || true)
  [ "$count" -eq 2 ]
}

@test "batch skips comment lines and blank lines" {
  local tmp
  tmp=$(mktemp)
  cat > "$tmp" <<EOF
# this is a comment
http://127.0.0.1:1/a

  # indented comment
EOF
  run "$SCRIPT" batch "$tmp"
  rm -f "$tmp"
  [ "$status" -eq 1 ]
  local count
  count=$(echo "$output" | grep -c '127.0.0.1:1' || true)
  [ "$count" -eq 1 ]
}

@test "stdin reads URLs from standard input" {
  run bash -c "echo 'http://127.0.0.1:1/a' | '$SCRIPT' stdin"
  [ "$status" -eq 1 ]
  [[ "$output" == *"127.0.0.1:1/a"* ]]
}

# ---------- live network (skipped if no internet) ----------

@test "url on https://example.com returns 200 (network)" {
  if ! curl -s --max-time 2 -o /dev/null https://example.com 2>/dev/null; then
    skip "no network or example.com unreachable"
  fi
  run "$SCRIPT" url "https://example.com"
  [ "$status" -eq 0 ]
  [[ "$output" == *"200"* ]]
}
