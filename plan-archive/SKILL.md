---
name: plan-archive
description: "Archive the current planning session or a specific plan to a dated archive directory. Preserves thinking evolution so AI can go back and evaluate how architecture decisions evolved. Use when: 'archive this plan', 'save this planning session', 'log this architecture decision', 'preserve this approach', 'store this plan for retrospective'. Complements ExitPlanMode — use immediately after exiting plan mode to capture what was decided."
user-invocable: true
disable-model-invocation: false
---

# /plan-archive — Dated Plans Archive

Save any plan, architecture decision, or strategic thinking session to a central dated archive with a timestamp. Enables retrospective review of how thinking evolved over time — you can look at "what I planned in April" vs "what I planned in October" and see whether the bets paid off.

## Location

**Default location: `~/.claude-plans/`** (override with the `CLAUDE_PLANS_DIR` env var).

Rationale vs per-project `.claude/plans/`:
- **Central search** — one place to grep / qmd / index. Per-project plans scatter and become invisible to retrospective workflows.
- **Lifetime** — plans survive project archival, repo deletion, or restructuring. The archive is permanent even when individual repos come and go.
- **Retrospectives** — comparing plans across months requires them all in one place.
- **Consistency** — adjacent log folders (daily notes, decisions, weekly retros) usually live in the same root; plans fit the same pattern.

Per-project `.claude/plans/` is the right choice ONLY when the plan is so code-specific that it's meaningless without the repo context. That's rare — even those are usually worth preserving centrally.

## Inputs

- No argument — synthesize and archive the current planning session from conversation context
- `topic:<slug>` — override the auto-generated topic name (e.g., `topic:auth-flow-refactor`)
- `file:<path>` — archive an existing plan document rather than synthesizing from context

## Process

### Step 1 — Determine Topic and Date

Generate a topic slug from the current conversation:
- Identify the main decision or architecture question being planned
- Convert to lowercase-hyphen slug: e.g., "Auth flow refactor" → `auth-flow-refactor`
- If `topic:<slug>` was provided, use that instead
- Date: today's ISO date (`YYYY-MM-DD`)
- Resolve archive root: `${CLAUDE_PLANS_DIR:-$HOME/.claude-plans}`
- Final filename: `<archive-root>/YYYY-MM-DD-{slug}.md`

Confirm with: "Archiving plan to `<archive-root>/YYYY-MM-DD-{slug}.md` — proceed?"

### Step 2 — Synthesize Plan Content

If synthesizing from conversation context:
- Extract the key decision that was made
- Extract the approach that was chosen
- Extract alternatives that were considered and rejected (with reasons)
- Extract open questions that remain
- Extract any constraints or assumptions that shaped the decision

If archiving from file: read the file as-is, append standard frontmatter.

### Step 3 — Write Archive File

Format:
```markdown
# Plan: {Human-readable topic} — {YYYY-MM-DD}

**Status**: drafted
**Session context**: {1-line description of what problem this was solving}

## Context

{What problem triggered this plan. Key constraints. What was already tried or considered.}

## Decision / Approach

{The actual plan — what was decided and why. Be specific enough that someone reading this later (or a future AI session) can understand without the original conversation.}

## Alternatives Considered

| Alternative | Why Rejected |
|-------------|-------------|
| {option A} | {reason} |
| {option B} | {reason} |

## Open Questions at Time of Archival

- [ ] {question 1}
- [ ] {question 2}

## Retrospective

> *(Fill in when revisiting — was this the right call? What changed? What would you do differently?)*
> *(Status: drafted | revised | implemented | abandoned | superseded-by: YYYY-MM-DD-{other-plan})*
```

### Step 4 — Commit (if archive root is a git repo)

If `<archive-root>` is inside a git repo, commit the new file:
```bash
cd <archive-root> && git add . && git commit -m "Archive plan: {slug}"
```

If not a git repo, just confirm the file was written: "Plan archived to `<archive-root>/YYYY-MM-DD-{slug}.md`."

## Auto-Capture via end-of-session ritual

Pair this skill with a session-close skill (or your own end-of-session ritual) that scans the ending session for substantive planning work and prompts once to archive. The reason to capture at session-close rather than at every `ExitPlanMode`:

- Plan mode often gets entered/exited multiple times per session for trivial "which approach" micro-decisions — hooking `ExitPlanMode` would flood the session with archive prompts.
- By session-close time the plan has been implemented (or explicitly deferred). The session has the full context — decision + execution + retrospective seed — which makes for a richer archive than a premature capture at exit-plan-mode time.

**Heuristic for triggering the prompt**:
- Session explicitly entered plan mode
- Alternatives were weighed before committing
- The design settled over >3 exchanges
- A decision was made that will affect future sessions

**Skip** purely tactical sessions: bug fixes, routine triage, comms, single-file edits with no alternatives considered.

To force-archive a session that the heuristic skipped: run `/plan-archive` directly.

## Retrospective Workflow

When revisiting an archived plan:
1. Find the file in the archive (grep, ripgrep, or your favorite indexer)
2. Update **Status** frontmatter field: `drafted → implemented` or `drafted → abandoned`
3. Fill in the **Retrospective** section: what happened, was it right, what changed
4. If plan was superseded: add `superseded-by: YYYY-MM-DD-{new-slug}` to the status line

The retrospective isn't for posterity — it's for training future-you (and future-AI). When a new plan resembles an old one, the retrospective tells you whether similar bets paid off.

## Example Invocations

```
/plan-archive                              # synthesize from current conversation
/plan-archive topic:database-migration-v3  # specific topic slug
/plan-archive file:./notes/2026-04-25.md   # archive existing doc
```
