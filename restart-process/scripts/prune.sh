#!/usr/bin/env bash
# prune.sh — cleanup of old restart-handoffs dirs (default: 30 days).
#
# Usage:
#   prune.sh [--days N] [--dry-run]
#
# Removes <root>/<ts>/ dirs older than N days (default 30) based on directory mtime.
# Skips the dir currently pointed at by `latest` symlink (so latest is never pruned).
#
# Output: NDJSON to stdout, one line per dir handled:
#   {"path":"...","mtime":"...","action":"removed|skipped|kept","reason":"..."}

set -uo pipefail

DAYS=30
DRY_RUN=0

while [ "$#" -gt 0 ]; do
    case "$1" in
        --days) DAYS="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        *) echo "ERROR: unknown arg $1" >&2; exit 1 ;;
    esac
done

ROOT="${RESTART_HANDOFFS_DIR:-$HOME/.cache/claude-restart}"
if [ ! -d "$ROOT" ]; then
    echo "(no restart-handoffs root yet: $ROOT)" >&2
    exit 0
fi

# Resolve `latest` symlink target (don't prune it)
LATEST_TARGET=""
if [ -L "$ROOT/latest" ]; then
    LATEST_TARGET=$(readlink "$ROOT/latest")
fi

CUTOFF_EPOCH=$(($(date +%s) - DAYS * 86400))

for dir in "$ROOT"/*; do
    [ -d "$dir" ] || continue
    base=$(basename "$dir")
    [ "$base" = "latest" ] && continue
    [ -n "$LATEST_TARGET" ] && [ "$base" = "$LATEST_TARGET" ] && {
        printf '{"path":"%s","action":"kept","reason":"is latest"}\n' "$dir"
        continue
    }

    # macOS stat
    mtime=$(stat -f %m "$dir" 2>/dev/null || stat -c %Y "$dir" 2>/dev/null || echo 0)
    if [ "$mtime" -lt "$CUTOFF_EPOCH" ]; then
        if [ "$DRY_RUN" = "1" ]; then
            printf '{"path":"%s","mtime":%d,"action":"would_remove","reason":"older than %d days"}\n' \
                "$dir" "$mtime" "$DAYS"
        else
            if rm -rf "$dir"; then
                printf '{"path":"%s","mtime":%d,"action":"removed","reason":"older than %d days"}\n' \
                    "$dir" "$mtime" "$DAYS"
            else
                printf '{"path":"%s","mtime":%d,"action":"failed","reason":"rm -rf failed"}\n' \
                    "$dir" "$mtime"
            fi
        fi
    else
        printf '{"path":"%s","mtime":%d,"action":"kept","reason":"within %d days"}\n' \
            "$dir" "$mtime" "$DAYS"
    fi
done
