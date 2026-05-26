---
name: restart-process
description: Capture every in-flight tmux Claude session into an atomic on-disk manifest BEFORE a reboot or system update, so /restart-resume can spawn fresh Claude processes post-reboot with full handoff context as the first user message. Use when you say 'restart my computer', 'reboot and update', 'wrap everything for reboot', 'preserve sessions across reboot', 'capture all sessions for restart', 'safely close all my sessions', 'update macOS and claude', '/restart-process', 'I need to restart but have many open sessions', or any request to safely terminate every live tmux Claude session before a system update without losing in-flight conversation context. Pairs with /restart-resume — this skill captures + commits + kills, the other restores.
user-invocable: true
---

# /restart-process — Capture every tmux Claude session for a reboot

Captures every in-flight tmux Claude session into an atomic on-disk manifest, pre-commits dirty repos centrally (so each pane's Claude doesn't need to do anything during shutdown), optionally updates `claude` + `brew`, then kills all old Claude PIDs except its own. After this skill exits, your terminal stays alive — you reboot manually. Post-reboot, the SessionStart hook + `/restart-resume` rebuild every session with handoff context as Claude's first user message.

**Why this exists**: if you run multiple concurrent tmux Claude sessions, OS or `claude` binary updates require reboots that kill them all. Resuming with `claude --resume <uuid>` reuses the old binary; that defeats the point of updating. /restart-process gives a clean shutdown + post-update fresh-process resumption story instead.

## Prerequisites

- Running inside a tmux session (the orchestrator is one of your normal Claude sessions)
- macOS tested; Linux paths exist in the scripts but are less battle-tested
- `claude` on PATH; `tmux` ≥ 3.0; `python3` ≥ 3.10

## Where things go

By default, manifests and per-run logs live under `~/.cache/claude-restart/`. Override via the `RESTART_HANDOFFS_DIR` env var if you want a different location.

```
$RESTART_HANDOFFS_DIR/
  ├─ 2026-05-25T215744Z/           # one archive dir per /restart-process run
  │   ├─ manifest.json             # atomic, checksummed
  │   ├─ inventory.json
  │   ├─ handoff-<sess>-<w>-<p>.md # one per Claude pane captured
  │   ├─ launch-<sess>-<w>-<p>.sh  # respawn script (legacy; restore.sh now spawns directly)
  │   └─ self-handoff-source.md    # this Claude's handoff (written inline pre-kill)
  ├─ latest -> 2026-05-25T215744Z  # symlink; /restart-resume reads this
  └─ logs/
      └─ run-2026-05-25T215744Z.log
```

## What to do when invoked

### 1. Write the orchestrator's self-handoff

THIS Claude session is the orchestrator. Its JSONL is mid-write, so reading it for handoff extraction would be lossy. Instead: synthesize the self-handoff inline from the current conversation context. Write a markdown file at `$RESTART_HANDOFFS_DIR/<ts>/self-handoff-source.md` (the orchestrator script picks it up from a marker path during Phase B).

Schema (matches `extract-handoff.sh` output for non-self panes):

```
# Session handoff: <one-sentence summary of what THIS session was doing>

## Last action
<...>

## Next step
<...>

## Files touched
- <...>

## Blockers / open questions
- <...>

## Uncommitted intent
<...>

## Was busy at capture
false

## Transcript (full)
<path to this session's JSONL or "current conversation, in-flight">
```

### 2. Invoke orchestrate.sh

```bash
~/.claude/skills/restart-process/scripts/orchestrate.sh
```

Flags:
- `--dry-run` — runs Phases PRE/A/A0/B/C/D, stops before updates + kill
- `--skip-updates` — skip `claude --upgrade` + `brew upgrade`
- `--skip-precommit` — skip Phase C (only safe if no repos are dirty)

The script logs every phase to `$RESTART_HANDOFFS_DIR/logs/run-<ts>.log` and aborts on any failure BEFORE the kill phase (no work destroyed if any pre-kill step fails).

### 3. Surface output to the user

`orchestrate.sh` prints the final handoff message at the end. Confirm the exit code is 0 and relay the message. If exit was non-zero:

- `2` — capture phase failed; no work destroyed; manifest may be partial; show log path
- `3` — updates/kill failure; manifest still valid; partial state; show log

### 4. What NOT to do

- Do NOT `/quit` or `/exit` this orchestrator session at the end — the terminal must stay alive until the user types `reboot`
- Do NOT kill the orchestrator's own Claude PID (`orchestrate.sh` excludes self automatically)
- Do NOT pre-emptively close other tmux panes' Claude processes — `orchestrate.sh` handles that via SIGTERM + 10s grace + SIGKILL after every manifest write has fsync'd

## Architecture

```
orchestrate.sh
  ├─ PRE: lock, self-locate, prune old archives (>30d)
  ├─ A:   snapshot.sh --phase=1 → inventory.json
  ├─ A0:  pgrep claude − tmux set → warn about strays
  ├─ B:   extract-handoff.sh per claude pane (parallel batches of 4)
  │       + self handoff (inline from this Claude's context)
  ├─ C:   precommit.sh --auto (serialized git add+commit+push per dirty repo)
  ├─ D:   write-launchers.sh → launch-*.sh per claude pane
  │       write-manifest.py → atomic manifest.json with sha256
  ├─ E:   claude --upgrade, brew upgrade (skippable)
  ├─ F:   SIGTERM 10s grace → SIGKILL stragglers (all claude PIDs except self)
  └─ FINAL: print handoff message
```

## Files

- `SKILL.md` — this file
- `scripts/orchestrate.sh` — top-level driver
- `scripts/snapshot.sh` — Phase 0/1 inventory: lock, self-locate, tmux walk, claude PID detection
- `scripts/lookup-session.sh` — claude_pid → sessionId, cwd, version, source_config_dir
- `scripts/escape-cwd.py` — canonical CWD encoding for `projects/<escaped>/<uuid>.jsonl`
- `scripts/extract-env.py` — cross-platform process env extraction
- `scripts/extract-handoff.sh` — JSONL → handoff.md via `claude -p` (model is configurable)
- `scripts/precommit.sh` — serialized git commit+push per dirty repo
- `scripts/write-launchers.sh` — per-pane `launch-*.sh` wrappers
- `scripts/write-manifest.py` — atomic manifest writer (sha256 + schema versioning)
- `scripts/restore.sh` — restore engine (used by `/restart-resume`)
- `scripts/prune.sh` — 30-day cleanup of old archive dirs
- `tests/` — bats tests covering atomic-write, checksum, schema, layout-roundtrip, restore semantics

## Failure modes

| Failure | Behavior |
|---|---|
| Lock conflict | Aborts: "another /restart-process is running" |
| `snapshot.sh` fails | Aborts; no manifest written |
| Handoff extraction times out (>180s per pane) | That pane's handoff is an "extraction failed" placeholder; manifest still valid |
| Pre-commit fails on a repo | That repo recorded as `action: failed`; orchestrate.sh continues with other repos |
| `write-manifest.py` fails post-handoff | Aborts BEFORE kill phase; no work destroyed |
| `claude --upgrade` fails | Logged warning, continues to kill phase |
| `brew upgrade` fails | Logged warning, continues |
| SIGTERM straggler | SIGKILL after 10s grace |
| Non-tmux claude detected | Warned but not touched (user closes manually) |

## When NOT to use

- Single-session quick reboots — just `/close` and reboot manually
- Mid-tender or mid-critical work where uncommitted changes need careful review — `orchestrate.sh` commits everything under a generic `WIP: pre-restart` message; review first if that's not what you want
- If you're already inside a session that you don't want destroyed and the orchestrator can't be that session (the orchestrator self-locates and excludes itself, but only if it's a tmux pane; non-tmux orchestration is unsupported)
