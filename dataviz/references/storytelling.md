# storytelling.md — Data-Driven HTML Reports That Deliver Insights

Transplantable reference. What separates a **client-ready report** from a **dashboard dump**: the report does the thinking *for* the reader. The dashboard makes them do it.

## 1. Structure archetypes

- **BLUF (Bottom Line Up Front).** The headline finding is the first thing the reader sees — above any chart. If they read nothing else, they walk away with the point. Cole Knaflic's "horizontal logic" rule: a reader who scans *only* your section titles should get the same story as the exec summary.
- **Inverted pyramid.** Exec summary (3–5 findings, each ≤ 1 sentence) → key findings with supporting chart each → methodology → appendix/raw tables. Never bury the lede in a trends section.
- **One-pager** when the audience is a decision-maker who wants a verdict (a single chart + 3 bullets + "what to do next"). **Multi-section** when you must defend the finding or the audience will implement from the doc (technical teams, audit trails).

## 2. Stat cards / KPI row

**Surprise-density rule:** a stat card earns its spot only if the number changes the reader's mental model. "Total sessions: 184,322" doesn't. "Mobile conversion dropped to 0.9% — half of desktop" does.

Every card carries four layers: **value + context + direction + sub-label**. A bare number is a dashboard artefact.

**Full example:**
```
┌─────────────────────────────────┐
│  Mobile conversion rate         │  ← sub-label (what + scope)
│                                 │
│  0.9%      ▼ 0.4pp              │  ← value + delta
│                                 │
│  ▁▂▃▂▁▁▁  vs. 1.8% benchmark   │  ← sparkline + reference
│                                 │
│  Industry median: 2.1%          │  ← benchmark line
│  Last 30 days · n = 12,430      │  ← caveat line (period + sample)
└─────────────────────────────────┘
```

Avoid the "6 meaningless counters" anti-pattern (Sessions, Users, Pageviews, Bounce, AvgTime, Events). Pick **3–5 cards that each tell a different story**; if two cards move together, drop one.

## 3. Chart titles as insight containers

Every chart title is a **one-sentence finding**, not a label. Subtitle carries the *mechanism*. Caption handles caveats.

| Before (label) | After (insight) |
|---|---|
| "Revenue by month" | "Revenue grew 43% in Q4 — driven entirely by new DACH customers" |
| "Traffic sources" | "Organic now drives 62% of sessions, up from 41% — paid search is no longer the main channel" |
| "Conversion funnel" | "Cart abandonment doubled after the April checkout redesign" |
| "Top products" | "Three SKUs account for 71% of revenue — concentration risk is rising" |
| "Page speed by device" | "Mobile LCP is 4.2s — 2× the Shopify median and the likely cause of the conversion drop above" |

## 4. Annotation layer

A chart without annotations asks the reader to find the point. A chart *with* annotations tells them.

- **Arrow + label** on the exact data point that matters ("launch", "price change", "outage")
- **Shaded bands** for target zones (green) and alert zones (red)
- **Event markers** on time series (launches, outages, Black Friday, algo updates)
- **Reference lines** for benchmark, last-year same-period, median, target

Technical note: annotation layers render **above** grid lines, **below** data marks. Chart libraries that invert this (axis-on-top) fight the reader.

## 5. Color strategy

Reports are not dashboards — restraint wins.

- **One neutral** (slate/gray 600 for text, gray 200 for grid)
- **One hero** color for the primary metric (e.g., brand blue)
- **One accent** for highlights / the one thing you want noticed
- **Red** reserved for alerts/negatives; **green** for positives — but always **colorblind-safe** (Okabe-Ito red `#D55E00` + green `#009E73`, never pure `#F00`/`#0F0`)
- Categorical: **Okabe-Ito** (8 colors, CUD-safe) or **ColorBrewer Set2/Set3**
- **Never** rainbow/jet colormaps — they imply false ordinal structure and fail for ~8% of readers

## 6. Narrative flow

- **TL;DR callout** at top (blockquote or highlighted box)
- **Progressive disclosure:** summary → chart → "What this means" paragraph *between* charts → raw table at bottom
- Interpretive text lives **next to** the chart it explains, not collected in a final paragraph
- **Anchor links** for any report > 3 screens; sticky nav for > 6 sections
- Write the section title as a finding: `## Cart abandonment doubled after April` beats `## Checkout analysis`

## 7. Interactivity with a point

Filters only where the filter-space is meaningful (segment, time range, device). Not "filter by any of 30 columns" — that transfers the analytical burden back to the reader.

- **Hover tooltips** carry detail axes can't (exact value, n, delta vs prior)
- **Sortable tables** default-sorted by the interesting dimension (not alphabetical)
- **Default state is the answer**; interactivity is for "show me why"

## 8. Trust signals

Every chart shows: **data source + as-of date + sample size (n)**. Methodology section names null handling, filters, exclusions. Estimates carry confidence bands or ± ranges. A report without these reads as "trust me" — clients don't.

## 9. Top 5 anti-patterns

1. **Dual-axis charts** — readers can't tell which axis a line belongs to; correlations look causal. Use two stacked small-multiples instead.
2. **Truncated Y-axis on bar charts** — a 2% change looks like 50%. Bar charts must start at zero. (Line charts can truncate, bars cannot.)
3. **Pie charts with > 5 slices** — humans can't compare angles. Use a sorted horizontal bar chart.
4. **Rainbow/jet colormaps** — imply ordered structure where none exists and break for colorblind readers.
5. **Chart-for-every-column syndrome** — if a chart has no finding worth writing in the title, it doesn't belong in the report. Move it to the appendix or delete it.

## Sources
- Cole Nussbaumer Knaflic — *Storytelling with Data* (horizontal logic, insight-as-title)
- FT Visual Vocabulary (chart-type selection, annotation practice)
- John Burn-Murdoch (FT) — "charts change minds" / data-design-words balance
- Okabe-Ito palette (CUD accessibility)
- ColorBrewer (Set2/Set3 categorical)
- The Pudding, IEEE VIS annotation research (ChartAccent, 2017)
