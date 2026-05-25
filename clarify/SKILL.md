---
name: clarify
description: "Force a self-audit of the current request — list every ambiguity, assumption, unilateral tradeoff, and irreversible-action risk, then ask David via AskUserQuestion before proceeding. Use when David says '/clarify', 'any doubts?', 'are you sure?', 'what are you assuming?', 'check with me first', 'wait — confirm', 'before you start', or any time you catch yourself thinking 'I'll assume X' / 'probably wants Y' / 'going with Z' / 'while I'm here I'll also...' / 'looks like David means...' / 'I think the right approach is...' / 'this could mean A or B — I'll go with A' on a non-trivial task."
user-invocable: true
disable-model-invocation: false
---

# /clarify — Disambiguate Before Acting

This skill exists because passive prose rules ("use AskUserQuestion proactively") get skimmed past. `/clarify` is a structural forcing function: when invoked, you MUST stop, audit, and ask. No exceptions.

## When this fires

**Explicit triggers (David):**
- `/clarify` (slash command)
- "any doubts?" / "are you sure?" / "what are you assuming?"
- "check with me first" / "before you start" / "wait — confirm"

**Self-triggers (you):** the moment you catch yourself writing or thinking any of these on a non-trivial task — STOP and run /clarify on yourself:
- "I'll assume X" / "probably wants Y" / "going with Z"
- "while I'm here I'll also fix..."
- "looks like David means..."
- "I think the right approach is..."
- "this could mean A or B — I'll go with A"

**Skip /clarify when**: David's request is a single unambiguous action ("create a Todoist task called X", "read this file", "what does Y do"). Don't ask for permission to do what was directly asked.

## Procedure

### Step 1 — Audit (silent, internal)

**If self-triggered mid-stream**: halt any in-flight tool calls before completing the audit. The point is to ask BEFORE the action, not narrate it after.

Scan the current request and your in-flight plan for items in these four buckets. **Be exhaustive — better to surface 6 things and skip 4 than to surface 2 and miss the one that mattered.**

**Bucket A — Ambiguities in David's request**
Things he said that could mean two different things. Examples:
- "archive this workflow" → archive in n8n? in registries? both? delete?
- "fix the email" → which email? rewrite or just typos?
- "update the script" → update what behavior? replace it?
- pronouns with unclear antecedents ("them", "that one", "the new one")

**Bucket B — Scope assumptions**
Auto-expansions you're inclined to do. Examples:
- "while I'm here I'll also rename X" / "I'll clean up the surrounding code"
- "this needs a new helper too" (does it?)
- "I'll add tests" (was that asked?)
- touching files outside the requested scope

**Bucket C — Unilateral tradeoffs**
Decisions you're making for David instead of with him. Examples:
- library choice (lodash vs native, axios vs fetch)
- file placement (`utils/` vs `lib/` vs colocated)
- naming (function name, env var name, table name)
- breaking change vs additive (do you preserve old API?)
- architectural pattern (singleton vs DI, sync vs async, polling vs webhook)

**Bucket D — Irreversible-action risk**
Anything that can't be reverted via API:
- sending messages (email, Slack, WhatsApp)
- pushing/force-pushing, dropping tables, deleting branches/files
- creating public artifacts, publishing packages
- modifying shared infra (n8n production workflows, CI/CD, DNS)
- spending money

### Step 2 — Triage (silent)

For each item found, decide:
- **Ask** — genuine ambiguity, multiple valid answers, David's preference matters → goes into AskUserQuestion
- **State and proceed** — you have a strong default, low downside if wrong → mention it in your text reply ("Going with X — say if you want Y instead") and proceed
- **Skip** — truly obvious from context, asking would be insulting

**Bias toward asking.** If you're 60/40 on whether it's obvious, ask. The cost of asking is one click; the cost of guessing wrong is rework + trust.

**Calibration check.** If everything triaged to State-and-proceed or Skip and the Ask bucket is empty, ask yourself why /clarify fired. If you self-triggered, you noticed *something*. An empty Ask bucket on a self-triggered run usually means you rationalized the ambiguity back into "obvious" — the exact failure mode this skill exists to prevent. Re-surface at least one item.

### Step 3 — Ask via AskUserQuestion

Build ONE AskUserQuestion call with up to 4 questions. If you have more than 4 genuinely-ambiguous items, ask the top 4 and hold the rest until those are answered.

**Question construction:**
- Each question is one focused decision — don't compound ("which library AND should we test?")
- 2-4 options per question, mutually exclusive
- Mark your recommendation with "(Recommended)" and put it first
- Each option gets a `description` explaining the consequence/tradeoff
- For Bucket D items (irreversible): one option should always be "Don't do this — explain alternative"

**Don't ask:**
- "Should I proceed?" / "Is this OK?" — those are non-questions
- Things David already specified — re-asking signals you weren't listening
- Things you can verify yourself with a Read or Bash call

### Step 4 — Apply answers

Once David answers, restate the resolved understanding in one short line ("Got it — X with Y, leaving Z alone"), then proceed. Do NOT re-ask the same question on the next turn.

If David selected "Other" with free-text, treat it as authoritative even if it contradicts your recommendation.

## Anti-patterns

- **Asking after you've already done the thing** — defeats the purpose. Audit BEFORE the irreversible action.
- **Asking obvious things** — "should the function be named addUser or createUser?" when David has a clear convention (read the codebase first). Asking is not a substitute for thinking.
- **One question with 12 options** — split into focused questions of 2-4 options each.
- **Burying the recommendation** — if you have a clear default, lead with it and label it "(Recommended)". Don't make David guess what you'd pick.
- **Re-running /clarify in a loop** — once David answers, those answers stick for the rest of the task. Don't re-ask on the next turn.
- **Asking instead of doing trivial verification** — if you can answer it by reading a file, read the file. AskUserQuestion is for things only David can decide.

## Why This Exists

The rule "use AskUserQuestion proactively" lives in `~/.claude/rules/interaction-style.md` and `soul.md`. Despite being load-bearing, Claude has historically skimmed past it on multi-step tasks — defaulting to "make reasonable assumptions and proceed" because that's faster and feels productive.

`/clarify` is a structural forcing function. When invoked (by David or by Claude self-recognizing a trigger phrase), it commands a literal AskUserQuestion call — not a prose rephrasing. The skill exists because behavior change requires a tool-shaped intervention, not another paragraph of guidance.

May 2026: David flagged that the existing rule was being ignored and asked for a skill that "specifically makes you load that tool." This is that skill.
