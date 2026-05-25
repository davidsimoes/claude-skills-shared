# /chrome-validate Handoff

The QA gate that runs after every render. Non-optional.

## Why this matters

A render that hasn't been validated is not ready. Local files have specific failure modes the eye misses on a casual glance:
- Broken Google Fonts URL → falls back to Times/Arial, kills the typography
- Mistyped CSS variable name → callouts render with no color
- Iframe / embed pointing at the wrong path → 0×0 silently
- Local file paths leaking into href attributes → broken on share

`/chrome-validate all` catches these in one tool call.

## Exact invocation

After writing the file, you have two options depending on whether `claude-in-chrome` MCP accepts `file://`:

### Preferred: try `file://` first
```
/chrome-validate all file://<absolute-path>/index.html
```

Where `<absolute-path>` is whichever path Phase 2 of /respond-html resolved (e.g. `~/dev/<project>/.html-answers/<slug>` or your generic html-answers fallback dir).

### Fallback: local http server (use this when `file://` is rejected)

**Known issue:** The `claude-in-chrome` MCP's `navigate` tool may prepend `https://` to `file://` URLs, breaking the navigation. When this happens, start a local server first:

```bash
cd <absolute-path> && python3 -m http.server 8765 > /tmp/respond-html-server.log 2>&1 &
SERVER_PID=$!
sleep 1
```

Then invoke chrome-validate against the localhost URL:
```
/chrome-validate all http://localhost:8765/
```

After PASS, stop the server: `kill $SERVER_PID`.

### Important: localStorage scope

Reactions persist in localStorage keyed by `location.pathname`. `file:///Users/<you>/...` and `http://localhost:8765/...` have **different pathnames** → reactions made on one will NOT show on the other. The chrome-validate gate uses the server; the final `open` uses `file://`. State doesn't migrate — but for the validation step this is OK (chrome-validate doesn't interact with reactions, it just validates the rendered HTML).

## What `all` runs

From `chrome-validate/SKILL.md`:

- **visual**: screenshot the page, zoom on logos/photos/text, DOM broken-image scan
- **css**: only runs if you pass `--selector`; for response-artifact, skip
- **layout**: bounding rects on flex/grid containers, check for unintended gaps and broken children
- **links**: curl every `<a href>` and `<link>` — must return 200

For response-artifact, the relevant gates are **visual** + **layout** + **links**.

## Surfacing the evidence

`/chrome-validate` emits a block like:

```
GATE: visual
STATUS: PASS
EVIDENCE: 1 screenshot saved to /var/folders/.../chrome-validate/visual-1715603400/page-initial.png
         DOM broken-image scan: []

GATE: layout
STATUS: PASS
EVIDENCE: .shell: 3 children, gap=2.5rem, w=1480px
         main: w=900px, h=2340px
         .toc: 1 child, sticky, scroll-overflow=auto

GATE: links
STATUS: PASS
EVIDENCE: 6 internal anchors → all resolve to in-page section IDs
         1 external link → https://fonts.googleapis.com/... → 200
```

Surface this block verbatim in your reply to the user, then add one line of plain English: *"All three gates PASS. Ready for review."*

## On FAIL

If any gate fails:

1. **Show the user the failure first.** Don't auto-fix. Failures often surface content/structural issues they want to weigh in on (a missing section, a wrong link, a broken decision-block that's a real disagreement, not a CSS bug).
2. **Identify the cause.** Read the file. Identify whether it's:
   - **Pure CSS/template bug** (e.g., mistyped variable) → safe to fix without asking
   - **Content issue** (missing section, broken anchor, dead link to a doc that doesn't exist) → ask the user before fixing
   - **Asset issue** (Google Fonts URL malformed, font subsetting wrong) → fix without asking
3. **Re-run the gate** after fixing.
4. **Don't loop.** If the same gate fails 3 times in a row, stop and surface to the user with what was tried. The chrome-validate skill itself recommends invoking a systematic-debugging workflow at that point — do so.

## What chrome-validate does NOT check

- Per-sentence language-quality (grammar, register, register mismatch) — that's a text-validation problem, not a browser-validation one
- Accessibility (use `chrome-devtools-mcp:a11y-debugging` separately if it matters for the artifact)
- Performance (this is a static reading doc — performance isn't relevant)

## Don't skip the gate

If chrome-validate is unavailable (e.g., the Chrome MCP extension isn't connected), surface that as a setup-gate FAIL — don't declare the artifact ready. The user needs to either reconnect the extension or explicitly tell you "skip the gate this time." The gate exists because untested HTML accumulates silent regressions.

## After PASS

```
open <absolute-path>/index.html
```

Then the final line:

```
Ready at file://<absolute-path>/index.html — opening now.
Summary: [1 line on what the artifact contains and the BLUF takeaway]
```
