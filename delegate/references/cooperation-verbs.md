# /delegate cooperation verbs (tmux-based)

The parent calls these verbs after a child is running. All of them share a common **fuzzy name resolution** step so the user can write `/delegate tell coach "thing"` instead of remembering the exact tmux window name.

These verbs use **tmux + a JSON registry** — no MCP dependency. State is observable via `capture-pane`, messages land directly at the child's prompt, no polling needed.

**Helper script**: `scripts/registry.sh` implements the deterministic parts of resolution and registry I/O — use it instead of ad-hoc JSON parsing. Subcommands: `list [--json]`, `resolve <name> [--json]`, `prune [--dry-run]`, `status <name>`. The mutating verbs (`tell`, `fetch`, `close`) are Claude-driven tmux calls — described below.

## Registry

The spawn helper writes a placeholder entry at spawn time; the child updates `summary` + `status` on its first turn. Path: `~/.claude/cache/delegate/<slug>.json` (slug = lowercased, hyphen-joined name):

```json
{
  "name": "deck-revisions",
  "tmux_target": "main:1.3",
  "cwd": "~/dev/example-project",
  "summary": "Revising slides 4–7 of the client deck",
  "spawned_at": "2026-04-24T09:32:00Z",
  "last_updated": "2026-04-24T09:45:12Z",
  "status": "active"
}
```

The child is responsible for writing this file on startup (via the startup prompt) and optionally updating `summary` + `last_updated` when its focus changes.

## Shared: resolve `<name>` to tmux target

1. List all JSON files in `~/.claude/cache/delegate/*.json` and parse each.
2. Run `tmux list-panes -a -F '#{session_name}:#{window_index}:#{window_name}\t#{pane_tty}'` to get the live tmux map.
3. Filter out stale registry entries (tmux_target no longer exists in the live map — suggests the child exited without cleanup).
4. Filter out the caller's own window (compare `tmux display-message -p '#S:#I:#W'` to the registry `tmux_target`).
5. Fuzzy match `<name>` (case-insensitive, partial) against: `name`, last segment of `cwd`, `summary`, and `tmux_target`. Allow multi-word where each word is an independent substring check.
6. If **zero matches**: fail with `No delegated session matching "<name>". Active children: [list names]`.
7. If **≥2 matches**: show all and ask user to disambiguate.
8. If **exactly one match**: proceed with that child's `tmux_target` and registry data.

## `/delegate status <name>`

Resolve. Then:

1. Read the registry JSON for metadata.
2. Run `tmux capture-pane -t <tmux_target> -p | tail -10` for live activity tail.
3. Output:

```
<tmux_target>
  name:        <registry.name>
  cwd:         <registry.cwd>
  summary:     <registry.summary or "(none set)">
  spawned:     <relative, e.g. "12m ago">
  last_update: <relative>
  status:      <registry.status>

  Live tail:
  <last 10 lines from tmux capture-pane>
```

If `last_updated` is >10 min old AND the tmux target is still alive: add `⚠ child hasn't refreshed status in a while (may be busy or idle)`.

If the tmux target is gone entirely: `⚠ tmux target no longer exists — child likely exited. Registry entry is stale; run /delegate list --prune to clean it up`.

## `/delegate tell <name> <message>`

Resolve. Then:

1. Echo: `→ <tmux_target>: <message>`
2. Send via tmux:
   ```bash
   tmux send-keys -t <tmux_target> "<message>" Enter
   sleep 1
   tmux send-keys -t <tmux_target> Enter
   ```
   (The double-Enter is because Claude Code's prompt sometimes requires a second Enter to submit when the buffer has trailing whitespace.)
3. Report: `Sent. Use '/delegate fetch <name>' after the child has had time to respond.`

Note: this places the message directly at the child's prompt, so the child sees it as regular conversation input — no polling needed on its side.

## `/delegate fetch <name>`

Resolve. Then:

1. Run `tmux capture-pane -t <tmux_target> -p -S -300` to get the last ~300 lines of the child's pane.
2. From that output, extract the most recent assistant response block — identifiable by the `⏺` glyph marking Claude's output, or by the content after the user's last prompt.
3. Show the extracted block with a small header:
   ```
   Last activity from <tmux_target> (captured at <now>):
   <extracted block>
   ```
4. If the child is still visibly working (spinner words like "Thinking", "Swooping", "Crunched" in the tail): `⧖ child is still processing — try again shortly.`

If you need a specific earlier message, use `tmux capture-pane -t <target> -p -S -2000` for deeper history.

## `/delegate close <name>`

Resolve. Then:

1. Clear any stray text in the child's input box, then send `/close`:
   ```bash
   tmux send-keys -t <tmux_target> C-u
   sleep 0.4
   tmux send-keys -t <tmux_target> "/close" Enter
   sleep 1
   tmux send-keys -t <tmux_target> Enter
   ```
   The `C-u` matters — unsubmitted text left in the child's prompt would otherwise be prepended to `/close`, submitting a garbled command.
2. Monitor the pane for up to 60s waiting for `/close` to finish (look for `Session closed` or the prompt returning after a commit+push sequence).
3. `/close` saves the child's work (commit + push + wrap-up) but does NOT terminate the Claude process — the REPL sits idle afterward. Send `/exit` for a graceful process shutdown. Guard against the rare case where the child exited during `/close` (a dead target makes `send-keys` error noisily):
   ```bash
   if tmux list-windows -t <session> -F '#{window_name}' 2>/dev/null | grep -qF '<window_name>'; then
     # Window still alive — send /exit (clear stray input first, same as step 1)
     tmux send-keys -t <tmux_target> C-u
     sleep 0.4
     tmux send-keys -t <tmux_target> "/exit" Enter
     sleep 1
     tmux send-keys -t <tmux_target> Enter
   fi
   # Window already gone → skip /exit; step 4 will resolve GONE and proceed to registry cleanup.
   ```
4. When the Claude process exits, tmux closes the window automatically (no `remain-on-exit`). Check whether the window is gone:
   ```bash
   tmux list-windows -t <session> -F '#{window_name}' | grep -qF '<window_name>' && echo LINGERS || echo GONE
   ```
   - **GONE** (normal case): the window auto-closed. Nothing to kill — skip to step 6.
   - **LINGERS** (rare — e.g. the pane dropped to a bare shell): present `Window didn't auto-close — kill it now? [y/N]`, and on `y` run `tmux kill-window -t <tmux_target>`.
5. Present a one-line summary: `Child ran /close + /exit, window <auto-closed | killed>.`
6. Remove the registry entry (the child's handoff expects the parent to do this):
   ```bash
   rm -f ~/.claude/cache/delegate/<slug>.json
   ```

**Never `tmux kill-window` a window still running an active Claude process.** Always `/close` (saves work) then `/exit` (graceful termination) first; `kill-window` is a fallback for a lingering shell only. An abrupt kill of a live Claude process risks losing in-flight disk writes (commits, logs, memory).

## `/delegate list`

Prints a table of all children from the registry, flagged by liveness. Maps to `registry.sh list`. Add `--prune` (parent-side) to translate to `registry.sh prune` for cleanup of dead targets.

```
NAME              TMUX TARGET   CWD                       SUMMARY                       AGE    STATE
deck-revisions    main:1.3      example-project           Revising slides 4–7           12m    live
old-analysis      main:2.0      (dead target)             ...                           2d     ☠ stale
```

## Edge cases

- **Registry entry but tmux target dead**: mark as stale in `/delegate list`, reject other verbs with the stale message.
- **Tmux target exists but no registry entry**: probably a manually-started session. Not resolvable by `/delegate` verbs — inspect via `tmux list-windows` directly.
- **Two registry entries with same tmux_target**: take the most recent `last_updated`, warn about the duplicate.
- **tmux send-keys fails** (target vanished between list and send): report `tmux target disappeared — child exited. Cleaning up registry.` and remove the JSON file.
