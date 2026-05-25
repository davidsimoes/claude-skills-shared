# process-diagrams.md — Visualizing Processes, Workflows, and Architectures

For when the input is a **process** (steps, flow, state machine, architecture) rather than tabular data. Same design language as `html-template.html`, same storytelling principles (insight-titles, annotations, trust signals) — but the rendering vocabulary is different: step cards, swimlanes, graph edges, state transitions.

## When process mode fires (vs data mode)

Mode detection in Phase 0:

| Signal | Mode |
|--------|------|
| `.json`, `.jsonl`, `.csv`, `.tsv` file with tabular/record shape | data |
| User says "process", "workflow", "flow", "pipeline", "architecture", "how X works", "diagram this" | process |
| Input is a markdown doc with step-by-step bullets, numbered list, or "1. X → 2. Y" shape | process |
| Input is prose describing a system | process |
| Ambiguous | ask user |

Process mode **reuses** Phase 3 review gate, Phase 6 delivery, CDN-fallback, design tokens, storytelling rules. It swaps Phase 1–2 (EDA → process capture) and Phase 5 (chart rendering → diagram rendering).

## Diagram-type picker

Pick based on the shape of the thing being described:

| Shape | Diagram | Notes |
|-------|---------|-------|
| Linear sequence of steps | **Step-card flow** (custom HTML) or **Mermaid flowchart TD** | Step cards when steps need rich detail (status, actors, code refs); Mermaid when pure shape matters |
| Branching decision tree | **Mermaid flowchart** with decision diamonds | Mermaid is cheapest |
| Multi-actor interaction over time | **Mermaid sequenceDiagram** | Best for API calls, handoffs, message passing |
| System with states and transitions | **Mermaid stateDiagram-v2** | e.g. deal stages, order lifecycle |
| Cross-functional / multi-team flow | **Swimlane layout** (custom HTML) | Mermaid's swimlane support is weak; custom is cleaner |
| Data model / entity relationships | **Mermaid erDiagram** | |
| Project timeline with dependencies | **Mermaid gantt** | |
| User journey with pain points | **Mermaid journey** | |
| Architecture (services, data stores, queues) | **Mermaid flowchart LR** with subgraphs OR custom HTML with icon grid | |
| Transitions / volume between states | **Plotly Sankey** (reuse data-mode lib) | e.g. funnel, lead stage transitions |

## Library picker for process mode

```
if diagram is {flowchart, sequence, state, ER, gantt, journey} AND no rich per-step detail needed:
    → Mermaid (cheapest, universal, self-contained via CDN)
elif diagram needs status badges / code refs / click-to-drill / quality-gate indicators:
    → Custom HTML (step-card layout + connectors, no chart lib)
elif diagram is {transitions between states, funnel, flow volume}:
    → Plotly Sankey (already in data-mode library set)
elif diagram is auto-layout of arbitrary graph with 20+ nodes:
    → D3 + dagre-d3 (last resort, verbose)

Max 2 libs per report: Mermaid + (optional) Tabulator for a step-detail table below.
```

**Default: Mermaid for most cases.** Custom HTML only when the richness of per-step detail justifies it (think: a workflow self-diagnostic with quality gates + links to source files).

## CDN — Mermaid

```
Mermaid 10.9.1: https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js
```

Init pattern:
```html
<script src="https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js"></script>
<script>
  mermaid.initialize({
    startOnLoad: true,
    theme: 'default',   // or 'dark' in process-template dark mode
    flowchart: { curve: 'basis', padding: 20 },
    themeVariables: {
      fontFamily: 'Inter, system-ui, sans-serif',
      primaryColor: '#2563eb',
      primaryTextColor: '#fff',
      lineColor: '#64748b',
      secondaryColor: '#f1f5f9',
      tertiaryColor: '#e2e8f0'
    }
  });
</script>
```

Each diagram lives in `<div class="mermaid">...</div>` — Mermaid auto-renders on load.

## Mermaid syntax cheatsheet (per type)

### Flowchart (TD top-down / LR left-right)
```
flowchart TD
  Start([Start]) --> Check{Valid?}
  Check -->|yes| Process[Process it]
  Check -->|no| Reject[Reject]
  Process --> End([Done])
  Reject --> End
```

### Sequence diagram
```
sequenceDiagram
  actor User
  participant FE as Frontend
  participant API
  participant DB
  User->>FE: Click submit
  FE->>API: POST /order
  API->>DB: INSERT order
  DB-->>API: ok
  API-->>FE: 201 Created
  FE-->>User: Confirmation
```

### State diagram
```
stateDiagram-v2
  [*] --> New
  New --> Qualified: MQL criteria met
  Qualified --> Proposal: Discovery done
  Proposal --> Won: Signed
  Proposal --> Lost: Rejected
  Won --> [*]
  Lost --> [*]
```

### ER diagram
```
erDiagram
  DEAL ||--o{ CONTACT : has
  DEAL }o--|| COMPANY : for
  DEAL {
    int id PK
    string stage
    int amount
  }
```

### Gantt
```
gantt
  title Launch plan
  dateFormat YYYY-MM-DD
  section Phase 1
  Research     :a1, 2026-04-01, 14d
  Spec         :a2, after a1, 7d
  section Phase 2
  Build        :b1, after a2, 21d
```

## Custom HTML step-card pattern (for rich process docs)

Used when per-step detail earns its space: status badge, actor, code ref, quality gate, link to source. A typical use case: a workflow self-diagnostic for an internal pipeline.

Component structure (styles inlined in `process-template.html`):

```html
<div class="process">
  <div class="step" data-status="ok">
    <div class="step-number">1</div>
    <div class="step-body">
      <h3 class="step-title">Lead enters CRM</h3>
      <p class="step-desc">Form submit on /kontakt triggers webhook → HubSpot deal creation.</p>
      <div class="step-meta">
        <span class="step-actor">HubSpot workflow</span>
        <span class="step-code"><code>n8n/lead-webhook.json</code></span>
      </div>
    </div>
    <div class="step-status badge-ok">OK</div>
  </div>
  <div class="step-connector">↓</div>

  <div class="step" data-status="warn">
    <div class="step-number">2</div>
    <div class="step-body">
      <h3 class="step-title">Enrichment runs</h3>
      <p class="step-desc">External data-provider lookup → writes revenue + platform + agency fields.</p>
      <div class="step-meta">
        <span class="step-actor">n8n workflow</span>
        <span class="step-code"><code>enrichment.yaml</code></span>
      </div>
    </div>
    <div class="step-status badge-warn">Intermittent</div>
  </div>
  <div class="step-connector">↓</div>

  <!-- …etc -->
</div>
```

Status badges: `badge-ok` (green), `badge-warn` (amber), `badge-fail` (red), `badge-info` (blue), `badge-gate` (purple for quality gates).

Branching in custom HTML — use nested `.process` with a `.branch-label`:
```html
<div class="branch">
  <div class="branch-label">If qualified</div>
  <div class="process"> <!-- nested steps --> </div>
</div>
<div class="branch">
  <div class="branch-label">If disqualified</div>
  <div class="process"> <!-- nested steps --> </div>
</div>
```

## Process analysis (signal extraction for processes)

The equivalent of EDA signal extraction in data mode. After capturing the process (Phase 1P), run it through this checklist and rank findings by **impact × likelihood × surprise**. These findings drive the BLUF, the step-card status badges, and the methodology section.

**Bottlenecks & flow**
- Which step has the longest latency / queue time?
- Which step gates everything downstream?
- Where does volume drop off (funnel leak)? Quantify if data available.

**Failure modes & fragility**
- Single points of failure — steps with no retry, no fallback, no circuit breaker
- Known-flaky dependencies (external API, 3rd-party service, manual handoff)
- Failure paths that aren't modeled — "what happens if step 7 fails?" — is there a path?
- Silent failures — steps that can fail without raising an alert

**Handoff gaps**
- Transitions between actors where context is lost (sales → CS without notes; system A → system B without ID mapping)
- Async handoffs with no SLA or follow-up
- Steps with ambiguous ownership ("who owns this?")

**Automation opportunities**
- Manual steps that are deterministic and rule-based (automation candidates)
- Steps done in multiple places that could be deduplicated into one service
- Approvals that could be conditional (only require human on edge cases)

**Quality gates & observability**
- Risky steps with no quality gate
- Steps without logging / metrics / dashboards
- Gates that are present but never alert (dead checks)

**Redundancy & drift**
- Two steps doing similar work with different data
- Process exists in code AND in docs AND in someone's head — which is authoritative?
- Steps that have diverged from original design (drift from spec)

**Compliance & audit**
- Steps touching PII without explicit consent gate
- Steps touching money without dual control
- Steps without an audit trail

**Hidden segmentation (Simpson's paradox for processes)**
- Aggregate success rate hides which segment fails — e.g. "90% of leads convert" but B2C leads convert at 95% and B2B at 40%
- Same step runs differently for different input types — which path is slower/riskier?
- Whenever the user gives an aggregate metric, ask: "broken down by what dimension might this hide a problem?"

**Observability & signals**
- Which steps have metrics that answer: is it working? how well? for whom?
- What would you need to see to detect a regression tomorrow?

## BLUF for a process (template)

*"This [process] has [N steps / M actors / K gates]. The headline finding is [X]. [Y] steps ([list]) account for [Z%] of [bad outcome]. Root cause: [mechanism]. Recommended fix: [action]."*

Example (lead-qualification pipeline):
*"The pipeline is 17 steps across 4 actors. 2 quality gates (steps 2 enrichment, 11 qualification) are intermittent and account for ~80% of stuck leads. Root cause: both call an external data-provider API without retry logic and silently fail on rate-limit. Fix: add exponential backoff + dead-letter queue on both."*

## Pitfalls to flag explicitly in the report

- **Correlation ≠ causation**: "step X is slow AND leads convert less" ≠ "step X causes low conversion"
- **Survivorship bias**: only measuring successful completions hides early-stage dropouts
- **Streetlight effect**: analyzing only the steps you have metrics for
- **Optimizing the wrong bottleneck**: local optimization without looking at end-to-end throughput
- **Normalized deviance**: known flakiness becomes "just how it works" — flag these, don't accept them
- **Missing the human step**: the longest latency is often the unmeasured human approval between automated steps

## Storytelling rules still apply

- **BLUF**: state what the diagram shows and the key takeaway. *"The lead-qualification pipeline is 17 steps across 4 actors; 2 quality gates are intermittent (steps 2, 11) and account for 80% of stuck leads."*
- **Section titles = insights, not labels**: `## Lead handoff gap between Enrichment and Qualification` beats `## Step 3`.
- **Annotations**: mark the steps that matter. Status badges carry weight.
- **Trust signals**: source (where the process lives in code/docs), as-of date, last verified.
- **Methodology**: what was measured vs inferred, known gaps, caveats.

## Anti-patterns (process mode)

- **Diagram-for-every-step** without connective insight — if a step has nothing notable, collapse it into a "steps 4–7: standard passthrough" note
- **Pure Mermaid when the insight is in the detail** — if you're annotating 5 nodes with paragraphs of prose, switch to custom HTML step cards
- **Swimlane overload** (>4 lanes) — usually means the process should be split
- **Unlabeled arrows** — every edge should say WHY the transition happens (condition, event, trigger)
- **Forgotten failure paths** — always show where things can fail and what happens next
