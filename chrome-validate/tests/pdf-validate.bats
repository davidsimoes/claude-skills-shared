#!/usr/bin/env bats
# Tests for scripts/pdf-validate.sh

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../scripts/pdf-validate.sh"
  FIXTURES="${BATS_TEST_DIRNAME}/fixtures"
  CS_PDF="${FIXTURES}/cs.pdf"
  EN_PDF="${FIXTURES}/en.pdf"
  CS_HTML="${FIXTURES}/cs.html"
  CS_MISMATCH_HTML="${FIXTURES}/cs-mismatch.html"
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

@test "extract with no path exits 2" {
  run "$SCRIPT" extract
  [ "$status" -eq 2 ]
}

@test "diacritic-count with two args exits 2" {
  run "$SCRIPT" diacritic-count a b
  [ "$status" -eq 2 ]
}

@test "diff-html with one arg exits 2" {
  run "$SCRIPT" diff-html only-one
  [ "$status" -eq 2 ]
}

# ---------- missing file ----------

@test "extract on missing file exits 4" {
  run "$SCRIPT" extract /nonexistent/path.pdf
  [ "$status" -eq 4 ]
  [[ "$output" == *"file not found"* ]]
}

@test "diacritic-count on missing file exits 4" {
  run "$SCRIPT" diacritic-count /nonexistent/path.pdf
  [ "$status" -eq 4 ]
}

@test "diff-html on missing pdf exits 4" {
  run "$SCRIPT" diff-html /nonexistent/path.pdf "$CS_HTML"
  [ "$status" -eq 4 ]
}

@test "diff-html on missing html exits 4" {
  run "$SCRIPT" diff-html "$CS_PDF" /nonexistent/path.html
  [ "$status" -eq 4 ]
}

# ---------- extract ----------

@test "extract on cs.pdf produces text containing Czech diacritics" {
  run "$SCRIPT" extract "$CS_PDF"
  [ "$status" -eq 0 ]
  # bats test names are ASCII-only; check for the Czech word in the body.
  echo "$output" | grep -q 'větička'
}

@test "extract on en.pdf produces ASCII English text" {
  run "$SCRIPT" extract "$EN_PDF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Plain ASCII"* ]]
}

# ---------- diacritic-count ----------

@test "diacritic-count on cs.pdf passes (>=10 diacritics)" {
  run "$SCRIPT" diacritic-count "$CS_PDF"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=PASS"* ]]
}

@test "diacritic-count on en.pdf fails (no diacritics)" {
  run "$SCRIPT" diacritic-count "$EN_PDF"
  [ "$status" -eq 1 ]
  [[ "$output" == *"status=FAIL"* ]]
  [[ "$output" == *"count=0"* ]]
}

@test "diacritic-count output has key=value format" {
  run "$SCRIPT" diacritic-count "$CS_PDF"
  [[ "$output" == *"count="* ]]
  [[ "$output" == *"floor=10"* ]]
  [[ "$output" == *"status="* ]]
}

# ---------- diff-html ----------

@test "diff-html with matching content passes" {
  run "$SCRIPT" diff-html "$CS_PDF" "$CS_HTML"
  [ "$status" -eq 0 ]
  [[ "$output" == *"status=PASS"* ]]
}

@test "diff-html with mismatched content fails" {
  run "$SCRIPT" diff-html "$CS_PDF" "$CS_MISMATCH_HTML"
  [ "$status" -eq 1 ]
  [[ "$output" == *"status=FAIL"* ]]
}
