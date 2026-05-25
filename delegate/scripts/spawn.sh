#!/usr/bin/env bash
# /delegate spawn helper — tmux placement + claude startup + prompt paste
#
# Usage:
#   spawn.sh --name <slug> --cwd <path> --prompt-file <abs-path>
#            [--where pane|window|session|worktree]  (default: window)
#            [--session <tmux-session>]
#            [--model <name>]
#            [--cooperate true|false]
#            [--worktree-name <git-worktree-name>]   (only used if --where=worktree)
#
# Emits JSON to stdout on success:
#   {"session":"main","window":"My Child Task","cwd":"/path","tty":"/dev/ttysNNN","pid":12345,"target":"main:My Child Task","where":"window"}
#
# Exit codes: 0 success, 1 arg error, 2 tmux error, 3 timeout waiting for claude

set -u
set -o pipefail

NAME=""
CWD=""
PROMPT_FILE=""
SESSION=""
MODEL=""
COOPERATE="true"
WHERE="auto"  # v2: default 'auto' resolves to 'pane' or 'window' based on parent window state
WHERE_EXPLICIT=0
WORKTREE_NAME=""
SUMMARY=""
CHILD_PREFIX="↳ "  # v2: visual marker prepended to child window name (and pane title)
CHILD_COLOR="yellow"  # v2: claude /color used by child session for visual differentiation.
# Valid /color values verified from claude binary 2.1.132 strings dump:
#   black, blue, brown, cyan, gray, green, magenta, orange, pink, purple, white, yellow
# Plus aliases for default: default, reset, none, gray, grey
# Skips silently if session is a "swarm teammate" (clausona / managed-swarm — colors are leader-assigned).
PERMISSION_MODE="auto"  # v3: delegated children default to auto so they don't stall on prompts in
                        # a window the parent isn't watching. Override with --permission-mode <mode>
                        # or --no-auto.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2 ;;
    --cwd) CWD="$2"; shift 2 ;;
    --prompt-file) PROMPT_FILE="$2"; shift 2 ;;
    --session) SESSION="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    --cooperate) COOPERATE="$2"; shift 2 ;;
    --where) WHERE="$2"; WHERE_EXPLICIT=1; shift 2 ;;
    --worktree-name) WORKTREE_NAME="$2"; shift 2 ;;
    --summary) SUMMARY="$2"; shift 2 ;;
    --no-prefix) CHILD_PREFIX=""; shift ;;
    --color) CHILD_COLOR="$2"; shift 2 ;;
    --no-color) CHILD_COLOR=""; shift ;;
    --permission-mode) PERMISSION_MODE="$2"; shift 2 ;;
    --no-auto) PERMISSION_MODE="default"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

# Summary defaults to a one-liner hint — child should update on its first turn.
if [[ -z "$SUMMARY" ]]; then
  SUMMARY="Initializing — child will update summary on first turn."
fi

if [[ -z "$NAME" || -z "$CWD" || -z "$PROMPT_FILE" ]]; then
  echo "required: --name, --cwd, --prompt-file" >&2
  exit 1
fi

case "$WHERE" in
  pane|window|session|worktree|auto) ;;
  *) echo "invalid --where: $WHERE (must be pane|window|session|worktree|auto)" >&2; exit 1 ;;
esac

# v2: resolve 'auto' → 'pane' if caller's window has only 1 pane (clean), else 'window' (avoid clutter).
# This ergonomic default means most short-lived /delegate calls land as a side pane in the parent's
# window, making them obvious children — but if the parent already has a multi-pane layout, we fall
# back to a new window to not disrupt it.
if [[ "$WHERE" == "auto" ]]; then
  CALLER_PANE="${TMUX_PANE:-}"  # set by tmux for any pane (preferred over display-message)
  if [[ -n "$CALLER_PANE" ]]; then
    CALLER_WINDOW="$(tmux display-message -t "$CALLER_PANE" -p '#{session_name}:#{window_index}' 2>/dev/null || true)"
    if [[ -n "$CALLER_WINDOW" ]]; then
      PANE_COUNT="$(tmux list-panes -t "$CALLER_WINDOW" 2>/dev/null | wc -l | tr -d ' ')"
      if [[ "$PANE_COUNT" == "1" ]]; then
        WHERE="pane"
      else
        WHERE="window"
      fi
    else
      WHERE="window"  # not in tmux or detection failed — safe default
    fi
  else
    WHERE="window"  # no $TMUX_PANE → caller isn't in a tmux pane
  fi
fi

if [[ ! -d "$CWD" ]]; then
  echo "cwd does not exist: $CWD" >&2
  exit 1
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "prompt file not found: $PROMPT_FILE" >&2
  exit 1
fi

# Resolve tmux session context (needed for pane + window placements; new session
# placements ignore this).
if [[ -z "$SESSION" ]]; then
  SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
fi

if [[ -z "$SESSION" && ("$WHERE" == "pane" || "$WHERE" == "window") ]]; then
  echo "no tmux session detected and --session not given — required for --where=$WHERE" >&2
  exit 2
fi

# Build the claude command. Worktree uses claude's native -w flag.
CLAUDE_CMD="claude"
if [[ "$WHERE" == "worktree" ]]; then
  # --worktree requires git repo; claude creates the worktree itself.
  if [[ -n "$WORKTREE_NAME" ]]; then
    CLAUDE_CMD="claude -w $WORKTREE_NAME"
  else
    CLAUDE_CMD="claude -w"
  fi
fi
if [[ -n "$MODEL" ]]; then
  CLAUDE_CMD="$CLAUDE_CMD --model $MODEL"
fi
if [[ -n "$PERMISSION_MODE" && "$PERMISSION_MODE" != "default" ]]; then
  CLAUDE_CMD="$CLAUDE_CMD --permission-mode $PERMISSION_MODE"
fi

# v2: child window/pane name with prefix (e.g., "↳ Skills Drop Investigation").
# Empty prefix (--no-prefix) keeps original NAME for callers who want strict naming.
CHILD_DISPLAY_NAME="${CHILD_PREFIX}${NAME}"

# Create the placement. TARGET is the tmux address of whichever pane holds claude.
TARGET=""
case "$WHERE" in
  pane)
    # Split current window horizontally; new pane takes focus by default.
    tmux split-window -h -t "$SESSION:" -c "$CWD" "zsh -lic '$CLAUDE_CMD'" >/dev/null 2>&1 || {
      echo "tmux split-window failed" >&2; exit 2;
    }
    TARGET="$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"
    # v2: label the pane with the child's name so the user can see what's running there.
    # tmux pane title shows in pane-border-status (if enabled) AND in `tmux list-panes -F '#T'`.
    tmux select-pane -t "$TARGET" -T "$CHILD_DISPLAY_NAME" 2>/dev/null || true
    # Try to enable pane-border-status for the parent window so the title is visible.
    # If the user already has a custom value, this doesn't disrupt — just ensures top is shown.
    PARENT_WIN="$(tmux display-message -t "$TARGET" -p '#{session_name}:#{window_index}' 2>/dev/null)"
    [[ -n "$PARENT_WIN" ]] && tmux set-option -t "$PARENT_WIN" -w pane-border-status top 2>/dev/null || true
    ;;
  window)
    if ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "tmux session not found: $SESSION" >&2; exit 2;
    fi
    tmux new-window -t "$SESSION:" -n "$CHILD_DISPLAY_NAME" -c "$CWD" "zsh -lic '$CLAUDE_CMD'" >/dev/null 2>&1 || {
      echo "tmux new-window failed" >&2; exit 2;
    }
    TARGET="$SESSION:$CHILD_DISPLAY_NAME"
    ;;
  session)
    # New detached tmux session — won't steal the user's attached session focus.
    # Session names can't contain unicode prefix safely, so use raw NAME for session, but apply prefix to the first window inside.
    if tmux has-session -t "$NAME" 2>/dev/null; then
      echo "tmux session already exists: $NAME" >&2; exit 2;
    fi
    tmux new-session -d -s "$NAME" -n "$CHILD_DISPLAY_NAME" -c "$CWD" "zsh -lic '$CLAUDE_CMD'" >/dev/null 2>&1 || {
      echo "tmux new-session failed" >&2; exit 2;
    }
    TARGET="$NAME:$CHILD_DISPLAY_NAME"
    SESSION="$NAME"
    ;;
  worktree)
    # Git worktree needs the parent cwd to be inside a git repo. Claude -w will
    # create the worktree at a sibling path. We run it inside a new tmux window
    # so the user can monitor + paste into it.
    if [[ -z "$SESSION" ]]; then
      SESSION="$(tmux display-message -p '#S' 2>/dev/null || true)"
    fi
    if [[ -z "$SESSION" ]] || ! tmux has-session -t "$SESSION" 2>/dev/null; then
      echo "tmux session required for worktree placement" >&2; exit 2;
    fi
    if ! (cd "$CWD" && git rev-parse --git-dir) >/dev/null 2>&1; then
      echo "cwd is not in a git repo: $CWD" >&2; exit 2;
    fi
    tmux new-window -t "$SESSION:" -n "$CHILD_DISPLAY_NAME" -c "$CWD" "zsh -lic '$CLAUDE_CMD'" >/dev/null 2>&1 || {
      echo "tmux new-window failed (worktree mode)" >&2; exit 2;
    }
    TARGET="$SESSION:$CHILD_DISPLAY_NAME"
    ;;
esac

# Write initial registry JSON with status=initializing. The child updates
# summary + status=active on its first turn. This makes the child visible
# to `/delegate list` immediately, even in the race window between spawn
# and the child's first action.
if [[ "$COOPERATE" == "true" ]]; then
  REGISTRY_DIR="${HOME}/.claude/cache/delegate"
  mkdir -p "$REGISTRY_DIR"
  # Slugify name for filename (keeps original in JSON.name).
  SLUG="$(echo "$NAME" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
  [[ -z "$SLUG" ]] && SLUG="unnamed-$$"
  REGISTRY_FILE="$REGISTRY_DIR/$SLUG.json"
  NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  jq -n \
    --arg name "$NAME" \
    --arg target "$TARGET" \
    --arg cwd "$CWD" \
    --arg summary "$SUMMARY" \
    --arg ts "$NOW" \
    '{name: $name, tmux_target: $target, cwd: $cwd, summary: $summary, spawned_at: $ts, last_updated: $ts, status: "initializing"}' \
    > "$REGISTRY_FILE" 2>/dev/null || {
      echo "failed to write registry entry: $REGISTRY_FILE" >&2
      # Non-fatal: spawn continues, child can still write its own JSON.
    }
fi

# Poll for Claude's REPL. First-run "Do you trust the files in this folder?"
# prompt may appear before the REPL — auto-dismiss with Enter (default = yes).
READY=0
TRUST_ACKED=0
for i in $(seq 1 60); do  # 60 × 0.5s = 30s max
  sleep 0.5
  CAPTURE="$(tmux capture-pane -t "$TARGET" -p 2>/dev/null || true)"

  if [[ "$TRUST_ACKED" -eq 0 ]] && echo "$CAPTURE" | grep -q "Do you trust the files in this folder"; then
    tmux send-keys -t "$TARGET" Enter
    TRUST_ACKED=1
    continue
  fi

  if echo "$CAPTURE" | grep -qE '(auto mode on|\? for shortcuts|bypass permissions)'; then
    READY=1
    break
  fi
done

if [[ "$READY" -eq 0 ]]; then
  echo "timeout waiting for claude REPL in $TARGET" >&2
  exit 3
fi

# Stability check: footer must persist across ~1s so we don't paste into a
# half-rendered frame.
sleep 1
CAPTURE2="$(tmux capture-pane -t "$TARGET" -p 2>/dev/null || true)"
if ! echo "$CAPTURE2" | grep -qE '(auto mode on|\? for shortcuts|bypass permissions)'; then
  echo "REPL footer disappeared between polls — aborting paste" >&2
  exit 3
fi

# Extra settle — Ink continues async rendering after footer appears.
sleep 2

# Load prompt and paste with bracketed-paste semantics.
BUFFER_NAME="delegate-$$"
tmux load-buffer -b "$BUFFER_NAME" "$PROMPT_FILE" 2>/dev/null || {
  echo "tmux load-buffer failed" >&2; exit 2;
}
# -p: bracketed paste — newlines treated as line breaks in the input box,
# not per-line submits.
tmux paste-buffer -p -b "$BUFFER_NAME" -t "$TARGET" 2>/dev/null
tmux delete-buffer -b "$BUFFER_NAME" 2>/dev/null || true

sleep 0.3
tmux send-keys -t "$TARGET" Enter

# v2: queue a /color slash-command for the child to apply (visual differentiation
# from parent and other claude sessions). Sent AFTER the prompt's Enter so it
# lands in the next-turn input buffer; claude processes it after the initial
# response. Skip if --no-color or empty $CHILD_COLOR.
if [[ -n "$CHILD_COLOR" ]]; then
  sleep 1
  tmux send-keys -t "$TARGET" "/color $CHILD_COLOR" Enter 2>/dev/null || true
fi

# Extract TTY + PID for the handle.
TTY="$(tmux display-message -t "$TARGET" -p '#{pane_tty}' 2>/dev/null || echo "")"
PID="$(tmux display-message -t "$TARGET" -p '#{pane_pid}' 2>/dev/null || echo "")"
WINDOW_NAME="$(tmux display-message -t "$TARGET" -p '#{window_name}' 2>/dev/null || echo "$NAME")"

REG_OUT="${REGISTRY_FILE:-}"
cat <<EOF
{"session":"$SESSION","window":"$WINDOW_NAME","cwd":"$CWD","tty":"$TTY","pid":$PID,"target":"$TARGET","where":"$WHERE","registry":"$REG_OUT"}
EOF
