#!/usr/bin/env python3
"""
respond-html generator — single source of truth for template substitution.

Usage:
  generate.py --content <content.json> --out <output-dir>
  generate.py --content <content.json> --out <output-dir> --pdf

Content JSON schema (see scripts/smoke-test-content.json for a worked example):

  {
    "title": "v0.3: close the drift, persist the rotation, ship PDF.",
    "subtitle": "Round-3 audit closed at 9/10. v0.3 is the ...",
    "eyebrow": "Plan · decisive",
    "gravity": "decisive",
    "bluf": "Tackle 4 things in v0.3: ...",
    "sections": [
      {
        "id": "scope",
        "title": "v0.3 scope at a glance",
        "body": "<HTML content for the section body>",
        "feedback_id": "scope-overview",       // optional — stable ID for reactions across re-renders
        "feedback_label": "Scope at a glance"  // optional — label in the markdown feedback export
      },
      ...
    ]
  }

The script reads the template at ../templates/response-artifact.html, substitutes
the {{TOKENS}}, and writes index.html to <output-dir>. With --pdf it also
produces index.pdf via headless Chrome.

Why this exists: v0.2 had a hand-written smoke-test that drifted from the
template across 3 versions. The generator is now the canonical path — any
template fix re-applies to the smoke-test on regen. See v0.3-plan.md.
"""

from __future__ import annotations

import argparse
import html
import json
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TEMPLATE_PATH = REPO_ROOT / "templates" / "response-artifact.html"

# Gravity tag -> content-type prefix for the eyebrow fallback. A "stern" artifact
# is typically an audit, not a "Plan", so the fallback eyebrow should read
# "Audit · stern" rather than "Plan · stern". Override per-render by setting
# content["eyebrow"] explicitly.
GRAVITY_TO_EYEBROW_PREFIX = {
    "stern":            "Audit",
    "decisive":         "Plan",
    "balanced":         "Comparison",
    "distinctive":      "Design",
    "editorial":        "Plan",
    "measured":         "Audit",
    "light":            "Recommendation",
    "multidimensional": "Plan",
}

# Gravity tag -> font pair + accent. Mirrors references/aesthetics.md.
GRAVITY_AESTHETICS = {
    "stern":            {"body": "IBM Plex Serif",     "head": "IBM Plex Sans",       "light": "#0a3f6b", "dark": "#6dafe6", "name": "oxford blue"},
    "decisive":         {"body": "Crimson Pro",        "head": "Manrope",             "light": "#1f6f43", "dark": "#6dd4a4", "name": "jade"},
    "balanced":         {"body": "Source Serif 4",     "head": "Geist",               "light": "#1d3a3a", "dark": "#7fcccc", "name": "deep teal"},
    "distinctive":      {"body": "Fraunces",           "head": "Bricolage Grotesque", "light": "#5c2d91", "dark": "#c9a3ff", "name": "deep violet"},
    "editorial":        {"body": "Newsreader",         "head": "Hanken Grotesk",      "light": "#b1230b", "dark": "#ff7a59", "name": "vermilion"},
    "measured":         {"body": "EB Garamond",        "head": "Outfit",              "light": "#8a4f00", "dark": "#f0b85b", "name": "amber"},
    "light":            {"body": "Lora",               "head": "Hanken Grotesk",      "light": "#1f6f43", "dark": "#6dd4a4", "name": "jade"},
    "multidimensional": {"body": "Spectral",           "head": "Manrope",             "light": "#5c2d91", "dark": "#c9a3ff", "name": "deep violet"},
}

# Which fonts have an opsz axis (need different Google Fonts URL syntax).
HAS_OPSZ = {"Fraunces", "Newsreader", "Source Serif 4", "EB Garamond"}


def build_google_fonts_url(body_font: str, head_font: str) -> str:
    """Build a Google Fonts CSS URL with both families and all weights used by the template."""
    def family_chunk(name: str, weights: list[int]) -> str:
        slug = name.replace(" ", "+")
        if name in HAS_OPSZ:
            weight_spec = ";".join(f"9..144,{w}" for w in weights)
            return f"family={slug}:opsz,wght@{weight_spec}"
        weight_spec = ";".join(str(w) for w in weights)
        return f"family={slug}:wght@{weight_spec}"

    body_chunk = family_chunk(body_font, [400, 500])
    head_chunk = family_chunk(head_font, [500, 600, 700])
    return f"https://fonts.googleapis.com/css2?{body_chunk}&{head_chunk}&display=swap"


def gravity_to_aesthetics(gravity: str) -> dict:
    if gravity not in GRAVITY_AESTHETICS:
        raise ValueError(f"Unknown gravity tag: {gravity!r}. Valid: {sorted(GRAVITY_AESTHETICS)}")
    return GRAVITY_AESTHETICS[gravity]


def escape_token(value: str) -> str:
    """HTML-escape <, >, &, ", ' so token values can't break the template."""
    return html.escape(value, quote=True)


def render_section(section: dict, index: int) -> str:
    """Render one section block. Section body is trusted HTML (Claude wrote it)."""
    section_id = section["id"]
    title = escape_token(section["title"])
    num = f"{index:02d}"
    body = section.get("body", "")
    extra_id_attr = ""
    extra_label_attr = ""
    if "feedback_id" in section:
        extra_id_attr = f' data-feedback-id="{escape_token(section["feedback_id"])}"'
    if "feedback_label" in section:
        extra_label_attr = f' data-feedback-label="{escape_token(section["feedback_label"])}"'
    return (
        f'<section id="{section_id}"{extra_id_attr}{extra_label_attr}>\n'
        f'  <h2><span class="num">{num}</span> {title}</h2>\n'
        f'{body}\n'
        f'</section>\n'
    )


def render_toc(sections: list[dict]) -> str:
    items = []
    for s in sections:
        items.append(f'<li><a href="#{s["id"]}">{escape_token(s["title"])}</a></li>')
    return "\n        ".join(items)


def substitute_template(template: str, content: dict) -> str:
    gravity = content.get("gravity", "editorial")
    aesthetics = gravity_to_aesthetics(gravity)

    google_fonts_url = build_google_fonts_url(aesthetics["body"], aesthetics["head"])

    sections_html = "".join(render_section(s, i + 1) for i, s in enumerate(content["sections"]))
    toc_html = render_toc(content["sections"])

    default_eyebrow = f"{GRAVITY_TO_EYEBROW_PREFIX.get(gravity, 'Plan')} · {gravity}"
    substitutions = {
        "{{TITLE}}": escape_token(content["title"]),
        "{{SUBTITLE}}": escape_token(content.get("subtitle", "")),
        "{{EYEBROW}}": escape_token(content.get("eyebrow", default_eyebrow)),
        "{{BLUF}}": content["bluf"],  # NOT escaped — Claude may include <strong>, <code>, etc.
        "{{TOC_ITEMS}}": toc_html,
        "{{SECTIONS}}": sections_html,
        "{{ACCENT}}": aesthetics["light"],
        "{{ACCENT_DARK}}": aesthetics["dark"],
        "{{BODY_FONT}}": aesthetics["body"],
        "{{HEADING_FONT}}": aesthetics["head"],
        "{{GOOGLE_FONTS_URL}}": google_fonts_url,
        "{{GENERATED_AT}}": content.get("generated_at", ""),
    }

    output = template
    for token, value in substitutions.items():
        output = output.replace(token, value)
    return output


def to_pdf(html_path: Path, pdf_path: Path) -> None:
    """Render HTML -> PDF via headless Chrome. Falls back to weasyprint if Chrome not available."""
    chrome_candidates = [
        "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
        shutil.which("google-chrome"),
        shutil.which("chromium"),
    ]
    chrome = next((p for p in chrome_candidates if p and Path(p).exists()), None)
    if chrome:
        try:
            subprocess.run(
                [
                    chrome,
                    "--headless=new",
                    "--disable-gpu",
                    "--no-pdf-header-footer",
                    "--print-to-pdf=" + str(pdf_path),
                    html_path.resolve().as_uri(),
                ],
                check=True,
                capture_output=True,
            )
            print(f"  -> PDF written via headless Chrome: {pdf_path}")
        except subprocess.CalledProcessError as e:
            print(f"  ! Chrome PDF generation failed: {e.stderr.decode(errors='replace').strip()}", file=sys.stderr)
            raise
        return
    weasyprint = shutil.which("weasyprint")
    if weasyprint:
        try:
            subprocess.run([weasyprint, str(html_path), str(pdf_path)], check=True, capture_output=True)
            print(f"  -> PDF written via weasyprint: {pdf_path}")
        except subprocess.CalledProcessError as e:
            print(f"  ! weasyprint failed: {e.stderr.decode(errors='replace').strip()}", file=sys.stderr)
            raise
        return
    print("  ! PDF requested but no renderer found (Chrome or weasyprint). Use --pdf=skip to silence.", file=sys.stderr)
    raise SystemExit(3)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate /respond-html artifact from content JSON + template.")
    parser.add_argument("--content", required=True, help="Path to content JSON file.")
    parser.add_argument("--out", required=True, help="Output directory (index.html written here).")
    parser.add_argument("--pdf", action="store_true", help="Also generate index.pdf via headless Chrome.")
    parser.add_argument("--template", default=str(TEMPLATE_PATH), help="Template path (default: bundled).")
    args = parser.parse_args()

    content_path = Path(args.content).resolve()
    out_dir = Path(args.out).resolve()
    template_path = Path(args.template).resolve()

    if not content_path.exists():
        print(f"error: content file not found: {content_path}", file=sys.stderr)
        return 2
    if not template_path.exists():
        print(f"error: template not found: {template_path}", file=sys.stderr)
        return 2

    try:
        content = json.loads(content_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"error: malformed JSON at {content_path}: {e}", file=sys.stderr)
        return 2

    # utf-8-sig strips a BOM if the template was saved with one (Windows editors).
    template = template_path.read_text(encoding="utf-8-sig")
    out_dir.mkdir(parents=True, exist_ok=True)

    rendered = substitute_template(template, content)
    html_path = out_dir / "index.html"
    html_path.write_text(rendered, encoding="utf-8")
    print(f"  -> HTML written: {html_path}")

    if args.pdf:
        to_pdf(html_path, out_dir / "index.pdf")

    return 0


if __name__ == "__main__":
    sys.exit(main())
