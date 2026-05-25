---
name: dataviz
description: "Visualizes any data OR process as a client-ready interactive HTML report. DATA MODE: statistician-grade EDA from JSON/CSV — profiles, extracts signals, picks the right viz library (Observable Plot, Plotly, Vega-Lite, Chart.js). PROCESS MODE: visualizes workflows, pipelines, architectures, state machines — picks Mermaid or rich custom HTML with step cards. Use on explicit /dataviz invocation, or when the user says 'visualize this data/process', 'analyze this dataset', 'diagram this workflow', 'show me how X works', 'create a chart', 'generate a dashboard'."
user-invocable: true
disable-model-invocation: false
---

# /dataviz — Statistician-Grade Data & Process Storytelling

Turns any JSON/CSV **or process description** into a client-ready, insight-driven interactive HTML report.

- **Data mode**: profiles data like a PhD statistician, extracts signals, picks the right viz library, renders a dashboard with insight-titles + annotations + trust signals.
- **Process mode**: captures steps/actors/branches/gates, picks Mermaid or custom step-card HTML, renders a diagram with the same storytelling rigor (BLUF, titles-as-findings, anti-pattern avoidance).

**This is not a chart dumper.** Explicit `/dataviz` invocation only. The skill is a 7-phase workflow that asks questions.

## Usage

```
/dataviz                                   # auto-detect: look for data/*.json|csv or process hints
/dataviz path/to/file.json                 # data mode (explicit file)
/dataviz path/to/steps.md                  # process mode (markdown with step structure)
/dataviz "how the order pipeline works"    # process mode (inline description)
/dataviz data: path/to/file.csv            # explicit data mode
/dataviz process: <description>            # explicit process mode
/dataviz ... theme:dark                    # dark variant
/dataviz ... output:/abs/path/index.html   # override default output path (for orchestrators)
```

## Invocation context (when called by another skill)

When invoked via the Skill tool by an orchestrator (e.g., `/respond-html`):

- **Prefix is authoritative** — see Mode detection below. The caller's classification wins; do not re-classify, do not fall through to "ambiguous → ask user".
- **`output:` arg overrides the default path** — when present, write to that absolute path verbatim. Skip the `data/{slug}_{hash6}_report.html` derivation and the cwd safety check (the caller owns path policy). Create parent dirs if missing.
- **Suppress Phase 6 `open`** — if `output:` was set OR an orchestrator context is detected, return the absolute path and let the caller handle `open`. Prevents double-open when /respond-html Phase 4 opens the file too.

References for every phase:
- `references/eda-workflow.md` — statistical methodology (data mode)
- `references/viz-libraries.md` — library picker, CDN URLs, per-chart configs (data mode)
- `references/process-diagrams.md` — diagram-type picker, Mermaid cheatsheet, step-card patterns (process mode)
- `references/storytelling.md` — BLUF, titles-as-findings, annotations, anti-patterns (**both modes**)
- `references/html-template.html` — data-mode skeleton (light + dark themes)
- `references/process-template.html` — process-mode skeleton (Mermaid + step cards + swimlanes)

## Mode detection (FIRST THING in Phase 0)

Before anything else, classify the input. **Evaluate top-down — first match wins. An explicit `data:` / `process:` prefix is authoritative and bypasses everything below it (including the "ambiguous → ask" row).**

| Signal | Mode |
|--------|------|
| User prefix `data:` (any case, whitespace tolerated) | **data** (authoritative — skip ambiguity ask, override file-ext signal if it conflicts) |
| User prefix `process:` (any case, whitespace tolerated) | **process** (authoritative — same) |
| `.json`, `.jsonl`, `.csv`, `.tsv` file with tabular/record shape | **data** |
| User says "process", "workflow", "flow", "pipeline", "architecture", "how X works", "diagram", "steps" | **process** |
| Input is a markdown doc with step-by-step bullets, numbered list, or "1. X → 2. Y" shape | **process** |
| Input is prose describing a system or sequence of steps | **process** |
| Ambiguous | **ask the user** (but never when a prefix is present — see top two rows) |

**Data mode** runs Phases 1–6 as specified below.
**Process mode** swaps Phases 1–2 for a process-capture pass and swaps Phase 5 rendering. Phases 3 (review gate), 4 (library pick), 6 (deliver), and the storytelling rules apply to **both modes**.

## Process-mode Phases 1–2 (replace EDA)

**Phase 1P — Capture the process.** From the user's description or source doc, extract:
- **Steps**: ordered list (or graph of nodes). Number each.
- **Actors/systems**: who/what performs each step (person role, service, queue, data store).
- **Inputs/outputs**: what triggers each step; what it produces.
- **Branches**: decision points and their conditions.
- **Failure paths**: what happens when a step fails or is rejected.
- **Quality gates**: checkpoints, approvals, manual reviews.
- **Code/doc references**: where each step lives (file paths, workflow IDs, dashboard URLs) if known.
- **Status / known pain points**: OK / warn / fail / intermittent per step (if the user flags any).

**Phase 2P — Analyze the process.** Run the captured process through the analysis checklist in `references/process-diagrams.md` § Process analysis. Look for:
- **Bottlenecks**: which step gates throughput, where volume leaks
- **Fragility**: single points of failure, steps without retry/fallback, silent failures, unmodeled failure paths
- **Handoff gaps**: context-loss between actors, async with no SLA, ambiguous ownership
- **Automation opportunities**: manual-deterministic steps, deduplication candidates
- **Gate/observability gaps**: risky steps without quality gate, steps without metrics/logs
- **Redundancy & drift**: duplicated work, code-vs-docs-vs-tribal-knowledge divergence
- **Compliance**: PII without consent gate, money without dual control, missing audit trails
- **Hidden segmentation (Simpson's equivalent)**: aggregate success rate hiding which sub-population fails — always ask "broken down by what dimension might this hide a problem?"

Rank findings by **impact × likelihood × surprise**. These drive the BLUF, step-card status badges (`data-status="ok|warn|fail|gate|info"`), and the methodology section.

**Phase 2P.5 — Pick the diagram shape.** Using `references/process-diagrams.md`:
- Linear steps → step cards OR Mermaid `flowchart TD`
- Multi-actor over time → Mermaid `sequenceDiagram`
- State transitions → Mermaid `stateDiagram-v2`
- Cross-functional / swimlanes → custom swimlane layout
- Entity relationships → Mermaid `erDiagram`
- Timeline with dependencies → Mermaid `gantt`
- User journey → Mermaid `journey`
- Flow volume between states → Plotly Sankey (reuse data-mode lib)
- Architecture → Mermaid `flowchart LR` with subgraphs, OR custom HTML with icon grid

Pass to Phase 3 review with the proposed diagram type + a draft BLUF: *"This diagram shows [what], and the takeaway is [key finding]."*

## Process-mode Phase 4 (library pick)

```
if diagram type ∈ {flowchart, sequence, state, ER, gantt, journey} AND no rich per-step detail:
    libs = {"mermaid"}
elif diagram needs status badges / code refs / click-to-drill / quality-gate indicators:
    libs = {"custom-html"}   # step-card layout, no chart lib
elif diagram is transitions-between-states / funnel / flow volume:
    libs = {"plotly"}        # Sankey
elif diagram is auto-layout of arbitrary graph with 20+ nodes:
    libs = {"d3", "dagre-d3"}

Optional add-on: Tabulator for a step-detail table below the diagram.
Max 2 libs per process report.
```

**Default: Mermaid for most cases.** Custom HTML step-cards win when per-step richness justifies it (status, code refs, quality gates — like a workflow self-diagnostic for an internal pipeline).

Use `references/process-template.html` instead of `references/html-template.html` for rendering.

## Process-mode Phase 5 (render)

- Start from `references/process-template.html` (Mermaid CDN is pre-wired).
- Fill placeholders: `__TITLE__`, `__SUBTITLE__`, `__BLUF__`, `__SOURCE__`, `__ASOF__`.
- Replace `<!-- __PROCESS_CONTENT__ -->` with Mermaid blocks, step cards, swimlanes, or a mix.
- For each step card, fill `.step-title` (the insight — not just the step name), `.step-desc`, `.step-meta` (actor + code ref), `.step-status` (badge), and `data-status="ok|warn|fail|gate|info"`.
- Every arrow/transition in a Mermaid diagram MUST be labeled with the condition/event/trigger.
- Show failure paths explicitly.
- Methodology section: source of truth (code paths, docs), last verified date, inferred vs measured, known gaps.
- Horizontal-logic check: section titles + BLUF alone should read like the same story.

Process-mode Phase 6 (deliver) is identical to data mode — including the orchestrator-aware `open` rule (see data-mode Phase 6 below). Summarize, offer Vercel only on explicit ask.

---

## Data-mode workflow (original — used when mode == data)

## Phase 0 — Setup + Input Validation

**File handling:**
- Resolve source: file path or inline. Support `.json`, `.jsonl`, `.csv`, `.tsv`.
- UTF-8 BOM sniff; handle Latin-1 and Czech diacritics (`č ř š ž ý á é í ó ú ů`).
- **CSV parser: Papa Parse 5.5.3**. Never naive `split(',')` — it breaks on quoted commas and newlines-in-fields.
- **JSON nesting**: detect max depth. Depth > 1 → prompt user: *"This JSON has nested objects (e.g., `line_items[]`). Flatten with dotted keys + array-length columns? Or pick one nested path to analyze?"* Wait for answer.
- **JSONL heterogeneity**: union schema across lines, null-fill missing keys. If >20% of lines are missing any given key, warn in the profile.

**Size handling (gates):**
- `rows == 0` → bail: *"Dataset is empty, nothing to analyze."*
- `rows == 1` → degraded univariate only (SD and Pearson undefined; skip).
- `cols == 1` → univariate only, skip Phase 2 bivariate.
- `rows > 50,000` → auto-aggregate for viz (pre-bin histograms, sample scatters at n=5,000, group time series). Full data still used for Tabulator (virtual DOM).
- `rows > 500,000` → refuse interactive mode; offer summary-only report.

**Output path:**
- **`output:<abs-path>` arg present (orchestrator invocation)** → write there verbatim, create parent dirs if missing, skip the cwd safety check below. Caller owns path policy.
- **Default** (no `output:` arg): `data/{slug}_{hash6}_report.html` in cwd.
  - `slug` = lowercase kebab of source filename (no extension)
  - `hash6` = first 6 hex chars of SHA256(resolved absolute source path). For inline data, hash a canonical string of the first 256 chars.
- `cwd == ~/` or `/` → refuse: *"Run from a project directory."* (default-path mode only)
- `data/` directory: create if missing. If cwd is read-only, fall back to `$TMPDIR` with a visible warning.
- If output file already exists → ask for confirm before overwrite.

### Phase 1 — EDA Profile

Follow `references/eda-workflow.md` Phase 1. Cover:
- Structural inventory (rows, cols, dtypes declared vs inferred, key-candidates)
- **Dtype inference rules** (concrete, not guesswork):
  - Leading-zero numerics → string (postal codes, SKUs, order IDs)
  - Column name matches `(?i)(id|code|zip|postal|phone|sku|barcode|uuid|hash)` → force string
  - Cardinality > 0.95 × nrows AND looks numeric → likely identifier, exclude from stats
- Missingness classification (MCAR / MAR / MNAR), row+column null rates
  - 100% null columns: drop unconditionally, list in profile
  - 1 unique value: keep as "constant context", surface once in BLUF, exclude from charts
- Duplicates & near-duplicates
- Low-variance columns
- Hygiene (whitespace, case collisions, date-format mixing, impossible values)
- Outliers (IQR + z-score; Mahalanobis for multivariate)

Output: a **profile summary** — what this dataset IS, before any charts.

### Phase 2 — Univariate + Bivariate

Follow `references/eda-workflow.md` Phases 2 and 3. Cover:

**Univariate (per column):**
- Numeric: five-number summary, mean, SD, skew, kurtosis. Distribution shape (symmetric / right-skewed / bimodal / heavy-tailed / log-normal suspect / power-law suspect). Use Freedman–Diaconis for histogram bins.
- Categorical: frequency table, mode, cardinality bucket. If cardinality > 50, default to top-10 + "Other" for charts.
- Temporal: range, sampling rate, ACF hint.

**Bivariate:**
- Numeric × numeric: Pearson AND Spearman (divergence = non-linearity signal). Correlation matrix, flag |ρ| > 0.9.
- Categorical × numeric: grouped boxplots + Cohen's d or η² (effect size, not just p-value).
- Categorical × categorical: contingency + Cramér's V (not raw chi-square — sample-size inflated).
- Temporal × numeric: trend + ACF + changepoint.

**Simpson's paradox heuristic (mandatory):**
For every headline bivariate relationship, try every categorical column with cardinality 2–10 as a conditioner. Recompute within each group. **If direction flips between aggregate and within-group, lead the report with the paradox, not the aggregate.**

### Phase 3 — Signal Extraction + Review Gate (default required)

Rank findings by **effect size × reliability × surprise**. Draft:

- **BLUF** (one sentence): the single finding a journalist would lead with.
- **3–5 stat cards** (surprise-density rule — each number changes the reader's mental model).
- **Chart list**: each with a draft **insight-title** (not a label) and the library it will use.
- **Library pick**: run the picker in Phase 4 and state the result.
- **Caveats**: null rates, sample size per segment, selection-bias risk, Simpson's findings, multiple-comparisons inflation (if > 5 tests).

**Present to user. Wait for approval or adjustments before Phase 4.**

**Override path:** if the user expresses any explicit override intent — e.g. *"skip review"*, *"one-shot it"*, *"just do it"*, *"no review needed"*, *"skip the gate"*, or any case-insensitive variant — skill complies. Claude judges intent; the listed phrases are non-exhaustive examples, not a strict match list. When overridden, skill prefixes the report with: *"Report generated without Phase 3 review per request."*

### Phase 4 — Library Pick + Design

See `references/viz-libraries.md` for the picker + per-chart config snippets.

**Question-tag derivation (bridge from Phase 2 output to picker input):**
- Numeric column with non-trivial distribution → `distribution`
- >1 bivariate relationship worth comparing across groups → `small multiples` + `faceting`
- User asks to filter / zoom / brush → `linked brushing` / `cross-filtering`
- ≥5 numeric columns with pairwise correlations → `SPLOM`
- Data shape needs violin / Q-Q / Sankey / 3D / geo → corresponding specialist tag
- User wants a familiar dashboard → `simple KPI`, `familiar line/bar`
- Tabular detail at the bottom → `tabulator` (implicit, always on)

**Picker (returns a set):**

```
libs = {"tabulator"}
if any tag in {distribution, small multiples, faceting, EDA exploration, scatter+trend}:
    libs.add("observable-plot")
if any tag in {linked brushing, cross-filtering, SPLOM}:
    libs.add("vega-lite")
if any tag in {violin, Q-Q, sankey, 3D, geo}:
    libs.add("plotly")
if any tag in {simple KPI, familiar line/bar} and "observable-plot" not in libs:
    libs.add("chart.js")

# Hard cap: 3 chart libs + Tabulator.
# If exceeded: consolidate onto Observable Plot + one specialist.
```

**Observable Plot is the default for 95% of EDA reports.** Chart.js only wins when the user explicitly wants "familiar Excel-style" for a simple KPI row AND Plot is not already loaded.

**Theme**: light body + dark header by default; `theme:dark` opt-in toggles `body.dark` class in template.

**Palette**: Okabe-Ito for categorical (CUD-safe), ColorBrewer sequential/diverging for ordinal/signed. **Never rainbow/jet.**

### Phase 5 — Generate HTML

Start from `references/html-template.html`. Process:

1. **Fill CDN slot** (`<!-- __CDN_SLOT__ -->`) with the picked libraries. Use pinned URLs from `references/viz-libraries.md`.
2. **Replace placeholders**:
   - `__TITLE__` → report title (contains the BLUF as a sentence)
   - `__SUBTITLE__` → mechanism + context (n = X · as of Y · source Z)
   - `__BLUF__` → headline finding (one sentence)
   - `__SOURCE__`, `__ASOF__`, `__N__` → trust footer values
   - `/*__DATA__*/` → JSON.stringify of the data (or aggregated form if rows > 50k)
3. **Populate `#summaryCards`**: 3–5 cards. Each carries **value + delta + reference + caveat line with period + n**.
4. **Chart sections**: one per chart. Each has:
   - `.section-title` = the **insight** (not a label)
   - `.section-subtitle` = the **mechanism** (what drives it)
   - `.section-caption` = trust signals (source · as of · n)
   - Annotations where they earn their spot: arrow+label on the point that matters, shaded bands for target/alert zones, reference lines for benchmark/last-year/median, event markers on time series
5. **Methodology section** at bottom: null handling, filters, sample sizes per segment, Simpson findings, known caveats.
6. **Appendix Tabulator** at the very bottom: full row-level detail, default-sorted by the dimension most relevant to the headline.
7. **Observable Plot charts**: MUST use the `renderPlot(containerId, config)` helper from the template — it wraps in ResizeObserver for mobile responsiveness. Bare `Plot.plot(...)` will overflow on narrow viewports.
8. **Vega-Lite charts**: MUST use the `renderVegaLite(containerId, spec)` helper — it wraps in try/catch and logs `view.warnings()` (otherwise invalid specs fail silently).
9. **CDN fallback banner** is already wired in the template `<head>` — do not remove the listener.
10. **Horizontal-logic check** (before delivering): scan only the section titles and the BLUF. If they read like the same story, ship. If not, rewrite titles until they do.

### Phase 6 — Deliver

- **Stand-alone invocation**: `open {output_path}` in default browser.
- **Orchestrator invocation** (`output:` arg was set, or skill was invoked via Skill tool by another skill): **skip `open`** — return the absolute path string and let the orchestrator handle opening + downstream gates (e.g., /respond-html's Phase 3 chrome-validate + Phase 4 open). Prevents double-open and lets the caller chain its own QA.
- Summarize: libraries used, chart count, output path, the top 3 findings surfaced.
- Offer Vercel deploy only on explicit ask: *"Want me to deploy this to Vercel?"* — do not auto-deploy.

Process-mode Phase 6 (deliver) follows the same orchestrator-aware rule above.

## 6 Hard Rules (non-negotiable on auto-pick; yield with one-line warning on explicit user override)

1. **No dual-axis charts.** Use stacked small multiples instead. *Override allowed on explicit request.*
2. **Bars start at zero by default.** *Narrow-range numeric exception*: conversion-rate-style data (e.g. 2.0%–2.4%) may use a broken-axis indicator **with an explicit caption note** stating the truncation.
3. **No pies with >5 slices.** Use sorted horizontal bar. *Override allowed on explicit request.*
4. **Colorblind-safe palettes only** (Okabe-Ito or ColorBrewer). **Never rainbow/jet** (they imply false ordinal structure and fail for ~8% of readers).
5. **Every chart earns its spot.** Insight-title (not label) + trust signals (source · as of · n). No chart-for-every-column syndrome — if a chart has no finding worth writing in the title, move it to the appendix or drop it.
6. **Max 3 chart libraries + Tabulator per report.** Consolidate onto Observable Plot when possible.

Auto-pick (Phase 4) never proposes a violation. Explicit user override (in Phase 3 review) triggers a one-line warning + generates anyway — the skill serves the user, not the other way around.

## Anti-patterns the skill actively avoids

- "Revenue by month" titles → always rewrite as the finding ("Revenue grew 43% in Q4, driven by new DACH customers")
- "6 meaningless counters" stat cards → use the surprise-density rule (see `references/storytelling.md`)
- Kitchen-sink filters (filter by 30 columns) → filters only where the filter-space is meaningful
- Legend far from the data it explains → inline legends where possible
- Truncated bar Y-axis (except narrow-range exception with caption note)
- 3D charts, ever
- Over-decimaled numbers (3.14159% when 3.1% is fine)

## Safety

- **Never auto-deploy** to Vercel. Always ask first.
- **Never overwrite** an existing output file without confirming.
- **Never silently drop** columns — list everything excluded in the methodology section.
- **Never fabricate** numbers in stat cards — every value must be computable from DATA.
- **Never substitute** Czech-less fonts when diacritics are present — Inter + system-ui is the floor.

## Verification (self-check before delivery)

Before calling the report done, confirm:

- [ ] Every chart has an insight-title (not a label)
- [ ] Every stat card has value + delta + reference + n + period
- [ ] Trust footer present with source + as-of + n
- [ ] Methodology section lists null handling, exclusions, and any Simpson findings
- [ ] Horizontal-logic holds: section titles + BLUF read as the same story
- [ ] Zero anti-pattern charts (unless user explicitly overrode in Phase 3)
- [ ] Czech diacritics render correctly
- [ ] Mobile viewport (400px) doesn't overflow — ResizeObserver wired on all Plot charts
- [ ] `view.warnings()` empty on all Vega-Lite charts
- [ ] CDN failure listener present in `<head>`
