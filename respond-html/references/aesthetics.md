# Aesthetics — Match To Content, No AI Slop

Borrowed and trimmed from `/frontend-design` and Anthropic's design-quality work. Specialized for *reading-optimized* output.

## The rule

Reading-optimized doesn't mean boring. It means: typography carries the personality, color is restrained, layout supports scanning. Editorial-quality. Think New York Magazine longreads or a polished Substack post — not a SaaS dashboard, not a luxury brand site, not a brutalist art zine.

**v0.3 change**: aesthetics are no longer rotated randomly. They're matched to **content gravity** — the topic, tone, and stakes of the artifact decide the font pair + accent. This is intentional: a security audit and a strategy roadmap shouldn't feel alike.

## Gravity → Aesthetic mapping

Pick the row that best fits the artifact's content. Use the **gravity tag** in the artifact's eyebrow (e.g. "Plan · stern" or "Audit · measured") so the user sees the classification.

| Gravity tag | Content type | Body serif | Heading sans | Accent (light/dark) |
|---|---|---|---|---|
| **stern** | Security audit, contract review, money/legal, compliance | IBM Plex Serif | IBM Plex Sans | Oxford blue `#0a3f6b` / `#6dafe6` |
| **decisive** | Strategy proposal, roadmap, "what should we do", clear recommendation | Crimson Pro | Manrope | Jade `#1f6f43` / `#6dd4a4` |
| **balanced** | Comparison, evaluation, tradeoff analysis, "X vs Y" | Source Serif 4 | Geist | Deep teal `#1d3a3a` / `#7fcccc` |
| **distinctive** | Mockup, design proposal, UI feedback, creative brief | Fraunces | Bricolage Grotesque | Deep violet `#5c2d91` / `#c9a3ff` |
| **editorial** | Routine plan, project status, recap, weekly review | Newsreader | Hanken Grotesk | Vermilion `#b1230b` / `#ff7a59` |
| **measured** | Audit (non-security), retro, postmortem, lessons | EB Garamond | Outfit | Amber `#8a4f00` / `#f0b85b` |
| **light** | Quick recommendation, short proposal, single-decision memo | Lora | Hanken Grotesk | Jade `#1f6f43` / `#6dd4a4` |
| **multidimensional** | Compound (data + plan, audit + mockup), cross-cutting | Spectral | Manrope | Deep violet `#5c2d91` / `#c9a3ff` |

## How to pick the row (gravity classifier)

After Phase 0 content-type classification (see `content-type-detection.md`), apply this 3-step gravity check:

1. **Stakes signal**: does the artifact involve money, legal, security, or a high-trust client commitment? → `stern`.
2. **Verdict signal**: does the BLUF land on a single recommendation with a path forward? → `decisive` (if confident), `light` (if simple), `editorial` (if routine).
3. **Shape signal**: is it primarily comparing options, auditing past work, or proposing creative direction?
   - Comparing → `balanced`
   - Auditing → `measured` (or `stern` if security/compliance)
   - Creative / UI / mockup → `distinctive`
   - Crosses 2+ shapes → `multidimensional`

If two rows feel right, pick the one with the higher stakes — over-grave is better than under-grave.

State the gravity tag in your one-line classification announcement: *"Classifying as a **proposal**, gravity **decisive** → Crimson Pro + Manrope + jade."*

## What's gone in v0.3

- **No more rotation logic.** Don't track "last 3 combos used." Don't read previous artifacts' footers to learn what was used. The mapping table is deterministic.
- **No more "vary across runs."** Two strategy proposals in a row will both be Crimson Pro + Manrope + jade. That's correct — they're the same shape of artifact.
- **No state file.** No `~/.claude/skills/respond-html/state.json`.

If the user wants variation within a gravity tag (e.g., 3 strategy proposals shouldn't be identical), v0.4 can add a within-row pair swap. Don't pre-build that.

## Font URL recipe

The template loads fonts from Google Fonts. Build the URL with both families and **every weight actually used in the CSS** — the heading sans uses 500/600/700, the body serif uses 400/500.

```
https://fonts.googleapis.com/css2?family=<BodySerif>:opsz,wght@9..144,400;9..144,500&family=<HeadingSans>:wght@500;600;700&display=swap
```

For variable fonts WITHOUT an `opsz` axis (e.g. Manrope, Bricolage Grotesque, Hanken Grotesk, Geist, IBM Plex Sans, Outfit) drop the `opsz,wght@9..144,` prefix and use `wght@400;500` directly.

| Font | Has `opsz` axis? |
|---|---|
| Fraunces | yes |
| Newsreader | yes |
| Source Serif 4 | yes |
| EB Garamond | yes |
| Crimson Pro | no |
| IBM Plex Serif | no |
| Lora | no |
| Spectral | no |
| All listed heading sans-serifs | no |

## The never-list

**Never use** for any role:
- Inter, Roboto, Arial, Helvetica, system-ui as the primary face
- Space Grotesk (over-used by AI)
- Open Sans, Lato, Merriweather (over-used)
- The purple-on-white gradient (Inter + `#6366f1` = AI slop signature)
- Candy-pink CTAs, bright sky-blue links, default Tailwind indigo

## Layout principles

The template already implements these — don't fight them.

- **Single-column reading width**: `--measure: 70ch`. Body prose never goes wider. Tables and code blocks can.
- **Two-column shell on desktop**: TOC sidebar (sticky) | reading column. Collapses to single column on narrow screens.
- **Generous vertical rhythm**: `1.65` line-height for body, 3rem between sections.
- **Hierarchy through size + weight + space**, not through color or boxes. Boxes are for callouts only.

## Color usage rules

- **Body text**: `--ink` on `--bg`. Always high contrast.
- **Subtle structure**: `--rule` for borders, `--ink-soft` for secondary text, `--ink-faint` for tertiary.
- **Accent** (from the gravity row): hyperlinks, BLUF border, eyebrow text, active TOC item. Not for body emphasis (use weight instead).
- **Callout colors**: decision (green), tradeoff (amber), risk (red), recommendation (blue) — these are fixed semantic colors, don't swap them per-render even when the accent is similar.

## Things to avoid (recap)

- Inter, Roboto, Arial, Helvetica, Space Grotesk
- Purple-on-white gradient
- Generic Tailwind defaults (slate-50, indigo-500, etc.)
- Multiple competing accent colors
- Box-everywhere layouts (boxes are for callouts only)
- Gradient text headings
- Animation on page load (the user is reading, not being entertained)
- Emoji icons in body content (this is editorial, not a Notion doc — only the reaction-button emojis are allowed)
- Drop shadows everywhere (the template uses 0-1 drop shadows total)

## The vibe check

Before declaring ready, look at the rendered page. Ask:
1. Does the aesthetic match the gravity tag? (Stern artifact in vermilion → mismatch.)
2. Could this be from any random SaaS landing page? (If yes → too generic.)
3. Does the typography carry character without shouting? (If shouting → too maximalist.)
4. Can I scan the TOC and know what each section is about? (If no → titles are too generic.)
5. Is there exactly ONE accent color doing real work? (If multiple → simplify.)

If all five are yes, the aesthetics are right.
