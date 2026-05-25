# Content-Type Detection

Decision tree for routing the user's request to the right rendering path.

## Why this matters

The skill is an orchestrator. Picking the wrong route either duplicates work (`/dataviz` already handles process diagrams beautifully — don't re-implement them) or under-delivers (the response-artifact template is for reading; a data dashboard wants `/dataviz`).

## The tree (apply in order, first match wins)

### Q1. Is the input tabular data?

Signals: file extension `.json`, `.jsonl`, `.csv`, `.tsv`; user pasted an array of records; user says "analyze this data", "EDA", "profile this dataset", "what's in this CSV", "find patterns in this data".

**Yes** → `/dataviz` (data mode). Stop here.

### Q2. Is the content a process / workflow / system to diagram?

Signals: words like "workflow", "pipeline", "flow", "architecture", "state machine", "how X works", "diagram", "steps in", "stages of"; user describes ordered steps with actors and branches; input is a markdown doc with numbered steps; the natural output is a diagram, not prose.

**Yes** → `/dataviz` (process mode). Stop here.

### Q3. Is the user asking for a UI / component / app interface?

Signals: "mock up", "design a screen for", "build a component", "what would this page look like", "prototype the UI for", "show me an interface for"; the output is something interactive a user clicks/types into; aesthetics and interaction matter more than reading flow.

**Yes** → `/frontend-design` for aesthetic principles + the response-artifact template if the deliverable is *also* a doc-style artifact (e.g., "mock up X with an explanation of why"). For pure mockups (no explanatory wrapping), delegate fully to `/frontend-design`.

### Q4. Is it a plan?

Signals: "show me a plan for", "how should I approach", "roadmap for", "what's the plan", "steps to do X", "phased approach", "rollout for".

**Yes** → response-artifact template. Plan-shaped: phases as H2 sections, decision-blocks for branching choices, BLUF = "the recommended path is X because Y."

### Q5. Is it a proposal / recommendation?

Signals: "what should I do about", "recommend an approach", "propose X", "your take on", "what would you do", "advice on".

**Yes** → response-artifact template. Proposal-shaped: BLUF = the recommendation, body = rationale + alternatives + tradeoffs + risks.

### Q6. Is it a comparison?

Signals: "compare A vs B", "which is better, X or Y", "tradeoffs of X vs Y", "X or Y for our case", "evaluate these options".

**Yes** → response-artifact template. Comparison-shaped: comparison table near the top, callouts for non-obvious tradeoffs, decision-block at the end with the recommendation.

### Q7. Is it an audit / review?

Signals: "review this", "audit X", "what's wrong with Y", "is this safe", "check this approach", "find issues in".

**Yes** → response-artifact template. Audit-shaped: BLUF = severity summary, sections grouped by severity (Critical → High → Medium → Low) or by area, callouts for risks.

### Q8. Is it structured analysis / a recommendation memo?

Signals: "explain X with structure", "break down Y", "give me a structured take on Z", "memo on X", or any request where the answer naturally has 3+ distinct sections.

**Yes** → response-artifact template. The default fallback when the response is too structured for chat but doesn't fit any other route.

### Strategic gate hook

If the matched route is `response-artifact` AND the content type is **plan / proposal / audit / recommendation**, the skill's Phase 2.5 (see `SKILL.md`) fires `/fresh-eyes` on the rendered output before the chrome-validate gate. This is automatic — content-type-detection just classifies; SKILL.md's Phase 2.5 decides whether to fire the audit. Visualization routes (`/dataviz` data + process, `/frontend-design`) and gravity `light` skip the strategic gate.

### Otherwise

If none of the above matched cleanly:

1. State the classification confidence: *"This looks like a comparison-with-data — leaning response-artifact (template), but `/dataviz` would handle it too."*
2. **Confidence test (operational)**: high confidence = "you can cite 2+ specific signals from the tree above that match" (file extensions, explicit prefix words, file paths, presence of step-numbering, etc.). Low confidence = "you're inferring from tone or a single ambiguous keyword." High → state classification, default to response-artifact, proceed (no AskUserQuestion). Low → ask David (single AskUserQuestion, 2-3 options). This resolves the apparent contradiction between Q8's "ambiguous → ask" and the "When in doubt" edge case below.

## Edge cases & overlaps

### Process diagram vs plan

Both describe "how something happens." The difference:

- **Process** answers *how does this work?* — current state, factual, descriptive. Steps + actors + flows.
- **Plan** answers *what should we do?* — future state, evaluative, prescriptive. Options + recommendation + tradeoffs.

If both are present (a current-state process diagram AND a plan to change it), do TWO artifacts: `/dataviz` process for the diagram, response-artifact for the plan. Cross-link them.

### Data dashboard vs audit-with-data

- **Data dashboard** (→ `/dataviz`): the chart IS the answer. Reader scrolls through visualizations.
- **Audit with data** (→ response-artifact): the findings are the answer. Charts are supporting evidence inside callouts.

If the deliverable is "tell me what's wrong + show the evidence", it's an audit; charts go inside response-artifact sections.

### Pure mockup vs annotated mockup

- **Pure mockup** (→ `/frontend-design` only): just the interface, no surrounding doc.
- **Annotated mockup** (→ this skill + delegate to `/frontend-design` for the interface fragment): mockup embedded in a doc explaining rationale, decisions, alternatives.

### Compound requests ("plan AND visualize data" / "audit AND mock up the fix")

When the request contains 2+ Q's matching strongly (e.g., "show me a plan for X with a dashboard of current data" → Q4 plan + Q1 data), don't silently pick one. Surface the compound to David via AskUserQuestion: "I see two artifacts here — a plan (response-artifact) and a data dashboard (/dataviz). Want both? One? Combined into a single response-artifact with embedded charts?" The default lean is to produce both and cross-link, but check first.

### When in doubt

Default to response-artifact when your confidence is ≥70% — it handles the widest range and the cost of a wrong choice is a re-render, not a deal lost. When confidence is <70%, ask David (see "Otherwise" above).

## Announce the classification

Always say one line about what you classified the request as and which template you're using, before rendering. Example:

> "Classifying as a **proposal** with 2 options + 1 recommendation → response-artifact template. Will render then run `/chrome-validate all`."
