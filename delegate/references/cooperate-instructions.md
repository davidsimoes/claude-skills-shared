# Cooperation instructions appended to the child's startup prompt

## If cooperate=true

A registry JSON file has already been written for you by spawn.sh at `~/.claude/cache/delegate/<slug>.json` (the slug is the lowercased, hyphen-joined version of your name from `[delegate:meta]`). It currently contains `status: "initializing"` and a placeholder summary.

**On your first turn**, open that file and update it with:
- `summary`: one short line (≤80 chars) describing what you're actually going to do
- `last_updated`: current ISO timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)
- `status`: `"active"`

As your focus changes (new phase, blocker, completed step), update `summary` + `last_updated` again. Keep summaries terse — they show up in `/delegate status` and should read at a glance.

When you finish or hit a blocker that needs the parent, set `status` to `"done"` or `"blocked"` and make the summary the final one-line outcome.

You don't need to poll for parent messages — the parent sends input directly to your tmux pane via `tmux send-keys`, so new instructions appear as regular conversation turns.

If you need to notify the parent proactively, just write the question in your normal chat output. The parent runs `/delegate fetch <name>` to capture-pane your output.

When the parent sends `/close` to your pane, run the `/close` skill to commit, push, and wrap up — then stop and idle. The parent drives teardown from there: it sends `/exit` to terminate your process (the window auto-closes on exit) and removes the registry JSON. Do NOT run `/exit` yourself and do NOT delete the registry JSON — `/close` only saves your work; the parent handles process exit and cleanup.

## If cooperate=false

No registry file exists for you. Execute and exit. Fire-and-forget only.
