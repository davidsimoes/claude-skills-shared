# viz-libraries.md — Library Picker, CDN URLs, Per-Chart Configs

Single source of truth for picking a viz library and configuring each chart type. Values verified Apr 2026.

## Library picker (Phase 4)

Returns a **set** of libraries based on question tags derived from EDA findings + user's stated goal.

Question-tag derivation (bridge from Phase 2 output to Phase 4 input):
- Numeric column with non-trivial distribution (skew, bimodal, heavy-tail) → `distribution`
- >1 bivariate relationship worth comparing across groups → `small multiples` + `faceting`
- User explicitly asks to filter / zoom / brush → `linked brushing` / `cross-filtering`
- ≥5 numeric columns with pairwise correlations → `SPLOM`
- Data shape needs violin / Q-Q / Sankey / 3D / geo → corresponding specialist tag
- User says "show me the numbers" or wants a familiar dashboard → `simple KPI`, `familiar line/bar`
- Tabular detail at the bottom → `tabulator` (implicit, always on)

Picker (pseudocode — Claude applies in prose):

```
libs = {"tabulator"}  # always, for tabular detail at bottom of report

if any(q in {"distribution", "small multiples", "faceting", "EDA exploration", "scatter+trend"} for q in questions):
    libs.add("observable-plot")
if any(q in {"linked brushing", "cross-filtering", "SPLOM"} for q in questions):
    libs.add("vega-lite")
if any(q in {"violin", "Q-Q", "sankey", "3D", "geo"} for q in questions):
    libs.add("plotly")
if any(q in {"simple KPI", "familiar line/bar"} for q in questions) and "observable-plot" not in libs:
    libs.add("chart.js")

# Hard cap: 3 chart libs + Tabulator.
# If len(libs) > 4, Claude MUST consolidate: prefer Observable Plot for anything it covers,
# keep only one specialist (Plotly OR Vega-Lite, whichever the user's explicit request needs).
```

**Observable Plot is the default** for 95% of EDA reports. Chart.js only wins when the user explicitly wants "familiar Excel-style" for a simple KPI row AND Plot is not already loaded.

## Statistical feature matrix

| Feature | Chart.js 4 | Plotly.js | Observable Plot | Vega-Lite 6 |
|---------|-----------|-----------|-----------------|-------------|
| Histogram (bin choice) | plugin | native | native (`Bin` transform, Freedman–Diaconis, Scott, Sturges) | native |
| Box plot | plugin (sgratzl, maintained) | native | native (`Box` mark) | native |
| Violin | plugin (same) | native | via density | native |
| Q-Q plot | manual | scatter + manual | manual | manual |
| ECDF | manual | native (`histnorm: cumulative`) | manual | native (`aggregate: ecdf`) |
| Error bars / CI bands | plugin | native | `Rule` + `AreaY` band | native |
| Faceting / small multiples | no | via subplots | **first-class (`fx`/`fy`)** | first-class |
| Linear regression / LOESS | no | native (trendline) | native (`linearRegressionY`, `Loess`) | via transform |
| Scatter matrix / SPLOM | no | native | manual | native (`repeat`) |
| Annotations (arrows/callouts) | plugin | native | `Text`/`Arrow` marks | native |
| Brushing / cross-filter | no | native | `Pointer` interaction | **native selections** |
| Zoom/pan | plugin | native | limited | native |

## Bundle sizes (gzipped)

- Chart.js 4.5.1: ~60 KB gz core (add ~10–30 KB per stat plugin)
- Observable Plot 0.6.17: ~80 KB gz (includes D3 subset)
- vega 5.33.1 + vega-lite 6.4.2 + vega-embed 6.29.0 stack: ~350 KB gz combined
- Plotly cartesian-dist-min 3.5.0: ~463 KB gz
- Tabulator 6.4.0: ~90 KB gz
- Papa Parse 5.5.3: ~16 KB gz

## CDN URLs (pinned exact, all HTTP 200 verified)

```
Observable Plot: https://cdn.jsdelivr.net/npm/@observablehq/plot@0.6.17/dist/plot.umd.min.js
Vega stack:      https://cdn.jsdelivr.net/npm/vega@5.33.1
                 https://cdn.jsdelivr.net/npm/vega-lite@6.4.2
                 https://cdn.jsdelivr.net/npm/vega-embed@6.29.0
Plotly cartesian: https://cdn.jsdelivr.net/npm/plotly.js-cartesian-dist-min@3.5.0/plotly-cartesian.min.js
Chart.js:        https://cdn.jsdelivr.net/npm/chart.js@4.5.1
Tabulator JS:    https://unpkg.com/tabulator-tables@6.4.0/dist/js/tabulator.min.js
Tabulator CSS:   https://unpkg.com/tabulator-tables@6.4.0/dist/css/tabulator.min.css
Papa Parse:      https://cdn.jsdelivr.net/npm/papaparse@5.5.3/papaparse.min.js
Mermaid:         https://cdn.jsdelivr.net/npm/mermaid@10.9.1/dist/mermaid.min.js
```

**Mermaid is the process-mode default** — flowchart / sequence / state / ER / gantt / journey. See `references/process-diagrams.md` for per-diagram syntax and when to use Mermaid vs custom step-card HTML.

## Deprecation / risk flags

- **Vega-Lite v5 → v6**: major version bump, use `vega@5 + vega-lite@6 + vega-embed@6` together. Plain `<script src>` tags still work (UMD bundles).
- **ECharts v5 → v6**: theme breaking changes. This skill avoids ECharts — Plotly covers the niche with better defaults, Plot wins on faceting.
- **`datavisyn/chartjs-chart-box-and-violin-plot`**: archived, redirects to `@sgratzl/chartjs-chart-boxplot` (v4.4.5, actively maintained).
- **DataTables**: jQuery legacy. Use Tabulator.
- **`cdn.plot.ly/plotly-cartesian-<ver>.min.js`**: inconsistent versions hosted; prefer jsdelivr for predictable pinning.

## Silent-failure risk ranking

- **Vega-Lite**: HIGHEST risk. Invalid spec → empty SVG, no console error. Always wrap in try/catch and check `view.warnings()` after embed.
- **Chart.js**: loud (throws).
- **Plotly**: loud.
- **Observable Plot**: loud.

## Observable Plot mobile responsiveness pattern (mandatory)

Plot's default SVG width is 640px; it doesn't auto-shrink to container. Every Plot chart must be wrapped with a ResizeObserver:

```js
function renderPlot(containerId, plotConfig) {
  const container = document.getElementById(containerId);
  const render = () => {
    container.innerHTML = '';
    container.appendChild(Plot.plot({
      width: container.clientWidth,
      ...plotConfig
    }));
  };
  new ResizeObserver(render).observe(container);
  render();
}
```

## CDN failure fallback (inline in template `<head>`)

```html
<script>
  window.addEventListener('error', (e) => {
    if (e.target && e.target.tagName === 'SCRIPT') {
      document.body.insertAdjacentHTML('afterbegin',
        '<div style="background:#fee;color:#900;padding:12px;text-align:center;font-family:system-ui">' +
        '⚠ Chart library failed to load (' + (e.target.src || 'unknown') + '). Check your connection.' +
        '</div>');
    }
  }, true);
</script>
```

## Per-chart config snippets

### Histogram — Observable Plot (Freedman–Diaconis bins default)
```js
Plot.plot({
  marks: [
    Plot.rectY(data, Plot.binX({y: "count"}, {x: "value", thresholds: "freedman-diaconis"})),
    Plot.ruleY([0])
  ],
  x: {label: "Value →"},
  y: {label: "Count ↑"}
})
```

### Box plot — Observable Plot
```js
Plot.plot({
  marks: [
    Plot.boxY(data, {x: "group", y: "value", fill: "group"}),
    Plot.ruleY([0])
  ]
})
```

### Violin — Plotly
```js
Plotly.newPlot(container, [{
  type: 'violin', y: values, box: {visible: true}, meanline: {visible: true},
  points: 'outliers', line: {color: '#2563eb'}
}], {margin: {t: 10}});
```

### ECDF — Plotly (cumulative histogram)
```js
Plotly.newPlot(container, [{
  type: 'histogram', x: values, cumulative: {enabled: true}, histnorm: 'probability',
  marker: {color: '#2563eb'}
}], {xaxis: {title: 'Value'}, yaxis: {title: 'Cumulative probability'}});
```

### Q-Q plot against normal — Plotly
```js
// Sort values, compute theoretical normal quantiles, scatter
const sorted = [...values].sort((a,b) => a-b);
const n = sorted.length;
const theoretical = sorted.map((_, i) => jStat.normal.inv((i + 0.5) / n, 0, 1));
Plotly.newPlot(container, [
  {type: 'scatter', mode: 'markers', x: theoretical, y: sorted, name: 'Data'},
  {type: 'scatter', mode: 'lines', x: theoretical, y: theoretical, name: 'y=x'}
], {xaxis: {title: 'Theoretical'}, yaxis: {title: 'Sample'}});
```

### Scatter + regression — Observable Plot
```js
Plot.plot({
  marks: [
    Plot.dot(data, {x: "x", y: "y", opacity: 0.5}),
    Plot.linearRegressionY(data, {x: "x", y: "y", stroke: "#2563eb"})
  ]
})
```

### Correlation heatmap — Observable Plot (cell mark)
```js
Plot.plot({
  color: {scheme: "RdBu", domain: [-1, 1]},
  marks: [
    Plot.cell(corrPairs, {x: "col_a", y: "col_b", fill: "r"}),
    Plot.text(corrPairs, {x: "col_a", y: "col_b", text: d => d.r.toFixed(2)})
  ]
})
```

### SPLOM — Vega-Lite
```js
{
  "repeat": {"row": ["a","b","c"], "column": ["a","b","c"]},
  "spec": {
    "data": {"values": data},
    "mark": "point",
    "encoding": {
      "x": {"field": {"repeat": "column"}, "type": "quantitative"},
      "y": {"field": {"repeat": "row"}, "type": "quantitative"}
    }
  }
}
```

### Time series + event annotations — Observable Plot
```js
Plot.plot({
  marks: [
    Plot.lineY(data, {x: "date", y: "value", stroke: "#2563eb"}),
    Plot.ruleX(events, {x: "date", stroke: "#dc2626", strokeDasharray: "4,2"}),
    Plot.text(events, {x: "date", y: d => yMax, text: "label", dy: -8, fill: "#dc2626"})
  ]
})
```

### Stacked bar (composition over time) — Observable Plot
```js
Plot.plot({
  marks: [
    Plot.rectY(data, {x: "period", y: "value", fill: "category", interval: "month"}),
    Plot.ruleY([0])
  ],
  color: {legend: true, scheme: "category10"}
})
```

### Simple KPI line — Chart.js fallback
```js
new Chart(ctx, {
  type: 'line',
  data: {labels: xs, datasets: [{label: 'Revenue', data: ys, borderColor: '#2563eb', tension: 0.2}]},
  options: {responsive: true, maintainAspectRatio: false, plugins: {legend: {display: false}}}
});
```

### Sankey — Plotly
```js
Plotly.newPlot(container, [{
  type: 'sankey', orientation: 'h',
  node: {label: nodes, pad: 15, thickness: 20},
  link: {source: srcIdx, target: tgtIdx, value: values}
}]);
```

### Sortable/filterable table — Tabulator
```js
new Tabulator('#detail-table', {
  data: rows,
  layout: 'fitDataStretch',
  columns: [
    {title: 'Entity', field: 'name', headerFilter: 'input'},
    {title: 'Revenue (CZK)', field: 'revenue', sorter: 'number', formatter: 'money', formatterParams: {precision: 0}},
    {title: 'Platform', field: 'platform', headerFilter: 'select', headerFilterParams: {values: true}}
  ],
  initialSort: [{column: 'revenue', dir: 'desc'}],
  pagination: 'local', paginationSize: 25
});
```
