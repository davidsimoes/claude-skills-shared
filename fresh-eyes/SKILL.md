---
name: fresh-eyes
description: "Hostile audit of current plan or implementation. Spawns parallel subagents to verify everything against reality. Produces Reality Score."
user-invocable: true
disable-model-invocation: false
---

# /fresh-eyes - Deep Verification Review

Perform a comprehensive, assumption-free review of the current plan, implementation, or analysis. Reset all priors and verify everything against reality.

## Parameters
- `scope`: What to review - "plan", "code", "all" (default: "all")
- `focus`: Optional area to pay extra attention to (e.g., "api-contracts", "data-flow", "edge-cases")

## Philosophy

This is not a polite review. This is a hostile audit by a fresh engineer who trusts nothing from the conversation so far. Every claim gets verified. Every assumption gets challenged. Every "it should work" gets tested.

## Process

### Step −1 — Decide: orchestrator-inline, fan-out, or delegated?

`/fresh-eyes` has **three execution modes** with very different cost profiles. Pick deliberately.

1. **Orchestrator-inline (no Agent fan-out)**: the orchestrator (the session running `/fresh-eyes`) reads the audit target into its own context and performs all 4 roles itself in main context. ~10–20k tokens total. Right for single-file audits where the file fits comfortably in context and the orchestrator already has it loaded. Validated 2026-05-14 in the /close pilot (commit e2dfbea) — spawning 4 Agent subagents for a 268-line file would have burned ~280k tokens vs ~15k inline.
2. **Inline fan-out**: orchestrator spawns 3–4 Agent subagents (Sonnet) in parallel; each does its role. ~200–280k tokens. Right when the audit target is too large to fit in orchestrator context, OR when independent verification matters more than token cost (the orchestrator can't confabulate from its own context if it never read the file).
3. **Delegated**: orchestrator spawns a child Claude session via `/delegate`, which itself runs inline fan-out. Adds tmux/REPL boot latency (60–90s cold-boot Opus 4.7) but keeps the parent context clean. Right for 3+ iteration rounds or when the parent is doing unrelated work in parallel.

**Decision rule:**

| Situation | Orchestrator-inline | Inline fan-out | Delegate to child |
|---|---|---|---|
| Single file < 500 lines, orchestrator already has it in context | ✓ | | |
| User explicitly asks for "1 round" / "quick check" on a small target | ✓ | | |
| Audit target too large for orchestrator context, OR independent verification non-negotiable | | ✓ | |
| Parent expects 3+ iteration rounds | | | ✓ |
| Parent context already heavy (>50% used) | | | ✓ |
| Parent in the middle of unrelated work and wants audit in parallel | | | ✓ |
| 1 round is enough but parent is in plan mode | ✓ | ✓ | (delegation is incompatible — see below) |

**Why delegation costs more than the proposal first suggested**: a delegated child is itself an orchestrator that spawns 3-4 Level-2 Sonnet subagents. Realistic per-child context is 25–35k tokens, not the 10k initially estimated. Net parent savings are ~30–50%, not ~66%. For a 1-round audit on a small target, orchestrator-inline is the right choice — even inline fan-out is overkill. For 3+ rounds on a larger target, delegation's savings compound and the latency is worth it.

**When orchestrator-inline is the right call but you're tempted to fan out**: ask whether the orchestrator can confabulate from its in-context view. For a single SKILL.md it just read, the orchestrator's "Code Reality" check IS rereading the file plus grepping cross-references — that's what Sonnet subagents would also do, with 14× the tokens. The independence argument only wins when the orchestrator's prior context could bias its read of the audit target.

**Plan mode incompatibility:** Plan mode blocks the Write tool AND blocks Bash write operations. Step 0 requires both (Write to persist the plan content; Bash to run `persist.sh init` which creates the cache dir and lock dir). Therefore `/fresh-eyes` cannot delegate from inside plan mode — the child would fail Step 0 immediately and fall back to DEGRADED inline-text. **If parent is in plan mode and wants to audit the in-progress plan: exit plan mode first, OR run orchestrator-inline (which already has the in-context plan and skips Step 0's persistence).** Don't promise plan-mode-friendly delegation; it doesn't exist.

### Delegation contract (when Step −1 says "delegate")

Use the existing `/delegate` skill. Pass:

- `--name "fresh-eyes-{audit_session_id}"` so registry filename matches plan filename.
- `--cwd` set to the audit target's repo (so `git diff`, `git log`, etc. work in the child). For chat-only / repo-less / multi-repo plans, set `--cwd ~` (or any stable existing directory) — the child won't need git in those cases.
- `--prompt-file` containing the orchestrator's task brief (template below).
- `--model opus` if available — fresh-eyes orchestration is judgment-heavy synthesis (per `model-routing.md`). If parent is on Sonnet, child inherits Sonnet by default; explicit `--model opus` is worth the cost for the verdict-synthesis step.

**Child contract (must be in the prompt-file):**

The contract below extends `/delegate`'s stock state machine (`initializing` → `active` → `done`/`blocked`). The `degraded` and `crashed` statuses + `fsync` + EXIT trap are **fresh-eyes-specific extensions** — `/delegate` does not implement them by default. The orchestrator MUST include all of these instructions in the prompt-file; otherwise the child will fall back to stock behavior and the parent's polling logic for `degraded`/`crashed` will never fire.

1. Read `{{PLAN_FILE}}` first (Step 0 already wrote it; child receives the path). **If `{{PLAN_FILE}}` ends `-manifest.md`, ALSO read every file listed in the manifest, in the order specified.** Otherwise the child silently audits the index file (the manifest itself) and ships a vacuous verdict.
2. Run `/fresh-eyes` Steps 1–4 against that plan, applying the positive-scope contract from Step 1.
3. Write verdict to `~/.claude/cache/fresh-eyes/{audit_session_id}-verdict-round{N}.md` using **atomic write**: write to `{path}.tmp`, fsync, then `mv {path}.tmp {path}` so the parent never reads a partial file. (Fresh-eyes-specific — fsync is not in the stock /delegate child instructions.)
4. Update registry status sequence: `initializing` → `active` (set on first turn) → write verdict → `done` (set ONLY after verdict file is on disk + fsynced). Never set `done` before the verdict exists.
5. If any Level-2 subagent returns DEGRADED, write `status: degraded` (distinct from `done`) so parent knows the verdict is partial. (Fresh-eyes-specific status — must be in the prompt-file.)
6. Wrap the whole flow in a trap handler that writes `status: crashed` on EXIT/ERR — gives the parent a definitive end-state instead of a stuck `active`. (Fresh-eyes-specific — must be in the prompt-file; without it, a crashed child shows `active` until parent timeout.)
7. Self-`/close` and exit when verdict is on disk. The window is single-purpose; don't leave it idling.

**Parent contract (after spawn):**

1. Poll `~/.claude/cache/delegate/fresh-eyes-{audit_session_id}.json` every 30s for `status` change.
2. Timeout: **10 minutes** for a 3-4 subagent audit. If status is still `active` at 10 min, surface the timeout to the user and offer to peek at the child's tmux pane (don't auto-kill — child might be mid-write).
3. On `status: done` — read the verdict file at the documented path, surface it.
4. On `status: degraded` — read the verdict, but flag the partial nature in the user-facing summary.
5. On `status: crashed` — surface that explicitly; offer to inspect the pane or retry.
6. The verdict file is the only artifact the parent needs to absorb — no need to read the child's chat transcript or subagent dumps.

**Spawn gotcha (verified 2026-05-05):** `/delegate`'s `spawn.sh` waits 30s for the REPL footer. Cold-boot Opus 4.7 sometimes takes longer; spawn.sh exits with `timeout waiting for claude REPL`. If you see this, the child IS up — just paste the prompt manually (`tmux load-buffer` + `paste-buffer -p` + `Enter`). Or extend spawn.sh's poll budget. Either way, don't treat the timeout as "child failed to start."

### Step 0 — Persist plan to file

**Branch on what was passed as audit target:**

| Target form | Action |
|---|---|
| Single file path, exists, regular file, size > 0 | Skip persistence; reuse as `{{PLAN_FILE}}` |
| Multiple file paths (e.g., `plan.md spec.md design.md`) OR a manifest-style invocation | Persist a manifest at `${audit_session_id}-manifest.md` (see "Multi-file plans" below); pass that manifest path as `{{PLAN_FILE}}` (subagent preamble auto-detects manifest mode by suffix) |
| Path is a directory | STOP. Ask the user to point at a specific file or list of files |
| Path doesn't exist OR is empty file | STOP. Ask the user to disambiguate |
| Git target: `diff:HEAD~3`, `diff:main..feature`, `branch:feature-x`, `commit:abc123` | Materialize via Bash before fan-out (see "Git materialization" below) |
| Plan exists only in conversation context | Run `/clarify` if the conversation contains multiple competing revisions; otherwise persist via the steps below |

Why STOP for the unsupported modes: they were HIGH-severity invocation modes that produced vacuous audits in self-test (Round 1 verdict 2026-05-05) — silent empty fan-outs are worse than a clear error.

**Pre-Step-0 ambiguity check** (chat-only plans only): if the conversation has gone through 2+ major plan revisions (e.g., the user discussed Plan A and then revised to Plan B without explicitly retracting A), invoke `/clarify` before persisting: "I see X and Y in context — which is the plan I should audit?" This prevents the self-trigger phrase pattern ("I'll assume the latest plan is what they want") that `interaction-style.md` flags. If the audit target is unambiguous (single coherent plan in chat), skip the /clarify and proceed.

#### Persistence steps (chat-only plan, single file)

The mechanics — `audit_session_id` generation, cache-dir + lock acquisition, stale-lock recovery, prune, git materialization — live in `scripts/persist.sh`. Step 0 is now prose + script invocations; Claude calls the script, parses its `key=value` stdout, and uses the Write tool for content.

1. Run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh init`. Parse stdout for `audit_session_id` and `plan_path`. The script generates a millisecond-precision ISO id, ensures the cache dir exists, and acquires a durable lock (no shell-exit trap — the lock persists across Claude tool calls).
2. **On exit 75 (lock conflict)**: this is a same-millisecond collision. Wait 1ms (`sleep 0.001`) and retry once. **Two consecutive exit-75 from `init` → surface to user.**
3. **On exit 78 (config error)**: `$HOME` unset, `python3` missing or `< 3.6`, or `$CACHE_DIR` read-only. Surface verbatim to user — no retry.
4. Use the Write tool (NOT Bash heredoc — Write avoids permission noise) to write the plan content to `plan_path`.
5. **Post-Write verification** (mandatory before Step 1): use the Read tool on `plan_path` and check `size > 100 bytes` AND first ~200 chars match what you intended to write. If the file is missing, empty, or contains stale content, mark the audit DEGRADED and stop fan-out.
6. Pass `plan_path` to all subagents via the placeholder `{{PLAN_FILE}}` (see Step 1 positive-scope contract below).

#### Multi-file plans

Some audits need more than one file (e.g., `plan.md` + `spec.md` + `architecture-diagram.md`, or several PRDs that interrelate). Treating any single file as "complete context" actively misleads subagents.

When the audit target is multi-file:

1. After `init` (which gave you `audit_session_id` and `cache_dir`), use the Write tool to write a **manifest file** at `${cache_dir}/${audit_session_id}-manifest.md` with:
   ```
   # Audit manifest — {audit_session_id}

   ## Plan files (read all in order)
   1. /abs/path/plan.md — [one-line role: "scope and goals"]
   2. /abs/path/spec.md — [one-line role: "API contract"]
   3. /abs/path/architecture.md — [one-line role: "data flow + dependencies"]

   ## Reading order
   Read 1 first (sets context), then 2 and 3. Cross-reference between them.
   ```
   Format unchanged from prior versions: numbered list with one-line role hints + reading-order paragraph.
2. Pass the **manifest path** as `{{PLAN_FILE}}` (yes, the manifest IS the plan file — it points subagents at the rest).
3. Subagents read the manifest first, see the multi-file list, read the listed files. Files listed in the manifest count as "explicitly referenced by name" under the positive-scope contract.
4. The `files_read: [...]` accountability field will include the manifest + every listed file. Anything beyond that is out-of-scope (the contract still bites).

Single-file plans skip the manifest — the plan file IS the context.

#### Git materialization

For `diff:`, `branch:`, or `commit:` style targets, materialize to a snapshot file before fan-out — subagents have no guarantee that `git diff` output will be stable mid-audit (file changes, branch moves).

Run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh materialize <audit_session_id> <target>` and parse `materialized_path` from stdout. Use that path as `{{PLAN_FILE}}`.

Supported target forms: `diff:<ref>`, `diff:<A>..<B>`, `diff:<A>...<B>`, `branch:<name>`, `commit:<sha>`. The script verifies refs (rejecting empty refs, malformed ranges, and unknown SHAs with exit 65 + DEGRADED on stderr) and writes the result to `<id>-diff.md`, `<id>-branch.md`, or `<id>-commit.md` under the cache dir.

**On stderr containing `DEGRADED: output exceeds 2MB`**: surface the warning to the user — subagents may hit context truncation. The file is still produced (better to surface than abort).

After successful materialization, apply post-Write verification (step 5 above) — empty diff = nothing to audit = surface to user, don't silently proceed.

#### Iteration mode (Round N>1)

Reuse `audit_session_id` across rounds. Before re-fan-out, reacquire the lock with `resume`:

1. Run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh resume <existing_audit_session_id>`. Parse stdout the same way as `init`.
2. **On exit 75 (lock held by another caller)**: do NOT bump the id and retry. Surface to the user as "session locked, abort or wait?" — bumping the id would silently abandon the in-flight audit.
3. **On exit 65 (cache files missing or empty)**: the lock is auto-released; surface the data error. Common cause: prune deleted Round N artifacts (>7d pause). Surface as "session pruned" not "never existed."
4. **Re-entry within the same orchestrator**: if your orchestrator already holds the lock from an earlier `init` or `resume` in this session, call `release-lock <id>` first before invoking `resume <id>` again. Otherwise `resume` will (correctly) exit 75 — it has no way to distinguish you from an unrelated concurrent caller.
5. If the plan evolved between rounds, the Write tool overwrites `plan_path`. Re-run post-Write verification after each overwrite.
6. Annotate overwrites with a comment header (`<!-- Round N applied: ${changes summary} -->`) so subagents auditing Round N+1 can detect what changed.
7. When the round's verdict is on disk, run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh release-lock <audit_session_id>`. The call is idempotent — `released=true` if the lock dir existed, `released=false` if not.

#### Cache hygiene

The cache dir is shared across audits. Without an explicit `audit_session_id` in the orchestrator's task brief, a delegated child can't reliably pick the right file when the dir contains multiple plan files. **Always include `audit_session_id` in any delegate-prompt-template.**

Run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh prune` **before any new audit (Step 0 of `/fresh-eyes`)** — not at every Claude session start (`/fresh-eyes` doesn't run every session). The script removes plans/manifests/materialized files older than 7 days and verdicts older than 30 days. **Caveat**: a Round N+1 attempted after `prune` has run on stale artifacts (e.g., the user paused iteration > 7 days) will fail with `resume <id>` exit 65 — surface that case clearly as "session pruned" not "never existed." `/close` and `/maintenance` should also fire prune as a backstop.

#### Failure mode

If `init` / `resume` exit non-zero (lock conflict, disk full, missing `$HOME`, missing `python3`, etc.), fall back to inline plan-as-prompt-text with explicit DEGRADED warning prepended: `"DEGRADED: plan persistence failed at {path} (reason: {lock|write|verify|config}), audit reliability reduced — subagents work from prompt-text only."` Log the script's stderr verbatim in the final verdict. **Exit-75 from `init` is retry-safe** (bump id by 1ms, retry once; two consecutive exit-75 → surface). **Exit-75 from `resume` is NOT retry-safe** — surface to user immediately.

#### Tests + script-extraction discipline

`scripts/persist.sh` ships with `tests/persist.bats` (38 tests: 31 equivalence + 5 edge + 2 hygiene; 2 are skipped — test 27 is documentation-only; E4 is environment-dependent / requires controlled tmpfs). Run `bash ~/.claude/skills/fresh-eyes/tests/run-tests.sh` before committing changes to `scripts/persist.sh`. The runner does `bash -n`, `shellcheck`, and `bats tests/`. Required: `brew install bats-core shellcheck` (minimum bats 1.11.0).

The extraction discipline that motivated this layout: when a markdown skill grows multi-line bash that has shipped multiple load-bearing bugs across rounds of authorship, extract the bash to a tested script (`scripts/<name>.sh` + `tests/<name>.bats`). Mental simulation isn't enough for non-trivial bash; bats tests catch the next round of bugs structurally rather than relying on the author noticing them.

### Step 1: Gather Context (delegate via Agent tool, integrate summaries only)

Spawn parallel subagents via the **Agent tool** (matching `/maintenance` v6 fan-out pattern — that's the verified Claude Code primitive for subagent fan-out). Each subagent does the heavy reading; the orchestrator integrates only their 3-line summaries (~1k tokens each), so detailed findings stay out of main context — pollution is bounded, not zero.

**How many subagents**: spawn 3 if `scope:code` (skip Edge Case — no decisions to enumerate without a plan), 4 if `scope:plan` or `scope:all` (include Edge Case). For very small audits the user may explicitly request fewer roles; default to the scope-driven count.

**Orchestrator-inline override (no Agent fan-out)**: when Step −1 selected mode 1 (orchestrator-inline), the orchestrator runs all 3 or 4 roles in its own context — no Agent calls. Produce per-role notes (Plan/Decision, Code Reality, Integration, [Edge Case]) before synthesizing into Step 3's verdict, so the structure remains traceable. The `files_read: [...]` accountability still applies — the orchestrator records every file it read while playing each role; out-of-scope reads still flag findings as UNVERIFIED. The positive-scope contract is internalized rather than passed as a subagent prompt.

**Subagent prompt requirement (Step 0 hand-off — positive-scope contract):** A simple "do not search for plan files elsewhere" prohibition is too narrow — it's obeyed to the letter while subagents still freely read PRDs, sibling SKILL.md, etc. that they don't classify as "plan files" (verified in self-audit, 2026-05-05). Use a positive-scope contract instead. Each subagent prompt MUST start with:

```
Read the file at {{PLAN_FILE}} FIRST. That file is your scope-defining artifact.

Branch on the filename suffix:

- `-manifest.md` → MULTI-FILE PLAN MODE. Read every file the manifest lists, in
  the order specified. Those files plus the manifest are your COMPLETE context.

- `-diff.md` / `-branch.md` / `-commit.md` → CODE-CHANGE AUDIT MODE. {{PLAN_FILE}}
  is raw `git diff` / `git log -p` / `git show` output. Audit the code change
  itself — what it does, what it breaks, what it forgets. Do NOT try to extract
  "plans, decisions, stated goals" from it; a diff has none. If the orchestrator
  asked you to do plan-shaped extraction (e.g., Plan/Decision Subagent role),
  reframe your output as "what the code change CLAIMS to do (commit message,
  hunk titles, naming) vs what it ACTUALLY does (the line-by-line diff)."

- `-plan.md` or any other single file → PLAN MODE. {{PLAN_FILE}} IS your
  COMPLETE context.

In all branches: do not read any other files unless they are explicitly referenced
BY NAME in {{PLAN_FILE}} (or its manifest entries, in MULTI-FILE PLAN MODE).

If you cannot complete your task from the listed files alone, return:
  INSUFFICIENT_CONTEXT: [what was missing, why you needed it]
Do NOT search for additional context.

In your final output, include a `files_read: [...]` field listing every file path
you read. The orchestrator will reject outputs without this field.
```

Substitute `{{PLAN_FILE}}` with the path written in Step 0 (or the user-provided file path when Step 0 was skipped). Two things matter together:
1. **Positive scope** ("plan IS your complete context") closes the drift vector that prohibition-style framing leaves open.
2. **`files_read: [...]` accountability field** — the orchestrator inspects each subagent's `files_read` list against `{{PLAN_FILE}} + plan-referenced names`. Out-of-scope reads → that subagent's output is flagged UNVERIFIED in the verdict.

**Background:** This contract exists because earlier rounds of fresh-eyes audits hit DEGRADED state when subagents auto-discovered stale unrelated files instead of the chat-only plan. The first fix (a prohibition-style preamble: "don't read X") didn't actually close the bug — self-audit confirmed subagents still read 4–6 unrelated files because none registered as "plan files." The positive-scope contract above ("plan IS your complete context") is the verified-effective replacement.

**Model selection**: use **Sonnet** minimum for verification subagents. Never Haiku — it confabulates when it can't find what it's looking for, which is exactly the failure mode this skill exists to catch. The orchestrator runs on whatever model started the session (Opus is the right choice for hostile-audit synthesis).

When `focus` is set (e.g., `focus:auth`, `focus:data-flow`), the orchestrator passes it verbatim into every subagent prompt. Each role decides how to apply it: Plan/Decision and Code Reality treat it as a search bias (extra weight on files/sections matching the focus); Integration treats it as a depth multiplier (trace the focus area end-to-end first); Edge Case prioritizes failure modes in the focus area. Subagents NOT given a focus operate at default breadth.

Independent verification by subagent role:

1. **Plan/Decision Subagent**: Extract all claims, decisions, and stated goals from `{{PLAN_FILE}}` (NOT from your conversation/system context — those are unreachable as a subagent). List every concrete claim made ("we'll use X", "file Y does Z", "this handles edge case W"). Earlier wording ("from the conversation") conflicted with the positive-scope contract above; this is the resolution.

2. **Code Reality Subagent**: For every file **explicitly named in `{{PLAN_FILE}}`** (or files listed in its manifest, if multi-file mode), read the ACTUAL current state. Compare against what the plan claims it contains or does. Earlier wording ("files touched in implementation") contradicted the positive-scope contract — names in the plan are the only authorized read set; implicit references like "our auth module" without a path do NOT authorize reading auth files.

3. **Integration Subagent**: Trace data flow end-to-end across the files named in `{{PLAN_FILE}}`. Check that inputs, outputs, types, and contracts actually match across boundaries (API calls, function signatures, config references, env vars). If the plan claims an integration with a file not named, flag the integration as UNVERIFIABLE rather than reading the unnamed file.

4. **Edge Case Subagent** (only spawned when `scope:plan` or `scope:all`): **First, extract the decision list from `{{PLAN_FILE}}` yourself** — parallel subagents cannot share Plan/Decision Subagent's output, so you must re-derive the decisions from the plan. Then for each decision, ask "what happens when this fails?" — network errors, empty inputs, permissions, rate limits, concurrent access, missing config. **Mode precedence**: if `{{PLAN_FILE}}` is in CODE-CHANGE AUDIT MODE (`-diff.md`/`-branch.md`/`-commit.md` suffix), Edge Case does NOT apply the preamble's reframe instruction — return INSUFFICIENT_CONTEXT instead. Edge Case operates only in PLAN MODE or MULTI-FILE PLAN MODE; the orchestrator should not have spawned it for diff targets in the first place, but the role-level guard catches the case where it did.

### Step 2: Cross-Reference

Compare subagent findings. Flag every discrepancy between:
- What the conversation says vs. what the code actually does
- What the plan assumes vs. what the codebase supports
- What was promised vs. what was implemented
- Dependencies that are assumed to exist vs. what's actually installed/configured

### Step 3: Structured Verdict

Present findings in this format:

```
## Fresh Eyes Review

### Verified Correct
- [Things that are actually right — cite evidence]

### Wrong or Inaccurate
- [HIGH] [Claims that don't match reality — show what was said vs what's true; tag every finding with [HIGH]/[MEDIUM]/[LOW] per Step 4 calibration]
- [MEDIUM] [Include file paths, line numbers, actual values]

### Missing or Incomplete
- [HIGH] [Things the plan/implementation forgot]
- [MEDIUM] [Edge cases not handled]
- [LOW] [Integrations not wired up]

### Fragile / Risky
- [Things that technically work but are brittle]
- [Assumptions that could break under real conditions]
- [Areas with no error handling or fallback]

### Over- or Under-engineered
- [HIGH/MEDIUM/LOW] [Complexity that costs more than it earns OR missing structure where a load-bearing abstraction is needed]
- [Examples: redundant abstractions, dead code, vestigial options, copy-pasted patterns that should be a helper, missing helpers that force repetition]

### Recommendations
- [Prioritized list of what to fix, in order of impact]
```

The four findings buckets map to Step 4's four dimensions: Wrong/Inaccurate → Correctness, Missing/Incomplete → Completeness, Fragile/Risky → Robustness, Over-/Under-engineered → Simplicity. Every Simplicity subtraction in Step 4 should be traceable to an entry in the Over-/Under-engineered bucket.

### Step 4: Reality Score

**Who computes**: the orchestrator, NOT the subagents. Subagents provide evidence (claims, line references, contradictions); the orchestrator synthesizes that evidence into the score. If a subagent volunteers a "Reality Score 9/10" in its summary, treat that as input only — re-derive from the evidence list.

**Aggregation**: the headline `Reality Score: X/10` is the **MIN of the four dimensions**, not the average. A 9/9/9/5 means the artifact has a load-bearing weakness in one area and ships at 5, not 8. This forces the worst dimension to drive iteration priority.

**Headline format**: report as `Reality Score: <MIN>/10 (<C>/<K>/<R>/<S>)` where C/K/R/S are Correctness/Completeness/Robustness/Simplicity. Example: `Reality Score: 6/10 (8/8/8/6)`. The tuple makes non-bottleneck progress visible across rounds — without it, an artifact that improves 7→8 on three dimensions while one dimension is structurally pinned at 6 shows no headline movement at all.

Give an honest assessment with each dimension anchored to a concrete subtraction rule, not a vibe:

```
Reality Score: <MIN>/10 (C/K/R/S)

- Correctness: X/10 — claims that match reality
    Subtraction calibration: −1 per disproven HIGH-severity claim, −0.3 per MEDIUM, −0.1 per LOW.
    10 = all verified.
- Completeness: X/10 — load-bearing things present
    Subtraction calibration: −1 per missing HIGH-severity essential, −0.3 per MEDIUM, −0.1 per LOW.
    10 = nothing critical missing for the stated scope.
- Robustness: X/10 — handles real-world failure modes
    Subtraction calibration: −1 per unhandled HIGH failure mode, −0.3 per MEDIUM, −0.1 per LOW.
    10 = all covered.
- Simplicity: X/10 — design proportional to the problem
    Subtraction calibration: −1 per major over- or under-engineering symptom (load-bearing complexity that
    a simpler design would avoid), −0.3 per moderate, −0.1 per minor.
    10 = minimum viable, no waste.
```

**Severity tagging is required in Step 3 findings** so Step 4's subtractions are derivable. Mark each finding with `[HIGH]`, `[MEDIUM]`, or `[LOW]` in the Wrong / Missing / Fragile sections — Step 4 then applies the calibration above. Unmarked findings should be treated as MEDIUM by default but flagged with a note that severity wasn't classified.

The score is opinion, not measurement — but the anchors + severity-tagged findings keep it honest and comparable round-to-round. Across paired audits we'd EXPECT auditors to land within ~±2 per dimension; we don't have a measurement loop to enforce that, so treat it as a sanity expectation, not a guarantee. If two rounds on the same artifact diverge by more than 2 on any dimension, that's a signal to re-read the rubric, not to argue.

## Rules

- **Verify, don't recall** — re-read every file, don't trust conversation memory
- **Be specific** — "the API contract is wrong" is useless. "Line 42 of api.ts sends `userId` but line 18 of handler.ts expects `user_id`" is useful
- **No mercy** — if something is wrong, say it plainly. Don't soften findings
- **Proportional depth** — spend more time on high-impact areas (data flow, auth, money) than cosmetic issues
- **Actionable output** — every finding should have a clear fix, not just a complaint

## Example Usage
```
/fresh-eyes                                  # Audit current chat plan (Step 0 persists it)
/fresh-eyes scope:plan                       # Review plan only, before implementation
/fresh-eyes scope:code focus:auth            # Review implementation, focus on auth flow
/fresh-eyes focus:data-flow                  # Full review with extra attention to data flow
/fresh-eyes /abs/path/plan.md                # Audit a specific plan file
/fresh-eyes plan.md spec.md design.md        # Multi-file plan → manifest mode
/fresh-eyes diff:HEAD~3                      # Audit last 3 commits' diff
/fresh-eyes branch:feature-shopify-markets   # Audit a feature branch vs main
/fresh-eyes commit:abc123def                 # Audit a single commit
```

## Failure modes

What happens when subagents or the iteration loop misbehave:

- **Subagent crash / timeout**: orchestrator uses the partial output (or 3-line summary if returned). Mark that subagent's section in the verdict as DEGRADED with the error. Do NOT retry the same prompt — per `rules/subagent-recovery.md`, a context-exhausted subagent fails the same way on retry; either split the task or fall back to direct main-context exploration.
- **Subagent contradiction**: Plan subagent says X works; Code subagent says X is broken. Surface the contradiction in the verdict explicitly — do NOT pick a winner. Escalate to the user (or main-context spot-check) before either claim is treated as truth.
- **Subagent confabulation**: subagents have hallucinated in past `/maintenance` runs (~40% rate on infra topics, 2026-04-23). For any **CRITICAL or HIGH severity finding**, the orchestrator MUST verify by direct file read or grep before accepting it into the verdict. A finding without independent verification stays UNVERIFIED in the output, never DISMISSED-without-WHY.
- **Rate limit / partial fan-out failure**: proceed with the subagents that succeeded. Mark the verdict DEGRADED with which roles are missing. Do not silently re-run; honest partial > false complete.
- **Score gaming**: if a subagent claims "Reality Score 9/10" but its findings list shows 5 unfixed CRITICAL items, the orchestrator overrides the score downward. Subagent-claimed scores are inputs, not outputs.
- **Plan persistence failure**: If Step 0's Write fails (permissions, disk full), fall back to inline plan-as-prompt-text with explicit DEGRADED warning. Audit can proceed but reliability drops — subagents may scope-confuse if the prompt text is ambiguous about what's the audit target. Document the failure path in the verdict so the user knows to fix the underlying disk/permission issue.
- **Orchestrator (parent) crash mid-audit**: child contracts have a trap handler (Delegation contract step 6); inline mode does not. If the orchestrator crashes during Step 1 fan-out or Step 2 synthesis, subagent outputs may live in the Agent tool's response history but the verdict file will not exist. Recovery: re-run /fresh-eyes from scratch. Do NOT attempt to recover partial subagent outputs from the prior run — they're untrusted (the orchestrator never verified files_read accountability). If parent context is heavy AND audit is large, prefer delegation (Step −1) so the child has a trap handler.
- **User cancels /fresh-eyes mid-round** (Ctrl-C, /stop, session kill): subagents are mid-execution; partial outputs may exist in Agent tool history. Treat the audit as discarded — re-run from scratch. Do NOT attempt to resume from partial state. Locks are durable across Claude tool calls (no shell-exit trap by design — see Step 0 line 94). After ANY abort, manually run `bash ~/.claude/skills/fresh-eyes/scripts/persist.sh release-lock <audit_session_id>` (idempotent) before retrying — or wait >3600s for auto-stale-recovery to fire on the next `init`/`resume`.
- **Parent context fills during synthesis**: Step −1 says "delegate if >50% used," but if the audit was started inline at 30% and Step 1 outputs push past 80%, compaction during Step 2 may discard subagent findings before Step 4 writes. **Mitigation**: emit the Step 3 verdict (with whatever findings are synthesized) BEFORE compaction triggers, even if Step 4 hasn't computed the score yet. A partial verdict with a "score TBD due to context pressure" note is honest-partial; silent loss is silent-abort.
- **Subagents return contradictory `files_read`** (one in-scope, one out-of-scope read): flag the offending subagent's findings as UNVERIFIED, but only the findings traceable to the out-of-scope read — keep findings derivable from in-scope reads. If unclear which findings depended on which read, mark all findings from that subagent UNVERIFIED.
- **Plan file edited mid-audit**: if the plan file's mtime changed between Step 0 post-Write verification and Step 4, mark the verdict DEGRADED with "plan file mutated mid-audit at <timestamp>" — different subagents may have read different versions. Do NOT attempt to reconcile; surface the mutation and let the user decide whether to re-run.

**Continuation policy**: the audit ALWAYS completes a verdict, even when failure modes fire. Crashes/timeouts produce DEGRADED sections; contradictions surface both claims publicly; rate-limit failures publish what succeeded. Never silently halt mid-audit. The only legitimate **mid-audit** halt is user cancellation. Step 0 STOP cases (directory target, empty file) halt before the audit begins and are not subject to this policy — they produce a clear error to the user, not a verdict. Honest partial > false complete > silent abort.

## Iteration mode — iterate-to-10/10

The recommended usage pattern is to treat `/fresh-eyes` as an **iteration loop**, not a one-shot audit. Each round produces findings → apply fixes → re-run. The skill should stay aware of this and support it explicitly.

### How to iterate
1. Run `/fresh-eyes` once — produce Reality Score + findings
2. Apply fixes (inline if trivial; defer via PRD if content-aware)
3. Re-run `/fresh-eyes` on the SAME target with previous-round findings in context
4. Compare scores across rounds — each round's artifact should reference prior rounds' findings ("X was flagged in round N, fixed in round N+1") so progress is traceable. **Use the tuple format `<MIN>/10 (C/K/R/S)`** so per-dimension progress is visible across rounds; without it, an artifact whose 3 dimensions move 7→8 while one is structurally pinned at 6 shows no headline movement at all.
5. Stopping rules (evaluate in order, first-match wins):
   - **Score ≥ 9/10 on all dimensions** → STOP, goal met
   - **0 NEW HIGH or MEDIUM findings for 2 consecutive rounds** → STOP, diminishing returns regardless of headline score. Remaining gaps are either structural (require refactoring, not text iteration) or LOW (cosmetic, batch-closeable). This rule fires before the score-floor rules (rules 3–4 below) and is the primary signal that the loop has done its job. Before STOP fires, present any unresolved NEW LOW findings to the user for batch-close or ACCEPTED-LIMITATION classification — silent stop with unresolved LOWs is documentation drift. Validated retroactively in the May 2026 self-audit: would have stopped that 5-round loop at end of Round 4.
   - **MIN score ≥ 7/10 AND no new findings for 2 consecutive rounds** → STOP, all dimensions in good shape (note: MIN ≥ 7 means EVERY dimension is ≥ 7, since headline is MIN; this is intentionally a higher bar than the rule above)
   - **MIN score < 7/10 AND no new findings for 2 consecutive rounds** → ESCALATE. See the two-branch decision below.
   - **5 rounds total reached** → STOP regardless, write artifact noting incomplete state and remaining gaps

**ESCALATE — two branches** (when the rule above fires):

- **Branch A (audit angle wrong)**: the artifact may be fine but the audit roles aren't surfacing what's actually broken. Try /fresh-eyes again with a specific `focus:` parameter (e.g., `focus:auth`, `focus:concurrency`, `focus:contracts`) OR with a different role decomposition (e.g., add a domain-expert role for the specific area). Cost: 1 more round; if it surfaces new findings, the audit was wrong, not the artifact.
- **Branch B (artifact unfixable)**: the design itself is the problem. Open a new session, read ONLY the latest verdict + the original requirements (NOT the existing plan/code). Write a fresh PRD from scratch and start a new /fresh-eyes loop on the redesign. Do NOT reuse plan text from the failing artifact — it carries the assumptions that led to the plateau. **For chat-originated plans**: the "original requirements" live only in the current session's chat history, which won't transfer to a new session. Before opening the new session, extract the core requirements from the current chat into `~/.claude/cache/fresh-eyes/{audit_session_id}-requirements.md` (one paragraph: what does the user actually need, independent of the failing plan). That file becomes Branch B's input alongside the latest verdict.

If unsure which branch fits: try Branch A first (cheaper), and if it also plateaus below 7, take Branch B.

### Realistic ceiling
Claude-authored artifacts typically plateau at **8-9/10**. True 10/10 requires real-world runs surfacing issues the author couldn't anticipate. This is exactly how `/maintenance` matured v1→v8 — not through more fresh-eyes iterations on text, but through actual runs generating new evidence. If you hit a plateau, **stop iterating the text and start running the thing**.

### Rules for iteration rounds
- **Re-persist before re-audit.** Round N+1 starts with Step 0: if the user has applied fixes inline in chat between rounds, overwrite the cached plan file with the updated version. Subagents always read the current file, never the prompt text.
- Round N > 1: read the previous round's findings FIRST. Your job is to check whether the prior fixes stuck AND find NEW issues — not to re-surface old ones.
- If round N finds the same issue flagged in round N-1, the fix didn't work. Say so explicitly — don't pretend it's a new finding.
- If you can't find anything new, that's a valid stopping signal. Reality Score might genuinely be 9+/10. Don't invent issues.
- **3-line summary constraint applies to all rounds**, not just round 1. Round N+ subagents return: (1) what changed since round N-1, (2) what's new this round, (3) overall delta. Detailed findings still live in their full output, just like round 1.
- **Round N+1 splits roles cleanly**: one subagent verifies prior-round fixes (FIX-STUCK / FIX-PARTIAL / FIX-MISSING / NEW-CONFLICT / NOT-FIXED-DOC / **ACCEPTED-LIMITATION** per fix); another hunts new issues. This separation prevents one subagent from being asked to do two cognitively conflicting jobs (verify what's there + imagine what's not).

- **Carryover classification — NOT-FIXED-DOC vs ACCEPTED-LIMITATION**: if a finding was deferred in Round N and is still unaddressed in Round N+1, classify it deliberately:
  - **NOT-FIXED-DOC**: deferred-but-still-live; should be reconsidered in subsequent rounds. Use this for at most 1–2 rounds.
  - **ACCEPTED-LIMITATION**: the user has consciously decided not to fix. Write the rationale into the verdict ("accepted because: ...") and STOP carrying it as a live finding in subsequent rounds. The May 2026 self-audit found 4 items carried as NOT-FIXED-DOC across 5 consecutive rounds without ever being formally accepted — that's documentation drift. Promote to ACCEPTED-LIMITATION by Round 3 at the latest, or fix it.

### When NOT to iterate
- Single-file config changes (one pass is enough)
- Bug fixes where the root cause is known
- Work the user already validated manually
- Things currently in production with no reported issues

### Relationship to Pattern C (Autoresearch)
Iteration mode shares structure with Pattern C from `agent-orchestration-prd.md` (change → measure → keep/revert) but lacks Pattern C's defining feature: an **automated fitness function**. Reality Score here is computed by an LLM each round, not measured against an external mechanical scorer (PageSpeed, Lighthouse, test-suite runtime). That's exactly why iteration plateaus at 8-9/10 on text — the same model class judging its own work.

True Pattern C requires an external, mechanical scorer the agent cannot self-game. When that exists for a domain (theme perf, n8n perf, test runtime), iteration mode here is a useful template for the loop structure — but you must replace the LLM-judged Reality Score with the mechanical fitness function before scaling. Don't claim Pattern C status without the mechanical scorer.
