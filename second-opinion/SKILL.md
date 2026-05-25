---
name: second-opinion
description: "Multi-model review of a specific artifact (file, doc, strategic plan, PRD, decision). Runs Gemini + Claude Sonnet + Claude Opus in parallel — three independent reviewers with different strengths. Use when: 'get a second opinion on X', 'review this doc from multiple angles', 'multi-model audit of this plan', 'second opinion before I ship this', 'what would a hostile reviewer say'. Distinct from /fresh-eyes (hostile audit of the current conversation plan against reality) and gemini-code-review hook (auto-fires only on git commits for code diffs). Best for: strategic docs, PRDs, decision-journal entries, architecture plans, proposals, contracts."
user-invocable: true
disable-model-invocation: false
---

# /second-opinion — Multi-Model Artifact Review

Three independent reviewers (Gemini + Claude Sonnet + Claude Opus) examine a single artifact in parallel, then findings are synthesized into a severity-rated report.

## Inputs

- `file:<path>` — review a specific file (absolute path)
- `current` or no argument — review content pasted/described in the current conversation
- `/second-opinion focus:assumptions` — focus all reviewers on a specific angle

## What This Is NOT

- **Not /fresh-eyes** — `/fresh-eyes` does a hostile audit of the current conversation's plan against reality (are the code claims true, are the assumptions borne out by the actual files). `/second-opinion` reviews a *finished artifact* from multiple model families. They complement each other: use `/fresh-eyes` during planning, `/second-opinion` before shipping.
- **Not gemini-code-review** — that hook auto-fires on git commits, reviews code diffs for security/bugs. `/second-opinion` is deliberate, on-demand, for strategic outputs.

## Process

### Step 0 — Load Artifact

If `file:<path>` was given:
- Read the file at that path
- Record: filename, line count, file type, first 3 lines (preview)

If `current`:
- Use the content that was pasted or described in the last few messages
- Confirm with one line: "Reviewing [description of content] — N lines"

### Step 1 — Parallel Review (3 reviewers)

Spawn all three reviewers simultaneously (do NOT wait for one before starting the next):

**Reviewer A — Gemini (Bash tool)**

Run via Bash with a timeout. Gemini provides an independent perspective from a different model family — it catches patterns the Claude family tends to miss.

```bash
cat {FILE_PATH} | gtimeout 120 gemini -p "You are a critical reviewer. Examine this document and find: 1) Factual errors or unsupported claims 2) Logical gaps or inconsistencies 3) Important missing considerations or blind spots 4) Ambiguity that could cause misunderstanding or misimplementation. For each finding, rate: [CRITICAL] = breaks the whole artifact, [HIGH] = significant problem needing fix, [MEDIUM] = should address, [LOW] = minor. Quote the specific passage for each finding. Be specific — 'looks good' is not useful."
```

If content is inline (not a file), use `echo "content" | ...`.

If `gtimeout` is unavailable, use `timeout`. If gemini is unavailable: skip this reviewer and note DEGRADED.

**Reviewer B — Claude Sonnet subagent (Agent tool)**

Sonnet's strength: systematic, fast, broad coverage. Focuses on structure and completeness.

```
Spawn: general-purpose agent, model: sonnet
Prompt: "You are a systematic reviewer doing a structural audit. The artifact follows after the separator.

Review for:
1. Assumptions that could be wrong — list each assumption explicitly then evaluate it
2. Internal inconsistencies — claims or steps that contradict each other
3. Missing pieces — what does this plan/doc assume exists or happen, that isn't covered?
4. Edge cases not handled — failure modes, exceptional inputs, concurrent state
5. Scope creep or scope ambiguity — is the boundary of this artifact clear?

For each finding, rate [CRITICAL]/[HIGH]/[MEDIUM]/[LOW]. Quote the passage. Be terse.

---ARTIFACT---
{ARTIFACT_CONTENT}
```

**Reviewer C — Claude Opus subagent (Agent tool)**

Opus's strength: deep judgment, strategic reasoning. Focuses on soundness and alternatives.

```
Spawn: general-purpose agent, model: opus
Prompt: "You are a senior strategic advisor doing a judgment review. The artifact follows after the separator.

Your job is NOT to find typos or minor gaps — Sonnet is doing that. Your job is the harder questions:
1. Is the core bet here the right one? Is there a fundamentally better approach that wasn't considered?
2. What are the second-order effects if this plan succeeds exactly as written — are they all good?
3. What's the single most likely failure mode? Is it addressed?
4. Where is the author overconfident? (Look for unhedged absolute statements.)
5. What would change your recommendation? (Stress-test the key assumptions.)

For each finding, rate [CRITICAL]/[HIGH]/[MEDIUM]/[LOW]. Quote the passage.

---ARTIFACT---
{ARTIFACT_CONTENT}
```

### Step 2 — Synthesize

After all three reviewers return (or timeout — proceed with what completed):

1. **Deduplication**: Findings flagged by 2+ reviewers are higher-confidence. Mark them `[CONFIRMED BY N REVIEWERS]`.
2. **Severity merge**: If reviewers disagree on severity, take the higher rating (conservative).
3. **Organize by severity**: CRITICAL first, then HIGH, MEDIUM, LOW.

### Step 3 — Present Report

```
## Second Opinion Review: {artifact name}
Reviewed by: {which reviewers completed} | {timestamp}

### CRITICAL (N)
[findings]

### HIGH (N)
[findings]

### MEDIUM (N)
[findings]

### LOW (N)
[findings]

### ✓ Confirmed Correct (reviewers explicitly called out)
[things all reviewers agreed were sound]

### Synthesized Recommendation
[1-3 sentences: is this artifact ready? what's the most important thing to fix first?]

### Reviewer Coverage
- Gemini: {COMPLETE | DEGRADED (reason) | SKIPPED}
- Claude Sonnet: {COMPLETE | DEGRADED | SKIPPED}
- Claude Opus: {COMPLETE | DEGRADED | SKIPPED}
```

### Step 4 — Iteration (optional, user-initiated)

After presenting Round 1 findings:

> "Round 1 complete. {N} CRITICAL, {M} HIGH findings. Want a Round 2 focused on the unresolved issues? (max 3 rounds)"

If the user confirms Round 2:
- Extract only the unresolved CRITICAL/HIGH findings from Round 1
- Re-run the same 3 reviewers, but with this narrowed focus: "The following issues were flagged in Round 1. Verify if they're correctly identified, propose concrete fixes, and flag any new related issues."
- Present delta: what's new vs what changed vs what was confirmed

After Round 2, offer Round 3 only if CRITICAL items remain unresolved. Stop at 3 rounds regardless.

## Failure Modes

- **Gemini unavailable/timeout**: note `Gemini: SKIPPED (unavailable)` in report header; proceed with Claude reviewers only
- **Subagent crash**: mark that reviewer DEGRADED, proceed with remaining reviewers
- **Artifact too large** (>10k words): warn user; truncate to first 10k words for subagents; run Gemini on full file (it handles long context better)
- **All 3 reviewers fail**: fall back to single-model review by main context Claude; note "DEGRADED — single-model only"

Never silently skip a reviewer. Always note coverage gaps.

## Auto-Trigger (live globally 2026-04-25)

`~/.claude/hooks/second-opinion-gate.sh` is wired as a PostToolUse hook on `Edit|Write` in `~/.claude/settings.local.json`. It injects a suggestion (not auto-runs) when a strategic file is edited/written.

**Matched patterns** (tune in the hook if too noisy):
- `*.prd.md`, `*-prd.md`, `PRD.md` — product requirements docs
- `**/plans/*.md|.html` — plan documents
- `**/decisions/*.md` — decision-journal entries
- `**/proposals/*.md|.html` — proposals
- `**/architecture/*.md`, `ARCHITECTURE.md` — architecture docs
- `**/strategy/*.md`, `*strategy-*.md` — strategy docs
- `**/deals/*/offer.html`, `**/deals/*/cover-letter.*` — client-facing deal docs
- `**/contracts/*.md` — contracts

**Debounced**: one suggestion per file per 60 minutes (flag files in `/tmp/second-opinion-gate/`).

**Skipped always**: `.claude/cache/`, `.claude/sessions/`, `memory/`, `MEMORY.md`, `.gitkeep`.

To disable: remove the `second-opinion-gate.sh` entry from the `Edit|Write` PostToolUse array in `~/.claude/settings.local.json`.

## Example Invocations

```
/second-opinion file:./proposals/acme-rewrite.md
/second-opinion file:./decisions/2026-04-25-auth-approach.md
/second-opinion current                    # review what's in the conversation
/second-opinion focus:assumptions          # all reviewers focus on assumptions
```
