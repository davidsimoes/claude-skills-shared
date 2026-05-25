---
name: chrome-validate
description: Browser-based QA validation for any URL or PDF — screenshots, computed CSS, layout integrity, link liveness, network inspection, PDF text-diff with diacritic check. Use when validating a deck/prototype/PDF before sending to clients, verifying visual fixes via Chrome MCP, checking that font subsetting didn't eat non-ASCII characters (e.g. Czech/Polish/Vietnamese diacritics), or saying 'validate this URL', 'check this PDF', 'verify the deck renders', '/chrome-validate'.
user-invocable: true
---

# /chrome-validate — Browser & PDF QA

Single skill for recurring browser-validation patterns: visual QA, computed CSS verification, layout integrity, link liveness, network inspection, PDF text-diff. Designed to be called from other skills or from a pre-send QA workflow, replacing ad-hoc inline procedures.

Six subcommands plus an `all` suite-mode. Each ends with a verification block listing evidence (file path, computed value, curl status). No "looks good" without paste-able proof.

## Subcommands

| Subcommand | What it does | Tools |
|---|---|---|
| `visual <url>` | Slide-by-slide screenshot + zoom on logos/photos/text + DOM broken-image check. Catches halos, opacity drift, font fallback, and `<img>` elements that render at 0×0. | `claude-in-chrome.computer` (preferred) or `chrome-devtools-mcp.take_screenshot` (fallback) |
| `css <url> --selector=X --check=opacity:0.3` | `getComputedStyle()` on selector, compare to expected. Catches `!important` overrides. | `claude-in-chrome.javascript_tool` (preferred) or `chrome-devtools-mcp.evaluate_script` (fallback) |
| `layout <url>` | `getBoundingClientRect()` on flex/grid containers. Catches sibling-height drift, broken gaps. | `claude-in-chrome.javascript_tool` (preferred) or `chrome-devtools-mcp.evaluate_script` (fallback) |
| `links <url>` | Chrome-MCP DOM extract → `curl -sI` each href. Asserts 200. | `scripts/link-check.sh` + Chrome MCP |
| `pdf <pdf-path> [--diff-html=<html>]` | `pdftotext` + diacritic count + optional diff against HTML source. Catches font-subsetting drops. | `scripts/pdf-validate.sh` |
| `network <url> --pattern=X` | Filter network log by URL pattern, assert status/headers. | `claude-in-chrome.read_network_requests` |
| **`all <url>`** *(suite-mode)* | visual + css (smart defaults) + layout + links sequentially, stop on first FAIL. PDF and network are explicit-only. | all of the above |

## When to use each

- **Before sending a deck to a client** → `all <url>` then `pdf <pdf>` for every PDF attachment
- **After a CSS fix** → `css <url> --selector=X` to verify computed value matches what you set
- **After a layout change** → `layout <url>` to confirm sibling heights/gaps stayed consistent
- **Documents in a language that uses diacritics** (Czech, Polish, Vietnamese, etc.) → `pdf <pdf> --diff-html=<src.html>` for every PDF, to catch font subsetting silently dropping non-ASCII glyphs
- **Theme dev, asset rendering bug** → `visual <url>` with zoom on the suspect element
- **API integration changes** → `network <url> --pattern=/api/`
- **Performance / Lighthouse** → use the `chrome-devtools-mcp` plugin separately. `/chrome-validate` does not duplicate it.

## Workflow

For every subcommand:
1. **Setup**: call `mcp__claude-in-chrome__tabs_context_mcp` to get current tabs. If the target URL is already open, reuse the tab; otherwise `tabs_create_mcp`. **If `claude-in-chrome` returns "Browser extension is not connected" and another session has working Chrome MCP, fall back to `chrome-devtools-mcp` plugin tools (`new_page`, `navigate_page`, `take_screenshot`, `evaluate_script`).** If both are unavailable, halt and surface the setup gate as FAIL — don't fake validation.
2. **Execute**: run the subcommand-specific procedure (below).
3. **Evidence block**: print a verification block. Format:
   ```
   GATE: <name>
   STATUS: PASS | FAIL
   EVIDENCE: <pasted output, computed value, curl headers, or file path>
   ```
4. **Stop on FAIL**: do not continue to the next gate. Surface the failure, suggest a fix, ask the user what to do.

This mirrors the `verification-before-completion` discipline from `superpowers` — every PASS needs evidence, never a bare claim.

## Subcommand details

### `visual <url>`

**Output path**: save all screenshots to `$TMPDIR/chrome-validate/visual-<timestamp>/`. **Do not use `/tmp/` directly** — `chrome-devtools-mcp.take_screenshot` only writes inside workspace roots + `$TMPDIR`, and rejects bare `/tmp/...` paths even though they resolve. On macOS, `$TMPDIR` is the user-specific `/var/folders/...` path and is always writable.

1. **Navigate** to the URL. Wait for load (`wait` action in `computer` tool, not arbitrary sleep).
2. **Full-page screenshot** of the initial view. Save to `$TMPDIR/chrome-validate/visual-<ts>/page-initial.png`.
3. **DOM broken-image enumeration** — the gate screenshots miss. Run via `javascript_tool` / `evaluate_script`:
   ```javascript
   Array.from(document.querySelectorAll('img'))
     .filter(i => i.complete && i.naturalWidth === 0)
     .map(i => ({src: i.getAttribute('src'), alt: i.alt, displayed: getComputedStyle(i).display !== 'none'}))
   ```
   Any result = FAIL. This catches `<img src="something.html">` and other "loads but renders 0×0" bugs that visual screenshots miss because the parent is `display:none` (print fallbacks, hidden modals).
4. **For each suspect element** (logos, photos, hero text, CTAs): `computer` action `zoom` on the element's bounding box. Save zoomed crops to the same dir.

**For reveal.js decks** (deck URLs ending in `/deals/<slug>/`, `?print-pdf`, or any page with `<div class="reveal">`):

a. **Disable transitions for deterministic capture**: `Reveal.configure({ transition: 'none' })`. Without this, screenshots may capture mid-animation frames and you waste tool calls re-running.

b. **Get slide count**: `Reveal.getTotalSlides()` (preferred) or `document.querySelectorAll('.slides > section').length` (fallback). Note the count.

c. **Iterate every slide**: `Reveal.slide(i, 0, 0)` for `i` in `0..count-1`. After each navigation, **`wait` 200ms** (or check `Reveal.isReady()`) before screenshot. Save as `slide-NN.png` (zero-padded).

d. **Handle lazy-loaded iframes** (`<iframe data-src="...">`): reveal.js swaps `data-src`→`src` only when the slide enters the activation range. If a slide contains such an iframe AND the in-loop screenshot shows it 0×0, force re-mount:
   ```javascript
   document.querySelectorAll('iframe[data-src]').forEach(f => { if (!f.src) f.src = f.dataset.src; });
   ```
   Wait for iframe load, then re-screenshot. Save with `-iframe-loaded` suffix.

e. **Handle `.fragment` bullets**: slides with fragment animations only show the first one on initial navigation. If a slide has `.fragment` children, take BOTH screenshots:
   - Default (first fragment only) — already captured by step (c)
   - All revealed — run `document.querySelectorAll('.slides .present .fragment').forEach(f => f.classList.add('visible'))`, screenshot, save as `slide-NN-all-fragments.png`

f. **Sidecar iframe-text dump**: if any slide contains an `<iframe>`, dump that iframe's `document.body.innerText` to `$TMPDIR/chrome-validate/visual-<ts>/iframe-text-slide-NN.txt`. This skill doesn't perform per-sentence language QA on the iframe content, but it has the only opportunity to enumerate iframe content without re-driving Chrome. **Caller responsibility**: any downstream text-review pipeline can read these sidecars (copy/symlink them to wherever your reviewer expects).

**Evidence block**:
- Slide count + screenshot count
- Each saved file path
- For each zoom, a one-line description of what was checked (e.g., "company wordmark, white on dark background, no halo")
- Broken-img DOM scan results (PASS = empty list, FAIL = the list)

### `css <url> --selector=X --check=property:expected_value`
1. Navigate.
2. Run via `javascript_tool`:
   ```javascript
   const el = document.querySelector('SELECTOR');
   if (!el) { console.log('NOT_FOUND'); return; }
   const cs = getComputedStyle(el);
   console.log(JSON.stringify({
     opacity: cs.opacity, filter: cs.filter, display: cs.display,
     position: cs.position, zIndex: cs.zIndex,
     width: cs.width, height: cs.height,
     // inline reference
     inline_opacity: el.style.opacity, inline_filter: el.style.filter
   }));
   ```
3. Compare to `--check` expectation. If mismatch, grep the CSS for `!important` on that property:
   ```bash
   grep -n '!important' <css-files>
   ```
4. **Evidence**: paste the JSON output. If FAIL, paste the grep matches.

### `layout <url>`
1. Navigate.
2. For each container the user names (or default: `[class*="grid"], [class*="flex"], [class*="container"]`):
   ```javascript
   document.querySelectorAll(SELECTOR).forEach(el => {
     const r = el.getBoundingClientRect();
     const cs = getComputedStyle(el);
     console.log(el.tagName, el.className, {
       w: r.width, h: r.height,
       gap: cs.gap, rowGap: cs.rowGap, columnGap: cs.columnGap,
       children: el.children.length
     });
   });
   ```
3. Flag any sibling cards with height delta > 5%, any gap that resolves to `0px` when expected, any container with 0 children.
4. **Evidence**: paste the dump + flagged anomalies.

#### Sub-check: column alignment (table-shaped layouts)

The steps above catch sibling height / gap / child-count anomalies, but they do NOT verify that header-row column edges align with data-row column edges. That gap shipped a real bug in production: a dashboard "table" was rendered as one independent flex row per data row, so each row's columns were sized to their own content and drifted out of alignment with the header. The default layout dump passed it (gaps fine, heights fine, children count fine) while the columns were visibly misaligned. This sub-check closes that gap.

**When to run it**: any time the page presents tabular data built from sibling containers (header + N data rows) rather than a `<table>`. CSS-grid "tables", flex "tables", and grid-template-driven dashboards all qualify. For a real `<table>`, the browser aligns columns automatically — this sub-check is unnecessary there.

**Selector**: accepts an optional `--table-selector=<sel>` nominating the row containers (header at index 0, data rows after). If omitted, auto-detect: find any parent whose ≥3 immediate-child containers share both `children.length` and an identical computed `gridTemplateColumns` (or identical computed widths if not a grid).

For each detected table, run via `javascript_tool`:

```javascript
const rows = Array.from(document.querySelectorAll(TABLE_SELECTOR)); // or auto-detected list
const header = rows[0];
const dataRows = rows.slice(1);
const colCount = header.children.length;
const tol = 2; // px
const report = [];
let allOK = true;
for (let col = 0; col < colCount; col++) {
  const h = header.children[col].getBoundingClientRect();
  const rs = dataRows.map(r => r.children[col].getBoundingClientRect());
  const dLeft = rs.map(r => +(r.left - h.left).toFixed(2));
  const dRight = rs.map(r => +(r.right - h.right).toFixed(2));
  const maxAbs = Math.max(...[...dLeft, ...dRight].map(Math.abs));
  const ok = maxAbs <= tol;
  if (!ok) allOK = false;
  report.push({
    col,
    name: header.children[col].textContent.trim().slice(0, 30),
    header: [+h.left.toFixed(2), +h.right.toFixed(2)],
    maxAbsΔ: maxAbs,
    OK: ok
  });
}
({allOK, columns: report, rowCount: dataRows.length, tolerancePx: tol})
```

**FAIL** the gate if any column's max |Δ| > 2px. The 2px tolerance accommodates sub-pixel rounding without letting a visibly misaligned column slip through — most real misalignments are tens of px, not single px.

**Evidence shape** — per-column report, one row per column. Example PASS (5 columns × 8 data rows, every edge identical):

```
col0 Month          header [513.00, 759.28]   maxAbsΔ 0.00  OK
col1 Earned         header [775.28, 929.21]   maxAbsΔ 0.00  OK
col2 Invoiced      header [945.21, 1099.14]   maxAbsΔ 0.00  OK
col3 Delta         header [1115.14, 1269.07]  maxAbsΔ 0.00  OK
col4 Running total header [1285.07, 1439.00]  maxAbsΔ 0.00  OK
```

**Self-test fixture**: `tests/fixtures/column-alignment.html` ships two side-by-side tables in one page — one built from independent flex rows (the bug pattern), one built from a shared CSS-grid template (the fix). Navigating Chrome to `file://<skill-dir>/tests/fixtures/column-alignment.html` and running the snippet above with `TABLE_SELECTOR = '#bad > div'` should produce a FAIL; with `TABLE_SELECTOR = '#good > div'` it should produce a PASS. This is the regression artifact for the gate itself.



### `links <url>`
1. Navigate to `<url>` via Chrome MCP.
2. Extract all `<a href>` and `<link href>` from the rendered DOM via `javascript_tool`:
   ```javascript
   Array.from(document.querySelectorAll('a[href], link[href]'))
     .map(el => new URL(el.getAttribute('href'), location.href).toString())
     .filter(u => u.startsWith('http'))
   ```
3. Pipe the URL list into `scripts/link-check.sh stdin` (one URL per line). For a single arbitrary URL outside the page, use `scripts/link-check.sh url <url>`.
4. **Evidence**: list of `URL  HTTP_STATUS` pairs. Any non-200 = FAIL.

### `pdf <pdf-path> [--diff-html=<html>]`
1. Run `scripts/pdf-validate.sh extract <pdf>` — produces text dump.
2. Run `scripts/pdf-validate.sh diacritic-count <pdf>` — counts diacritic chars (defaults to the Czech diacritic set; adjust the script if you need other ranges). Floor: 10 for any non-trivial document in a language that uses diacritics.
3. If `--diff-html` provided, run `scripts/pdf-validate.sh diff-html <pdf> <html>` — extracts HTML text and diffs against PDF text.
4. **Evidence**: paste extracted text head, diacritic count, diff (first 40 lines).

### `network <url> --pattern=X`
1. Navigate. Trigger the action that should fire the request (let the user click, or use `computer.left_click`).
2. Call `mcp__claude-in-chrome__read_network_requests` with filter pattern.
3. **Evidence**: paste matched requests with status, headers (Authorization redacted), response body summary.

### `all <url>`
Runs visual → css (skip if no `--selector`) → layout → links sequentially. Stops on first FAIL.

## Failure escalation

If a gate FAILs **3 times in a row** on the same URL/element:
1. Stop iterating. You're stuck in a local optimum.
2. Invoke `superpowers:systematic-debugging` — its 4-phase method exists for this.
3. If still stuck after that, surface to the user with a tight summary of what was tried.

This rule comes from a broader "repeated regression pattern" / "script extraction discipline" practice: 3 consecutive rounds of fixes each introducing a new bug is a strong signal that the current approach is wrong, not that one more attempt will land it.

## What this skill does NOT do

- **Performance / Lighthouse / Core Web Vitals** → use `chrome-devtools-mcp` plugin
- **Accessibility tree parsing** → use `claude-in-chrome.find` + manual review (Playwright plugin available if needed)
- **Visual regression diff vs baseline** → no automated solution currently (llmist + Playwright removed from stack); use `visual <url>` on both before/after URLs for manual screenshot comparison
- **Form interaction testing** → use `/theme-dev` workflow or manual `claude-in-chrome.form_input`
- **Per-sentence grammar/quality review** → that's a text-validation problem, not a browser-validation one; pair with a separate language-QA workflow

## Why this exists

Consolidates 5 recurring browser-QA patterns that show up in any workflow that produces client-facing HTML, PDFs, or web apps. The chrome-devtools-mcp plugin handles Lighthouse and performance but not computed-CSS introspection, region zoom, layout integrity, or PDF text-diff — those gaps are what this skill fills, designed to be callable from other skills or from a pre-send QA workflow.

**v1.1** — added the DOM broken-image enumeration step after a real bug shipped: a broken `<img>` element with `display:none` was invisible to screenshots but would have rendered as a broken-image icon in PDF export. Same release added the chrome-devtools-mcp fallback path, `$TMPDIR` instead of `/tmp` (workspace-root restriction), reveal.js transition-off for deterministic deck capture, lazy iframe `data-src`→`src` re-mount, `.fragment` reveal-all pass, and optional iframe-text sidecar dump for downstream review pipelines.

**v1.2** — added a column-alignment sub-check to the `layout` subcommand. The previous gate confirmed sibling cards/rows had similar heights and that gaps weren't 0, but did NOT verify that header-column edges aligned with data-row column edges. That gap shipped a real bug: header + each data row were independent flex containers, so columns drifted because flex sizes each child to its own content. The default layout dump passed it. The new sub-check measures `getBoundingClientRect` on same-index children across sibling row containers and flags |Δ| > 2px. Self-test fixture lives at `tests/fixtures/column-alignment.html` (misaligned flex + aligned grid, side-by-side).
