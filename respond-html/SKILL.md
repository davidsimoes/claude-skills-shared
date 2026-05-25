---
name: respond-html
description: "Render a structured HTML artifact instead of a chat reply — for plans, proposals, comparisons, audits, recommendations, mockups, and process/data visualizations. Single self-contained file saved under an html-answers/ directory, opened in browser, with inline ✅/💬/❌ reactions + comment box on every section, decision-block, and callout. Live stats in sticky toolbar. One button copies all feedback as markdown for the user to paste back to chat. Use proactively when the user says 'show me a plan for X', 'compare approaches to X', 'mock up X', 'audit X', 'visualize this', 'html answer', 'html response', 'canvas this', 'structure this as html', 'show me visually', 'render this', '/respond-html', or any time the response is plan-shaped (3+ options with tradeoffs), proposal-shaped (recommendation with rationale), comparison-shaped (matrix or matrix-able), or audit-shaped (findings + severity + recommendations) — even if the user doesn't explicitly ask for HTML. The skill is an orchestrator: it routes data analysis to /dataviz data mode, process/workflow/architecture to /dataviz process mode, UI/component design to /frontend-design, and uses its own reading-optimized template for everything else. Always finishes with /chrome-validate before declaring ready."
user-invocable: true
disable-model-invocation: false
---

# /respond-html — Structured HTML Artifacts For Reading & Feedback

When a chat reply would be a wall of prose with implicit structure (sections, comparisons, decisions, tradeoffs), the artifact wins. The user scans the rendered HTML, reacts inline (✅/💬/❌ + comment per section/decision-block/callout), hits 📋 Copy feedback, pastes the markdown back to chat. The skill makes that the default path, not a special occasion.

## What this skill is

An **orchestrator** with one new template. It:

1. **Classifies** the request by content type.
2. **Delegates** to the right existing skill when one fits (`/dataviz` data mode, `/dataviz` process mode, `/frontend-design`), or **renders** with the response-artifact template when none of those fit (the gap this skill fills: plans, proposals, comparisons, audits, recommendations, structured analysis).
3. **QAs** the output with `/chrome-validate all` — non-optional. No "looks good" without evidence.
4. **Opens** the file in the user's browser via `open`.

## Phase 0 — Classify content type

Use `references/content-type-detection.md` for the full decision tree. Quick form:

| Signal | Route |
|---|---|
| Input is JSON/CSV/JSONL/TSV, or user says "analyze this data" / "EDA" / "profile this dataset" | `/dataviz` **data mode** |
| User describes a workflow, pipeline, architecture, state machine, "how X works"; numbered steps; sequence diagrams | `/dataviz` **process mode** |
| User asks for a UI component, page, app interface, prototype, "mock up X", "design a screen for X" | `/frontend-design` (apply its aesthetics rules) + this skill's template if the output is also a reading artifact |
| **Plan** ("show me a plan for X", "approach to X", roadmap) | **response-artifact template** |
| **Proposal** ("propose X", "recommend an approach", "what would you do") | **response-artifact template** |
| **Comparison** ("compare A vs B", "which is better", "tradeoffs of X") | **response-artifact template** |
| **Audit** ("review this", "audit X", "what's wrong with Y") | **response-artifact template** |
| **Recommendation / structured analysis** | **response-artifact template** |
| Ambiguous | One-line classification with reasoning, then ask. Default lean: response-artifact (it handles the widest range). |

Announce the classification in one line before proceeding: *"Classifying as a **plan** with 3 options → response-artifact template."*

## Phase 0.5 — Pick the gravity tag

After content-type, pick the **gravity tag** that matches the artifact's stakes + verdict + shape. The gravity tag deterministically chooses the font pair and accent — no rotation, no "what did I use last time." See `references/aesthetics.md` for the 8-row mapping table and the 3-step picker.

Eight tags: `stern` · `decisive` · `balanced` · `distinctive` · `editorial` · `measured` · `light` · `multidimensional`.

Extend the announcement: *"Classifying as a **plan** with 3 options, gravity **decisive** → Crimson Pro + Manrope + jade."* The chosen gravity tag goes into the artifact's eyebrow (e.g. "Plan · decisive").

## Phase 1 — If delegating, hand off cleanly

When the route is `/dataviz` or `/frontend-design`:

- **Invocation**: use the Skill tool with the exact skill name (`skill: "dataviz"` or `skill: "frontend-design:frontend-design"`) and pass the user's original request plus any context already gathered as `args`. For /dataviz, prefix the args with `data:` or `process:` to bypass /dataviz's autodetect — your Phase 0 classification is authoritative; double-classifying invites silent conflict.
- **Output path divergence**: /dataviz defaults to `data/{slug}_{hash6}_report.html` in the current working directory; /frontend-design typically produces code in chat or scaffolds a framework project, not a single HTML file. Phase 3 (chrome-validate) and Phase 4 (`open`) below assume the project-aware path resolved in Phase 2 exists — when delegating, you must either:
  - (a) pass an `output:<abs-path>` arg to /dataviz (supported — /dataviz writes there verbatim and suppresses its own Phase 6 `open`), OR
  - (b) use whatever path the target skill actually produces (read its SKILL.md or its emitted summary) and substitute that path into Phase 3 + 4.
  - For /dataviz, prefer (a) — concrete syntax: `data: <user-request> output:/abs/path/index.html` or `process: <user-request> output:/abs/path/index.html`. /frontend-design has no equivalent output-arg yet, so (b) is the only option there.
- Don't duplicate work — let the target skill own the render.
- After the target skill finishes, run the chrome-validate gate (Phase 3) yourself against whatever file path the target produced.

Stop here. Do not also produce a response-artifact.

**Maturity note**: when the route is unambiguous (a `.csv` file → /dataviz, an explicit "mock up a button" → /frontend-design), delegate without asking. Surface only when the request genuinely straddles modes (e.g., "show me the data AND a plan") — see Compound requests in `references/content-type-detection.md`. The response-artifact path (own template, Phase 2 below) is the well-trodden flow; delegation is less battle-tested but should not be avoided when clearly correct.

## Phase 2 — If rendering, build the artifact

**Inputs**: the user's request + whatever context was gathered (files read, conversation, prior decisions).

**Output path** (project-aware):

1. **Look at `pwd`**. If it's inside one of your standard project roots (e.g. `~/dev/<project>/`), write to `<that-root>/.html-answers/<slug>/index.html`.
2. **Otherwise scan the content** for project-name keywords that match your dev directories (e.g. `ls ~/dev/`). If a clear match, use that project's `.html-answers/`.
3. **Fallback** for cross-cutting / no-specific-project content: a generic shared dir like `~/dev/html-answers/<slug>/index.html` (configure to taste).

`<slug>` is a 3-5 word kebab-case summary of the topic (e.g., `compare-deploy-targets`, `audit-inbox-triage`, `q3-roadmap-plan`).

State the chosen path inline before rendering: *"Detected the `acme-migration` project — saving to `~/dev/acme-migration/.html-answers/vercel-plan/`."* If you're unsure (no `pwd` match, no clean keyword hit), surface a single AskUserQuestion with 2-3 plausible roots before rendering.

The path determines where TTL cleanup later sweeps from (see Phase 5).

**Template**: `templates/response-artifact.html`. Replace the placeholder tokens listed at the top of the file. See `references/response-artifact-spec.md` for what goes in each section and how to choose font pair + accent.

**Aesthetics come from the gravity tag picked in Phase 0.5** — no rotation, no random pick.
- The gravity row in `references/aesthetics.md` specifies the body serif, heading sans, and accent. Use exactly that combo.
- Never use any font on the never-list (Inter, Roboto, Arial, Helvetica, Space Grotesk, Open Sans, Lato, Merriweather).
- Two artifacts of the same gravity will share the aesthetic. That's correct — they're the same shape.
- If the gravity feels wrong while drafting, change the tag, not the font pair.

**Sections must include** (in order):
1. **BLUF** — bottom-line-up-front, 1-3 sentences. The single most important thing.
2. **Context / problem statement** — what we're answering and why.
3. **Body sections** — the actual content. Use callouts (`decision`, `tradeoff`, `risk`, `recommendation`) and decision-blocks (question + options + recommendation) where they earn their keep. Each section, decision-block, and callout becomes a **reactable unit** in the feedback model — the user can ✅/💬/❌ each one independently.
4. **Open questions / next steps** — what's unresolved, what the user needs to decide.

**Don't** dump raw chat transcripts into HTML. Synthesize. The artifact's value is the structure — TOC, callouts, scannable hierarchy, AND the inline reaction model. If you just paste prose into `<p>` tags you've added zero value over the chat reply.

**Feedback model** (handled by the template's JS — no manual work needed):
- Every section, decision-block, and callout gets ✅/💬/❌ buttons + comment box auto-injected.
- Sticky toolbar at the top shows live counts.
- One button copies grouped-by-section markdown to clipboard for the user to paste back.
- See `references/response-artifact-spec.md` for the snippet library and ID conventions.

## Phase 2.5 — Strategic content gate (only for plan/proposal/audit/recommendation)

Trigger condition (NOT a gravity tag — that's the visual layer; this is the content-type layer):
- The **content type** from Phase 0 is plan / proposal / audit / recommendation, AND
- The artifact contains at least one **decision-block** OR a **recommendation callout** that selects between options (testable: grep the rendered HTML for `class="decision-block"` or `class="callout recommendation"`). Pure-prose explainers without a recommend-an-option element don't trigger the gate.

When both are true, invoke `/fresh-eyes` on the rendered output BEFORE the chrome-validate gate. The hostile-audit pass catches what chrome-validate doesn't: stale claims, missing options, premise-not-questioned, scope drift from the original ask.

Skip `/fresh-eyes` for visualization-shaped output (data, process diagrams, UI mockups) where the artifact is descriptive not prescriptive — chrome-validate alone covers those. Also skip for short single-decision artifacts (gravity `light`) — over-auditing wastes context.

Strategic path: `Phase 2 (render) → Phase 2.5 (/fresh-eyes) → Phase 3 (chrome-validate) → Phase 4 (open)`.

## Phase 3 — Chrome-validate gate (non-optional)

After writing the file, run `/chrome-validate all` against the artifact. See `references/chrome-validate-handoff.md` for the exact invocation — note the `file://` rejection issue with `claude-in-chrome` and the `python3 -m http.server` workaround documented there.

Surface the GATE/STATUS/EVIDENCE block to the user. Do not say "ready" until every gate is PASS. On FAIL:
- Show the user the failing gate + the evidence
- Propose a fix (don't auto-apply changes that affect content/design — show the failure first, ask what to do)
- Once fixed, re-run the gate

The gate exists because untested HTML accumulates silent regressions (broken images, off-by-default CSS, dead links). The discipline is borrowed from `pre-send-qa-gate.md` Phase 3, reduced to a single tool call.

## Phase 4 — Open and report

```bash
open <output-path>/index.html
```

…where `<output-path>` is whichever path Phase 2 resolved (project-aware).

Final line to the user:

```
Ready at file://<absolute-path>/index.html — opening now.
```

Plus a one-line summary of what the artifact contains (so the user knows what to look at without opening it first).

## Phase 5 — Cleanup (passive, runs via /close)

Artifacts strictly older than 30 days get swept by the `/close` skill's end-of-session ritual. Exemption is file-based (not reaction-based — reactions live in browser localStorage, not on disk):

- A `.keep` file in the artifact dir → that slug is pinned forever
- A `.keep` file in the parent `.html-answers/` dir → ALL slugs in that project are pinned
- A `feedback.md` file in the artifact dir → that slug is pinned (use this when you've exported feedback via 📋 Copy feedback)

You don't invoke this — it's a side-effect of `/close`. Just be aware:
- Pre-existing artifacts in the output path are at risk of cleanup after 30 days if not pinned.
- To preserve reactions across the TTL, **export feedback markdown** (📋 Copy feedback button) and save as `<slug>/feedback.md`. That's the durable record — the in-browser localStorage is NOT readable from disk.

## When NOT to use this skill

- The answer fits in 1-3 short sentences (just reply).
- The user explicitly asked for chat, code, or a different format ("just tell me", "in chat is fine").
- The task is a single-file code edit, debug, or shell operation.
- The user is mid-flow on something else and wants a quick aside.

When the user invokes the skill but the request doesn't actually fit it, say so once and offer the alternative: *"This looks like a one-line answer — reply in chat instead?"*

## Anti-patterns

- **Dumping raw conversation into HTML.** Synthesize. The artifact must add structural value over the chat reply, not duplicate it.
- **Generic AI aesthetics.** Inter, Roboto, Arial, Space Grotesk, purple-on-white gradients, candy-color CTAs. See `references/aesthetics.md` for the gravity-tag mapping table and the "never" list.
- **Skipping chrome-validate.** That's the gate. A render that hasn't been validated is not ready.
- **Auto-fixing chrome-validate failures without showing the user first.** Failures often surface real issues they want to weigh in on (a missing section, wrong content, broken link to a doc that doesn't exist yet). Show, then fix.
- **Deploying anywhere public by default.** This skill is local-only. If the user wants to share, they'll say so — push or deploy then. Don't auto-deploy.
- **Opening multiple files.** Always `open` exactly the `index.html`. The browser-spam pattern is annoying and breaks the user's flow.
- **Speculative additions.** Don't add charts, animations, or sections he didn't ask for. The template is reading-optimized for a reason.

## What this skill does NOT do

- Doesn't visualize raw data — that's `/dataviz` data mode.
- Doesn't render workflow diagrams — that's `/dataviz` process mode.
- Doesn't design new UI components — that's `/frontend-design`.
- Doesn't deploy or share publicly — local only.
- Doesn't replace the chat reply for trivial answers.

## Related skills

- `/dataviz` — data mode for JSON/CSV analysis; process mode for workflows/architectures. /respond-html delegates to it.
- `/frontend-design` — bold UI/component design. /respond-html borrows the aesthetics rules and delegates UI-mockup requests.
- `/chrome-validate` — the QA gate. Always runs after a render.
- `/dataviz` and `/respond-html` partially overlap on "process mode" vs "plan/proposal". Rule: if the content is **how something works** (steps, actors, branches) → `/dataviz` process. If the content is **what we should do** (options, recommendations, tradeoffs) → `/respond-html`.

## References

- `references/content-type-detection.md` — full decision tree, edge cases, examples.
- `references/response-artifact-spec.md` — section-by-section spec, snippet library (callouts, decision-blocks, tables), TOC generation.
- `references/aesthetics.md` — gravity-tag → font/accent mapping (8 rows), never-list, vibe check.
- `references/chrome-validate-handoff.md` — exact invocation, evidence-block format, what to do on FAIL.
- `templates/response-artifact.html` — the template skeleton. Read it once before your first render to understand the placeholder tokens.

## Known limitations (v0.3.1)

Documented gaps rather than silent failures — the user should know what's unsupported:

- **Delegation paths to /dataviz and /frontend-design are documented but lightly tested.** The response-artifact path (own template) is the well-trodden flow. When delegating, output-path management and aesthetic-rule propagation depend on the orchestrator (Claude) being careful — see Phase 1.
- **/frontend-design is a plugin skill without `user-invocable: true` or trigger phrases.** Invocation must go via the Skill tool with the exact name `frontend-design:frontend-design`. Output is typically code in chat or scaffolded frameworks, NOT a single HTML file at a known path — Phase 3 (`/chrome-validate`) doesn't apply cleanly when delegating to frontend-design.
- **`claude-in-chrome` MCP may reject `file://` URLs** depending on the harness version — the chrome-validate workaround is to spin up `python3 -m http.server` and validate against `http://localhost:<port>/`. See `references/chrome-validate-handoff.md`.
- **Reactions persist locally in browser localStorage** keyed by pathname. They survive reload but don't migrate across origins (file:// vs localhost), and don't survive across browsers/devices. There's no server-side persistence — the user's expected to react in a single session, copy as markdown, paste back to chat.
- **Aesthetics are deterministic by gravity tag.** Two strategy proposals look alike — by design. If you need variation within a gravity, it's a v0.4 ask.
- **The smoke-test artifact is regenerated from the template via `scripts/generate.py`** (added in v0.3). Manual edits to the smoke-test will be overwritten on the next regen — that's the point. To change the smoke-test's content, edit `scripts/smoke-test-content.json` (the content layer) instead.

## Why this skill exists

Chat replies for plans, approaches, audits, and dataviz frequently become walls of prose that lose structure. Reaching for HTML manually is friction. This skill makes the artifact the default for structure-shaped replies, with inline ✅/💬/❌ reactions per reactable unit so the user can mark up the artifact and redirect — and reuses existing skills (`/dataviz`, `/frontend-design`, `/chrome-validate`) instead of duplicating their work.

Inspired by Anthropic's "Imagine with Claude" pattern: when the reply has structure (sections, comparisons, decisions), the artifact compresses the read and amplifies the feedback loop.
