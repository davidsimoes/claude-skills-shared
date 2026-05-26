---
name: restart-resume
description: Restore every tmux Claude session captured by /restart-process — recreates the original tmux layout (sessions, windows, panes with correct geometry via window_layout strings) and spawns FRESH claude processes (NOT --resume) with each pane's captured handoff as the first user message. Use when you say '/restart-resume', 'resume sessions after reboot', 'restore my tmux setup', 'bring back my claudes', 'I just rebooted - restore', or when a SessionStart hook surfaces a pending restart manifest banner. Reads the manifest at `$RESTART_HANDOFFS_DIR/latest/manifest.json` (default `~/.cache/claude-restart/latest/manifest.json`) — verifies checksum + schema before doing anything. Pairs with /restart-process — that skill captures, this restores.
user-invocable: true
---

# /restart-resume — Rebuild every session post-reboot

Reads the most recent restart manifest produced by `/restart-process`, recreates the tmux layout (sessions, windows, pane geometry), and spawns fresh `claude` processes per Claude pane with the captured handoff as the first user message.

**Why fresh, not `--resume`**: the whole point of `/restart-process` + `/restart-resume` is to take advantage of an updated `claude` binary, new MCP versions, fresh memory, no stale connections. `--resume` reuses old session state including the binary version. We deliberately discard that.

## Where the manifest lives

By default, `$HOME/.cache/claude-restart/latest/manifest.json` (a symlink to the most recent archive dir). Override the root via the `RESTART_HANDOFFS_DIR` env var if `/restart-process` was configured to write elsewhere.

## When to invoke

- A fresh terminal opens post-reboot and a SessionStart hook surfaces a pending manifest banner
- The user says `/restart-resume` or any of the trigger phrases in the description above
- Auto-invocation via the SessionStart-hook mechanism — wire your hook to emit `additionalContext` referencing this skill; the model will then invoke without asking

## Pre-flight

1. Verify a manifest exists at `${RESTART_HANDOFFS_DIR:-$HOME/.cache/claude-restart}/latest/manifest.json`. If missing, abort with: "no pending manifest — was /restart-process actually run?".

2. Print a summary BEFORE any destructive tmux mutation:
   ```python
   import json, os
   root = os.environ.get("RESTART_HANDOFFS_DIR") or os.path.expanduser("~/.cache/claude-restart")
   m = json.load(open(f"{root}/latest/manifest.json"))
   n_sessions = len({w["session"] for w in m["windows"]})
   n_claude   = sum(1 for w in m["windows"] for p in w["panes"] if p.get("is_claude"))
   n_panes    = sum(len(w["panes"]) for w in m["windows"])
   print(f'Manifest from {m["captured_at"]}: {n_claude} claude panes across '
         f'{n_sessions} sessions ({n_panes} total panes).')
   print(f'Orchestrator was at: {m["orchestrator_pane"]}')
   ```

3. Confirm intent to the user: "About to recreate <N> tmux sessions. Existing sessions with the same names will be reused (their first windows may be renamed to manifest names). Proceeding."

## Invocation

```bash
~/.claude/skills/restart-process/scripts/restore.sh \
    "${RESTART_HANDOFFS_DIR:-$HOME/.cache/claude-restart}/latest"
```

`restore.sh` is the shared engine (lives in the sibling `/restart-process` skill dir since that's where the rest of the family lives). It performs seven phases:

1. **R1.** Reads `manifest.json`; validates `schema_version: 1`; validates sha256 checksum against canonical re-serialization; verifies every referenced `handoff_path`, `launcher_path`, `pane_state_path` exists. Exits `2` on any mismatch. Symlink path arguments are resolved via `realpath` up-front (see Failure modes #7).

2. **R2.** For each session in the manifest: if it doesn't exist, `tmux new-session -d -s <name> -c <first_pane_cwd>`. If it does exist (e.g. a scheduled task or shell startup recreated it between `/restart-process` and `/restart-resume`), log and proceed. **Handoffs are not lost to silent collisions** — the own-pane case (the typical collision) is handled by displaced-spawn in R7. Other collisions are documented under "Known limitations".

3. **R3.** For each window: `tmux new-window -t <session>:<idx> -n <name> -c <cwd>` (skips windows that already exist after R2). The explicit `-t session:idx` is load-bearing — it preserves non-contiguous indices (e.g. `{1, 3, 6}`) the manifest captured.

4. **R4.** EXPLICIT ORDER per window:
   - (i) `tmux split-window` until pane count matches manifest
   - (ii) `tmux select-layout '<window_layout>'` to restore exact geometry
   - (iii) `sleep 0.3` then per pane: `send-keys`
     - Claude pane: send `cd <cwd> && claude "$(cat <abs-handoff-path>)"` + Enter — claude boots with the handoff as the first user message
     - Non-Claude pane: send the captured `argv` — NO Enter (user reviews before executing)

5. **R5.** Own-pane skip: whichever pane is running `/restart-resume` is the de facto orchestrator for this run and is skipped unconditionally (not just when `is_orchestrator == True` in the manifest). If the skipped pane has a Claude handoff in the manifest, the handoff is queued for displaced-spawn in R7 — it does NOT get orphaned on disk.

6. **R6.** Mark manifest consumed: write a `restored_at` marker file inside the archive dir + remove the `latest` symlink. This prevents a SessionStart banner from firing on subsequent sessions.

7. **R7.** Displaced-spawn queue: for each handoff queued in R5, find the next free window index in the same session and create a new window there named `<original-name> (resumed)`. Send `cd <cwd> && claude "$(cat <abs-handoff>)"` + Enter so Claude boots with the handoff as its first user message. This lets you invoke `/restart-resume` from a pre-existing session (e.g. a fresh post-reboot terminal that automatically opened a session matching one in the manifest) without losing the Claude that was supposed to land at the orchestrator's pane.

## Post-restoration

Tell the user:
- N panes restored (includes any displaced)
- M panes skipped (own-pane skips that had no Claude handoff to displace)
- D panes displaced (own-pane Claude handoffs spawned at `<session>:<next-free-idx>` instead of the manifest's original target — JSON lists `orig_target_pane`, `new_target_pane`, `window_name`)
- Any errors
- Manifest archived at `<ts>/` (no longer the `latest` symlink target)

## Failure modes

| # | Failure | Behavior |
|---|---|---|
| 1 | No `latest/` symlink | Abort; no destructive action |
| 2 | Checksum mismatch | Abort with stated vs computed hashes |
| 3 | Schema version mismatch | Abort — restore engine needs to be updated for new schema |
| 4 | Per-pane file missing | Abort — manifest references a file that's not on disk |
| 5 | `select-layout` fails | Non-fatal: tmux falls back to default tiling for that window |
| 6 | `send-keys` fails for one pane | Logged, continue with other panes |
| 7 | `restore.sh` invoked with a symlink path (the typical case) | Resolved via `realpath()` BEFORE composing any `send-keys` command — otherwise R6's symlink removal would race the slow-to-init pane shells, causing `cat <symlink>/handoff-*.md` to fail and Claude to boot with no context |
| 8 | Restore runs in a tmux pane the manifest claims existed (own-pane collision) | Skipped at the original target via R5; the Claude handoff is displaced-spawned at `<session>:<next-free-idx>` by R7 (zero info loss) |
| 9 | Non-own-pane collision in a pre-existing session (rare) | Existing windows are reused; send-keys lands in them. See "Known limitations" |

## Known limitations

- **Non-own-pane collisions in pre-existing sessions reuse the existing windows.** If a scheduled task or your shell startup created a session with the same name as one in the manifest AND that session also has windows at the same indices the manifest specifies (a rarer case than the own-pane variant, which R7 handles), restore will send-keys into those existing windows. Workaround: kill the conflicting session before invoking `/restart-resume`, or pass an alternate manifest dir directly.
- **Window renaming only applies to freshly-created sessions.** If the session already existed (per the limitation above), its windows are NOT renamed — to avoid clobbering user windows.
- **Layout strings include a tmux checksum prefix.** If you hand-edit a manifest, recompute the layout string via `tmux list-windows -F '#{window_layout}'` — otherwise `select-layout` fails (non-fatal, but the geometry won't match exactly).

## When NOT to use

- Mid-task — `restore` mutates tmux globally. Don't run if you have active work that conflicts with the manifest's expected sessions.
- If a different `/restart-process` was triggered after the manifest you're trying to restore — only `latest` is restored. Older manifests can be restored manually by passing their dir path directly.

## Files

This skill is intentionally thin — all the logic lives in the sibling `/restart-process` skill's `scripts/restore.sh`. Tests for `restore.sh` (including regression coverage for #7 above) live in `/restart-process/tests/restore.bats`.

- `SKILL.md` — this file (just the contract + invocation)
- Engine: `../restart-process/scripts/restore.sh`
- Tests: `../restart-process/tests/restore.bats`
