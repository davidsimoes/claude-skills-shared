#!/usr/bin/env bash
# /delegate registry helper — manage ~/.claude/cache/delegate/*.json
#
# Subcommands:
#   list [--json]               — list active children (human table; --json for piped output)
#   resolve <name> [--json]     — fuzzy-match <name>, print single matching entry (exit 1 if 0 or >1)
#   prune [--dry-run]           — remove JSON entries whose tmux_target is dead
#   status <name>               — print single entry + live tail from tmux capture-pane
#
# Exit codes: 0 success, 1 no match / ambiguous, 2 bad args, 3 runtime error

set -u
set -o pipefail

REGISTRY_DIR="${HOME}/.claude/cache/delegate"
mkdir -p "$REGISTRY_DIR"

# --- helpers ---

# Get the live tmux target set: "session:window_index:window_name" per line.
# Uses window_index because window_name alone isn't unique across sessions.
_live_targets() {
  tmux list-panes -a -F '#{session_name}:#{window_index}:#{window_name}' 2>/dev/null | sort -u
}

# Check if a tmux target from a registry JSON is still alive.
# Registry stores tmux_target as "session:window_name" or "session:window_index.pane_index".
# We check both forms against live panes.
_target_alive() {
  local target="$1"
  # Try exact match first (handles "session:window_name")
  if tmux list-panes -t "$target" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

# Read a registry JSON safely; returns empty string on parse error.
_read_json() {
  local f="$1"
  jq -c . "$f" 2>/dev/null || echo ""
}

# Compute relative age from an ISO timestamp.
_age() {
  local iso="$1"
  [[ -z "$iso" ]] && { echo "?"; return; }
  local ts_then ts_now delta
  # macOS date: -j -f FORMAT; Linux date: -d
  if date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s >/dev/null 2>&1; then
    ts_then="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$iso" +%s 2>/dev/null)"
  else
    ts_then="$(date -d "$iso" +%s 2>/dev/null)"
  fi
  [[ -z "${ts_then:-}" ]] && { echo "?"; return; }
  ts_now="$(date +%s)"
  delta=$((ts_now - ts_then))
  if   (( delta < 60 ));     then echo "${delta}s"
  elif (( delta < 3600 ));   then echo "$((delta / 60))m"
  elif (( delta < 86400 ));  then echo "$((delta / 3600))h"
  else                            echo "$((delta / 86400))d"
  fi
}

# --- list ---

cmd_list() {
  local json_mode=0
  if [[ "${1:-}" == "--json" ]]; then json_mode=1; fi

  shopt -s nullglob
  local files=( "$REGISTRY_DIR"/*.json )
  shopt -u nullglob

  if [[ ${#files[@]} -eq 0 ]]; then
    if [[ "$json_mode" -eq 1 ]]; then
      echo "[]"
    else
      echo "No delegated children registered."
    fi
    return 0
  fi

  if [[ "$json_mode" -eq 1 ]]; then
    # Emit a JSON array of enriched entries with computed `live` field.
    local first=1
    echo "["
    for f in "${files[@]}"; do
      local j; j="$(_read_json "$f")"
      [[ -z "$j" ]] && continue
      local target; target="$(echo "$j" | jq -r '.tmux_target // ""')"
      local live="false"
      _target_alive "$target" && live="true"
      local entry; entry="$(echo "$j" | jq --arg live "$live" --arg file "$f" '. + {live: ($live == "true"), _file: $file}')"
      if [[ "$first" -eq 1 ]]; then first=0; else echo ","; fi
      echo "$entry"
    done
    echo "]"
    return 0
  fi

  # Human table. Columns: NAME, TMUX, CWD (basename), SUMMARY, AGE, STATE
  printf "%-20s %-18s %-22s %-40s %-8s %s\n" "NAME" "TMUX" "CWD" "SUMMARY" "AGE" "STATE"
  printf "%-20s %-18s %-22s %-40s %-8s %s\n" "----" "----" "---" "-------" "---" "-----"

  for f in "${files[@]}"; do
    local j; j="$(_read_json "$f")"
    [[ -z "$j" ]] && continue

    local name target cwd summary spawned status
    name="$(echo "$j" | jq -r '.name // "?"')"
    target="$(echo "$j" | jq -r '.tmux_target // "?"')"
    cwd="$(echo "$j" | jq -r '.cwd // "?"')"
    summary="$(echo "$j" | jq -r '.summary // "(none)"')"
    spawned="$(echo "$j" | jq -r '.spawned_at // ""')"
    status="$(echo "$j" | jq -r '.status // "?"')"

    local cwd_short; cwd_short="$(basename "$cwd")"
    local age; age="$(_age "$spawned")"

    local state_flag="$status"
    if ! _target_alive "$target"; then
      state_flag="☠ stale"
    fi

    # Truncate long strings for table display.
    local name_s target_s cwd_s summary_s
    name_s="$(printf "%.20s" "$name")"
    target_s="$(printf "%.18s" "$target")"
    cwd_s="$(printf "%.22s" "$cwd_short")"
    summary_s="$(printf "%.40s" "$summary")"

    printf "%-20s %-18s %-22s %-40s %-8s %s\n" "$name_s" "$target_s" "$cwd_s" "$summary_s" "$age" "$state_flag"
  done
}

# --- resolve ---

cmd_resolve() {
  local name="${1:-}"
  local json_mode=0
  if [[ "${2:-}" == "--json" ]]; then json_mode=1; fi

  if [[ -z "$name" ]]; then
    echo "usage: registry.sh resolve <name> [--json]" >&2
    exit 2
  fi

  shopt -s nullglob
  local files=( "$REGISTRY_DIR"/*.json )
  shopt -u nullglob

  [[ ${#files[@]} -eq 0 ]] && { echo "No active children." >&2; exit 1; }

  # Get the caller's own tmux target so we can exclude it.
  # IMPORTANT: use $TMUX_PANE to target the calling pane specifically —
  # bare `tmux display-message` returns the focused pane (wherever the user
  # is looking), NOT the pane that invoked this script.
  local self_target=""
  local self_short=""
  if [[ -n "${TMUX_PANE:-}" ]]; then
    self_target="$(tmux display-message -p -t "$TMUX_PANE" '#S:#I:#W' 2>/dev/null || true)"
    self_short="$(tmux display-message -p -t "$TMUX_PANE" '#S:#W' 2>/dev/null || true)"
  fi

  # Lowercase the query, split on spaces for multi-word matching.
  local query; query="$(echo "$name" | tr '[:upper:]' '[:lower:]')"

  local matches=()
  for f in "${files[@]}"; do
    local j; j="$(_read_json "$f")"
    [[ -z "$j" ]] && continue

    local rname rtarget rcwd rsummary
    rname="$(echo "$j" | jq -r '.name // ""')"
    rtarget="$(echo "$j" | jq -r '.tmux_target // ""')"
    rcwd="$(echo "$j" | jq -r '.cwd // ""')"
    rsummary="$(echo "$j" | jq -r '.summary // ""')"

    # Skip caller's own registry entry.
    if [[ -n "$self_target" && "$rtarget" == "$self_target" ]] \
       || [[ -n "$self_short" && "$rtarget" == "$self_short" ]]; then
      continue
    fi

    # Skip dead targets for resolution — user should use prune to clean them.
    _target_alive "$rtarget" || continue

    # Build haystack: name + tmux_target + cwd + summary, lowercased.
    local haystack
    haystack="$(printf "%s %s %s %s" "$rname" "$rtarget" "$rcwd" "$rsummary" | tr '[:upper:]' '[:lower:]')"

    # All query words must appear as substrings (independent substring match).
    local hit=1
    for word in $query; do
      if [[ "$haystack" != *"$word"* ]]; then
        hit=0; break
      fi
    done

    if [[ "$hit" -eq 1 ]]; then
      matches+=("$f")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    echo "No match for '$name'." >&2
    echo "Active children:" >&2
    for f in "${files[@]}"; do
      jq -r '.name + "  (" + .tmux_target + ")"' "$f" 2>/dev/null
    done >&2
    exit 1
  fi

  if [[ ${#matches[@]} -gt 1 ]]; then
    echo "Ambiguous: '$name' matched ${#matches[@]} children:" >&2
    for f in "${matches[@]}"; do
      jq -r '.name + "  (" + .tmux_target + ")  — " + (.summary // "(no summary)")' "$f" 2>/dev/null
    done >&2
    exit 1
  fi

  # Exactly one match.
  if [[ "$json_mode" -eq 1 ]]; then
    jq -c --arg file "${matches[0]}" '. + {_file: $file}' "${matches[0]}"
  else
    jq -r '.tmux_target' "${matches[0]}"
  fi
}

# --- prune ---

cmd_prune() {
  local dry_run=0
  if [[ "${1:-}" == "--dry-run" ]]; then dry_run=1; fi

  shopt -s nullglob
  local files=( "$REGISTRY_DIR"/*.json )
  shopt -u nullglob

  local removed=0
  local kept=0

  for f in "${files[@]}"; do
    local j; j="$(_read_json "$f")"
    if [[ -z "$j" ]]; then
      # Corrupt / unparseable → prune regardless.
      if [[ "$dry_run" -eq 1 ]]; then
        echo "would remove (unparseable): $f"
      else
        rm -f "$f"
        echo "removed (unparseable): $(basename "$f")"
      fi
      removed=$((removed + 1))
      continue
    fi
    local target; target="$(echo "$j" | jq -r '.tmux_target // ""')"
    if [[ -z "$target" ]] || ! _target_alive "$target"; then
      if [[ "$dry_run" -eq 1 ]]; then
        echo "would remove: $(basename "$f")  (target: ${target:-none})"
      else
        rm -f "$f"
        echo "removed: $(basename "$f")  (target: ${target:-none})"
      fi
      removed=$((removed + 1))
    else
      kept=$((kept + 1))
    fi
  done

  echo "---"
  if [[ "$dry_run" -eq 1 ]]; then
    echo "dry-run: would remove $removed, keep $kept"
  else
    echo "pruned $removed, kept $kept"
  fi
}

# --- status ---

cmd_status() {
  local name="${1:-}"
  if [[ -z "$name" ]]; then
    echo "usage: registry.sh status <name>" >&2
    exit 2
  fi

  local entry; entry="$("$0" resolve "$name" --json 2>/dev/null)" || {
    # Surface resolve's error message.
    "$0" resolve "$name" --json >/dev/null
    exit $?
  }

  local target name cwd summary spawned last_updated status
  name="$(echo "$entry" | jq -r '.name')"
  target="$(echo "$entry" | jq -r '.tmux_target')"
  cwd="$(echo "$entry" | jq -r '.cwd')"
  summary="$(echo "$entry" | jq -r '.summary // "(none set)"')"
  spawned="$(echo "$entry" | jq -r '.spawned_at // ""')"
  last_updated="$(echo "$entry" | jq -r '.last_updated // ""')"
  status="$(echo "$entry" | jq -r '.status // "?"')"

  echo "$target"
  echo "  name:        $name"
  echo "  cwd:         $cwd"
  echo "  summary:     $summary"
  echo "  spawned:     $(_age "$spawned") ago"
  echo "  last_update: $(_age "$last_updated") ago"
  echo "  status:      $status"
  echo ""
  echo "  Live tail (last 10 lines):"
  tmux capture-pane -t "$target" -p 2>/dev/null | tail -10 | sed 's/^/    /'
}

# --- dispatcher ---

case "${1:-}" in
  list)    shift; cmd_list "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  prune)   shift; cmd_prune "$@" ;;
  status)  shift; cmd_status "$@" ;;
  ""|-h|--help)
    cat <<'USAGE'
registry.sh — /delegate registry helper

  list [--json]               List active children (human table; --json for piped output)
  resolve <name> [--json]     Fuzzy-match <name>; print tmux_target (exit 1 if 0 or >1 matches)
  prune [--dry-run]           Remove JSON entries whose tmux_target is dead
  status <name>               Print single entry + live tail from tmux capture-pane

Registry dir: ~/.claude/cache/delegate/
USAGE
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    exit 2
    ;;
esac
