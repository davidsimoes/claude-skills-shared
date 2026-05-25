#!/usr/bin/env bash
# link-check.sh — curl-based liveness check for URLs.
#
# Usage:
#   link-check.sh url <url>
#       Single URL check. Prints: <url>  <status>
#       Exit 0 if 2xx, 1 otherwise.
#
#   link-check.sh batch <file>
#       File with one URL per line. Prints status per URL.
#       Exit 0 if all 2xx, 1 if any failure. Continues through all URLs.
#
#   link-check.sh stdin
#       Read URLs from stdin (one per line). Same as batch.
#
# Notes: 5s timeout per URL. HEAD requests (some servers reject HEAD; falls
# back to GET on 405/501). User-Agent set to a real browser string to avoid
# WAF false-positives.

set -euo pipefail

UA='Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0 Safari/537.36'
TIMEOUT=5

check_url() {
  local url="$1"
  local status
  # Try HEAD first
  status=$(curl -sI -L -o /dev/null -w '%{http_code}' \
                --max-time "$TIMEOUT" \
                -A "$UA" \
                "$url" 2>/dev/null || echo "000")
  # On 405 Method Not Allowed or 501 Not Implemented, retry with GET
  if [[ "$status" == "405" || "$status" == "501" ]]; then
    status=$(curl -s -L -o /dev/null -w '%{http_code}' \
                  --max-time "$TIMEOUT" \
                  -A "$UA" \
                  "$url" 2>/dev/null || echo "000")
  fi
  echo "$status"
}

cmd_url() {
  local url="$1"
  local status
  status=$(check_url "$url")
  echo "$url  $status"
  if [[ "$status" =~ ^2 ]]; then
    exit 0
  else
    exit 1
  fi
}

cmd_batch() {
  local input="$1"
  local any_fail=0
  while IFS= read -r url; do
    [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
    local status
    status=$(check_url "$url")
    echo "$url  $status"
    [[ "$status" =~ ^2 ]] || any_fail=1
  done < "$input"
  exit "$any_fail"
}

cmd_stdin() {
  local any_fail=0
  while IFS= read -r url; do
    [[ -z "$url" || "$url" =~ ^[[:space:]]*# ]] && continue
    local status
    status=$(check_url "$url")
    echo "$url  $status"
    [[ "$status" =~ ^2 ]] || any_fail=1
  done
  exit "$any_fail"
}

usage() {
  cat <<EOF >&2
Usage:
  $(basename "$0") url <url>
  $(basename "$0") batch <file-of-urls>
  $(basename "$0") stdin
EOF
  exit 2
}

main() {
  local sub="${1:-}"
  shift || true
  case "$sub" in
    url)           [[ $# -eq 1 ]] || usage; cmd_url "$1" ;;
    batch)         [[ $# -eq 1 ]] || usage; cmd_batch "$1" ;;
    stdin)         cmd_stdin ;;
    ""|-h|--help)  usage ;;
    *)             echo "ERROR: unknown subcommand: $sub" >&2; usage ;;
  esac
}

main "$@"
