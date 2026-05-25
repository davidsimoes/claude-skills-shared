#!/usr/bin/env bash
# pdf-validate.sh — PDF text extraction, diacritic count, HTML-source diff.
#
# Catches font-subsetting failures that drop non-ASCII glyphs (diacritics) from
# PDFs even when the source HTML is clean. Default diacritic set is Czech; edit
# the DIACRITICS regex below to cover other languages (Polish, Vietnamese, etc.).
#
# Usage:
#   pdf-validate.sh extract <pdf-path>
#       Prints extracted text to stdout.
#
#   pdf-validate.sh diacritic-count <pdf-path>
#       Prints: count=<n> floor=10 status=PASS|FAIL
#       Counts diacritic characters per the DIACRITICS regex. Floor of 10 for
#       any non-trivial document in a language that uses diacritics.
#
#   pdf-validate.sh diff-html <pdf-path> <html-path>
#       Extracts text from both, normalizes whitespace, diffs.
#       Prints: status=PASS|FAIL diff_lines=<n>
#       Then the diff to stdout (head -40).
#
# Exit codes: 0=PASS, 1=FAIL, 2=usage error, 3=missing tool, 4=missing file.

set -euo pipefail

DIACRITICS='[řůčěšžýáíéťďňóúŘŮČĚŠŽÝÁÍÉŤĎŇÓÚ]'
DIACRITIC_FLOOR=10

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "ERROR: required tool not found: $1" >&2
    exit 3
  fi
}

require_file() {
  if [[ ! -f "$1" ]]; then
    echo "ERROR: file not found: $1" >&2
    exit 4
  fi
}

cmd_extract() {
  local pdf="$1"
  require_tool pdftotext
  require_file "$pdf"
  pdftotext -layout "$pdf" -
}

cmd_diacritic_count() {
  local pdf="$1"
  require_tool pdftotext
  require_file "$pdf"
  # grep returns 1 when there are zero matches; under `set -e` that would kill
  # the script before we can report count=0. `|| true` keeps us going so the
  # caller sees the actual count.
  local count
  count=$(pdftotext -layout "$pdf" - | grep -o -E "$DIACRITICS" 2>/dev/null | wc -l | tr -d ' ' || true)
  count=${count:-0}
  if (( count >= DIACRITIC_FLOOR )); then
    echo "count=$count floor=$DIACRITIC_FLOOR status=PASS"
    exit 0
  else
    echo "count=$count floor=$DIACRITIC_FLOOR status=FAIL"
    echo "FAIL reason: PDF has fewer than $DIACRITIC_FLOOR diacritic chars" >&2
    echo "  Likely cause: font subsetting dropped diacritic glyphs" >&2
    echo "  Fix: regenerate PDF with full Unicode font subset" >&2
    exit 1
  fi
}

cmd_diff_html() {
  local pdf="$1"
  local html="$2"
  require_tool pdftotext
  require_tool python3
  require_file "$pdf"
  require_file "$html"

  # Don't use `local` here — the EXIT trap fires after this function's scope
  # ends, and would see an unbound variable under `set -u`.
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  pdftotext -layout "$pdf" "$tmpdir/pdf.txt"

  # Compare HTML vs PDF as collapsed character streams. Whitespace is dropped
  # entirely, because pdftotext can wrap inside a word ("žluťoučký" → "žlu\n
  # ťoučký") which would break a word-by-word diff. We don't care about
  # whitespace anyway — only material text difference.
  #
  # Skip <head>, <title>, <script>, <style>, <noscript> in HTML.
  python3 - "$html" "$tmpdir/pdf.txt" <<'PY'
import sys, re, difflib
from html.parser import HTMLParser

SKIP = {'script', 'style', 'noscript', 'head'}  # head encloses title/meta/link

class TextExtractor(HTMLParser):
    def __init__(self):
        super().__init__()
        self.out = []
        self.skip_depth = 0
    def handle_starttag(self, tag, attrs):
        if tag in SKIP:
            self.skip_depth += 1
    def handle_endtag(self, tag):
        if tag in SKIP and self.skip_depth > 0:
            self.skip_depth -= 1
    def handle_data(self, data):
        if self.skip_depth == 0:
            self.out.append(data)

def normalize(s):
    return re.sub(r'\s+', '', s)

html_src = open(sys.argv[1], encoding='utf-8').read()
p = TextExtractor()
p.feed(html_src)
html_text = normalize(''.join(p.out))

pdf_text = normalize(open(sys.argv[2], encoding='utf-8').read())

if html_text == pdf_text:
    print('diff_lines=0 status=PASS')
    sys.exit(0)

# Show the regions that differ. Use SequenceMatcher to find gaps.
sm = difflib.SequenceMatcher(None, html_text, pdf_text)
diffs = []
for tag, i1, i2, j1, j2 in sm.get_opcodes():
    if tag == 'equal':
        continue
    diffs.append(f'{tag}: html[{i1}:{i2}]={html_text[i1:i2]!r}  pdf[{j1}:{j2}]={pdf_text[j1:j2]!r}')

print(f'diff_lines={len(diffs)} status=FAIL')
for line in diffs[:40]:
    print(line)
sys.exit(1)
PY
}

usage() {
  cat <<EOF >&2
Usage:
  $(basename "$0") extract <pdf-path>
  $(basename "$0") diacritic-count <pdf-path>
  $(basename "$0") diff-html <pdf-path> <html-path>
EOF
  exit 2
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    extract)         [[ $# -eq 1 ]] || usage; cmd_extract "$1" ;;
    diacritic-count) [[ $# -eq 1 ]] || usage; cmd_diacritic_count "$1" ;;
    diff-html)       [[ $# -eq 2 ]] || usage; cmd_diff_html "$1" "$2" ;;
    ""|-h|--help)    usage ;;
    *)               echo "ERROR: unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
