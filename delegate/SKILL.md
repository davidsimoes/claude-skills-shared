---
name: delegate
description: "Spawn and cooperate with a child Claude session for a specific task. Handles tmux placement (pane/window/session/worktree), task-prompt injection, registry tracking, and returns a clean handle for follow-up. Cooperation verbs: /delegate list|status|tell|fetch|close <name>. Use when you want to hand off a scoped task to a separate session, say 'delegate this to another Claude', 'spawn a coach/agent for X', 'start a session working on Y', 'open a side Claude to handle Z', or '/delegate ...'."
user-invocable: true
disable-model-invocation: false
---

# /delegate — Spawn + cooperate with child Claude sessions

Takes a task description, opens a new Claude session in tmux pre-loaded with that task, writes a JSON registry entry for cooperation verbs, and hands the parent back a clean handle (tmux location + registry name).

**Architecture:** cooperation uses tmux send-keys + a JSON registry at `~/.claude/cache/delegate/<slug>.json` — no MCP dependency. Works even when every MCP server is down.

Arguments: `{{ arguments }}`

---

## Step 1 — Parse arguments

Accepted forms:

- `/delegate <task description>` — spawn with defaults
- `/delegate @<path-to-prompt-file> [--name ...]` — use file content as the task
- `/delegate list [--prune]` — list active children (`--prune` removes dead targets)
- `/delegate status <name>` — show child's summary + last-seen + live tail
- `/delegate tell <name> <message>` — send message via tmux send-keys
- `/delegate fetch <name>` — retrieve last message received from child
- `/delegate close <name>` — ask child to wrap up + close window

Flags on spawn:

| Flag | Default | Effect |
|------|---------|--------|
| `--where pane\|window\|session\|worktree\|auto` | `auto` (resolves to `pane` if parent's window has 1 pane, else `window`) | tmux placement |
| `--cwd <path>` | inferred from task, else current | working directory of child |
| `--name <slug>` | auto-slug from task | tmux window name + registry filename (`~/.claude/cache/delegate/<slug>.json`; slug derived from `--name` by lowercasing + hyphenating) |
| `--model opus\|sonnet\|haiku` | inherit (no flag) | model override |
| `--cooperate` / `--fire-and-forget` | `--cooperate` (true) | whether child should register + message back |
| `--summary "<line>"` | auto | registry summary line (shown in /delegate status) |
| `--from-file <path>` | — | load task body from a file (alternative to inline) |
| `--no-prefix` | (off — default uses `↳ ` prefix on window/pane name) | suppress visual child marker |
| `--color <name>` | `yellow` | runs `/color <name>` in the child session for visual differentiation; pass `--no-color` to skip |
| `--no-color` | (off) | suppress the auto-`/color` step |
| `--permission-mode <mode>` | `auto` | sets `--permission-mode` on the child claude process; `auto` prevents prompt stalls in unwatched windows |
| `--no-auto` | (off) | revert to claude's default permission mode (removes `--permission-mode auto`) |

If the user invoked with just a verb (no task body), ask what they want delegated.

---

## Step 2 — Resolve placement

All five placements are implemented. **Default: `auto`** — resolves to `pane` if the calling pane's window has exactly 1 pane (clean split), else `window` (avoid clutter). This makes most short-lived /delegate calls land as a sibling pane in the parent's window — child output is visible at-a-glance without window switching. Heavy or multi-pane parents fall back to a new window automatically.

Manual override decision tree:

- **Debugging / parallel review / side-by-side comparison** → explicit `--where pane`
- **Substantive multi-step work in a clean parent window** → `auto` lands here as `pane`
- **Substantive multi-step work in an already-busy parent** → `auto` lands here as `window`
- **Fully isolated context, different repo or life area** → `--where session`
- **Risky / sandboxed code changes** → `--where worktree`

When auto-resolving, tell the user what was picked + why in ONE line before spawning. ("Spawning as pane in current window since it's not split — say if you want a separate window.")

Placement-specific semantics (handled by `spawn.sh`):

- `pane`: `tmux split-window -h -t <current-session>: -c <cwd>` — target session is current tmux session only. v2 also calls `tmux select-pane -T '↳ <name>'` to label the pane and enables `pane-border-status top` so the title shows in the border.
- `window`: `tmux new-window -t <current-session>: -n '↳ <name>' -c <cwd>` — the `↳ ` prefix marks this as a child relative to its spawner.
- `session`: `tmux new-session -d -s <name> -n '↳ <name>' -c <cwd>` — detached; won't steal focus. Session name itself stays clean (raw `<name>`); only the first window inside gets the prefix. Errors if session name already exists.
- `worktree`: same as `window` (with prefix), but claude is invoked with `claude -w <worktree-name>`. claude creates the git worktree itself. Errors if cwd isn't inside a git repo.

Window/session naming:
- `--name` wins for the base name. The `↳ ` prefix is applied automatically to the tmux display name (window or pane title); the registry JSON keeps the un-prefixed name. Use `--no-prefix` to suppress the visual marker.
- Auto-slug from task: first 4–6 significant words, Title Case, joined with spaces, capped at ~30 chars.
- For `--where session`, the `<name>` is also the tmux session name, so avoid names that collide with existing sessions (`tmux has-session -t <name>` pre-check recommended).

---

## Step 3 — Resolve cwd

1. If `--cwd` provided, validate it exists (`test -d`).
2. Else look for path hints in the task description (absolute paths, `~/...` paths, or project-name keywords matching your dev-root layout — e.g. `~/dev/<project>/`).
3. Else use the parent's current cwd.
4. Confirm with the user if inferred from hint — "cwd: `<path>` — ok?"

---

## Step 4 — Build startup prompt

Load `templates/startup-prompt.md` and fill placeholders:

- `{{TASK_BODY}}` — the task description (or file contents if `--from-file` / `@path` used)
- `{{NAME}}` — the child's name (same as tmux window name / registry filename)
- `{{PARENT_TARGET}}` — the parent's tmux `session:window` name (from `tmux display-message -p '#S:#W'`)
- `{{CHILD_TMUX_TARGET}}` — where the child will end up (resolved after spawn; see Step 5 helper output)
- `{{CWD}}` — resolved working directory
- `{{SUMMARY}}` — `--summary` value or auto-generated from task (one line, ≤80 chars)
- `{{COOPERATE}}` — `true` or `false`
- `{{SPAWNED_AT}}` — ISO timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)
- `{{COOPERATE_INSTRUCTIONS}}` — the appropriate section of `references/cooperate-instructions.md` (don't include both; pick one)

Write the filled prompt to a unique temp file: `/tmp/delegate-<slug>-<unix-ts>.md`.

Precompute `{{CHILD_TMUX_TARGET}}` from the parent's tmux session + the resolved placement: `<session>:↳ <name>` for window/worktree/session placements, or `<session>:<window_idx>.<pane_idx>` for pane (pane index is unknown pre-spawn — for pane placement, leave as the literal `<pending>` and the child can fetch its own target via `tmux display-message -t "$TMUX_PANE" -p '#S:#I.#P'` if needed).

---

## Step 5 — Launch

Call the spawn helper:

```bash
~/.claude/skills/delegate/scripts/spawn.sh \
  --name "<name>" \
  --cwd "<resolved-cwd>" \
  --prompt-file "<tmp-prompt-path>" \
  --where "<pane|window|session|worktree>" \
  [--session "<tmux-session>"] \
  [--model "<model>"] \
  [--cooperate "true|false"] \
  [--worktree-name "<git-worktree-name>"]
```

On success it emits one JSON line:
```json
{"session":"main","window":"My Child Task","cwd":"/...","tty":"/dev/ttysNNN","pid":12345,"target":"main:My Child Task","where":"window"}
```

The spawn script auto-dismisses the startup interstitial:
1. **Trust-folder prompt** — first-run "Do you trust the files in this folder?" is auto-answered with Enter (default yes).

(The dev-channels warning no longer fires since `claude()` dropped those flags on 2026-04-24.)

Exit codes:
- 0 → success, parse JSON and build handle
- 1 → argument error (fix and retry, don't re-spawn)
- 2 → tmux error (surface to user, don't retry automatically)
- 3 → timeout waiting for claude REPL (window/pane/session exists but REPL never rendered — surface and let user inspect)

---

## Step 6 — Return handle to parent

After successful launch, the spawn helper has already written the initial registry JSON at `~/.claude/cache/delegate/<slug>.json` (status=`initializing`, placeholder summary). The child updates `summary` + `status=active` on its first turn — no need to poll for it from the parent.

Use the `registry` field from the spawn helper's JSON output as the path. The slug is the lowercased, hyphen-joined version of `<name>` (e.g., `"Deep Delegate"` → `deep-delegate.json`).

Print the handle in this shape:

```
✓ Delegated "<name>" to tmux <session>:<window>
  cwd: <path>
  pid: <N>  tty: <tty>
  registry: ~/.claude/cache/delegate/<slug>.json

  Follow up:
  - /delegate tell "<name>" <message>      # send a message via tmux send-keys
  - /delegate status "<name>"              # read registry + live tail
  - /delegate fetch "<name>"               # capture-pane the latest child output
  - /delegate close "<name>"               # ask child to wrap up
  - tmux select-window -t "<target>"       # jump to it visually
```

If cooperate=false, omit the follow-up block and add: "Fire-and-forget — no registry, no tracking. Check the tmux window manually."

---

## Step 7 — Cooperation verbs

Supported forms: `/delegate list [--prune]`, `/delegate status <name>`, `/delegate tell <name> <message>`, `/delegate fetch <name>`, `/delegate close <name>`.

All verbs delegate name resolution and registry I/O to **`scripts/registry.sh`**. Use it from your Bash tool — don't reimplement the logic inline.

```bash
# Show all children (human table)
~/.claude/skills/delegate/scripts/registry.sh list

# Show as JSON (for parsing)
~/.claude/skills/delegate/scripts/registry.sh list --json

# Fuzzy-resolve a name to a tmux target (exit 0 = single match; 1 = zero or ambiguous)
~/.claude/skills/delegate/scripts/registry.sh resolve "<name>"

# Resolve with full JSON entry
~/.claude/skills/delegate/scripts/registry.sh resolve "<name>" --json

# Status card for one child (registry data + live tail)
~/.claude/skills/delegate/scripts/registry.sh status "<name>"

# Remove stale entries (dead tmux targets + unparseable JSON)
~/.claude/skills/delegate/scripts/registry.sh prune [--dry-run]
```

Verb implementations (all `<name>` arguments get resolved first via `registry.sh resolve`):

- **`/delegate list`** → `registry.sh list` (add `--json` for parseable output).
- **`/delegate list --prune`** → `registry.sh prune` (the prune subcommand is separate from `list`; the parent-side verb maps to it).
- **`/delegate status <name>`** → `registry.sh status <name>`.
- **`/delegate tell <name> <message>`** → resolve target, then `tmux send-keys -t <target> "<message>" Enter; sleep 1; tmux send-keys -t <target> Enter`. Echo the send to the user; don't wait for reply.
- **`/delegate fetch <name>`** → resolve target, then `tmux capture-pane -t <target> -p -S -300 | tail -80`. Show the latest assistant response.
- **`/delegate close <name>`** → resolve target, clear stray input with `C-u`, send `/close`, monitor up to 60s. `/close` saves the child's work but does NOT terminate the Claude process — then send `/exit` for a graceful shutdown. The window auto-closes when the process exits; `tmux kill-window` is a fallback only if it lingers (ask the user first). Finally `rm <slug>.json`.

Full spec (edge cases, exact output formats): `references/cooperation-verbs.md`.

Key rules:

- **Never block waiting for a reply.** `/delegate tell` fires and returns immediately. Use `/delegate fetch` to read the child's latest output.
- **Never force-kill a live Claude process.** `/delegate close` runs `/close` (saves work) then `/exit` (graceful termination) so the window auto-closes cleanly; `tmux kill-window` is a fallback for a lingering shell only, and asks the user first.
- **The parent's own window is auto-excluded** from resolve matches. `registry.sh` reads `$TMUX_PANE` to identify the calling pane. (NOT bare `tmux display-message` — that returns the focused pane, not the calling pane.)
- **Stale registry entries are ignored by resolve** and flagged as `☠ stale` in list. Run `/delegate list --prune` to clean them up.

---

## Design constraints

- **Never auto-spawn without user intent.** `/delegate` is invoked explicitly. Don't auto-trigger from other skills without "y/n ok to delegate?" first.
- **Never respawn on child crash.** If the spawn script returns code 3, surface it. Let the user inspect.
- **No MCP dependency for cooperation.** Verbs use tmux + the registry. They work even if every MCP server is down.
- **No cross-machine.** tmux is local. Fail fast if user passes a hint suggesting remote.
- **Match model to task weight.** If the task description implies judgment-heavy work (security, irreversible deploy, architectural decision) and no `--model` was passed, suggest `--model opus` before spawning. For pure mechanical work, suggest `--model haiku`.

---

## References

- **New to tmux? Start here:** `tmux-primer.md` — session/window/pane in plain English, with the placement table.
- Startup prompt template: `templates/startup-prompt.md`
- Cooperation instructions appended to child: `references/cooperate-instructions.md`
- Cooperation verbs full spec: `references/cooperation-verbs.md`
- Spawn helper: `scripts/spawn.sh`
- Registry helper (list / resolve / prune / status): `scripts/registry.sh`

## Related skills

- `/close` — referenced by the close verb. Not bundled here; the child can still be terminated via `tmux kill-window` if you don't have a similar wrap-up skill.
- `/loop` — a different pattern (recurring self-ping on the *current* session), not parallel work.
