# tmux primer for /delegate users

If you've never used [tmux](https://github.com/tmux/tmux/wiki) before, this is the minimum mental model you need to read the rest of the `delegate` skill without getting lost.

## What tmux is

A terminal multiplexer. One terminal window can host many isolated shells that survive even if you disconnect from the machine. Think of it as your terminal's window manager.

## Three (sometimes four) levels of nesting

```
session  ─┬─ window  ─┬─ pane
          │           └─ pane
          └─ window  ─── pane
```

- **session** — the outermost container. One per project / workstream is typical. Detach from a session and everything inside keeps running; reattach later from anywhere.
- **window** — like a tab inside a session. You see one window at a time.
- **pane** — a split inside a window (left/right or top/bottom). Multiple panes are visible at once; you switch between them with keybindings.
- **worktree** — not a tmux concept; it's a git feature. `delegate --where worktree` creates a window in a fresh git worktree (a sibling checkout of the same repo on a different branch), so the child works in isolation without disturbing the parent's working tree.

## How `delegate` uses them

When you `/delegate <task>`, the spawn helper picks one of those four placements:

| `--where`  | Where the child lands | When to use |
|---|---|---|
| `pane`    | new pane in your current window (horizontal split) | quick parallel debug, side-by-side comparison |
| `window`  | new window in your current session | substantive work, more than one pane of context |
| `session` | new detached session you don't see by default | fully isolated context, different repo or life area |
| `worktree`| new window + new git worktree | risky/experimental changes you want sandboxed from main |
| `auto`    | resolves to `pane` if your window has 1 pane today, else `window` | the default |

You move between tmux containers with keybindings (the exact bindings depend on your `.tmux.conf`). On a stock tmux config, the prefix is `Ctrl-b`; common follow-ups are `s` (session picker), `w` (window picker), `o` (next pane).

## Setup

- macOS: `brew install tmux`
- Linux: install via your package manager (`apt`, `dnf`, `pacman`, etc.)
- Run `tmux` to start your first session. Inside it, `delegate` will detect your current session and place children relative to it.

## Learn more

- [Official tmux wiki](https://github.com/tmux/tmux/wiki) — canonical reference.
- [tmux cheatsheet](https://tmuxcheatsheet.com/) — quick lookup for default keybindings.
- [Hamvocke's tmux tutorial](https://hamvocke.com/blog/a-quick-and-easy-guide-to-tmux/) — gentle introduction.

If you want a more ergonomic setup than tmux's defaults (e.g., a session/window/pane picker bound to memorable prefixes), look at [tmux-resurrect](https://github.com/tmux-plugins/tmux-resurrect) and [tmux-continuum](https://github.com/tmux-plugins/tmux-continuum) for session persistence across reboots.
