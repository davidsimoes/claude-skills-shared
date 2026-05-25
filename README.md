# claude-skills-shared

Selected Claude Code skills from David's setup, packaged for sharing inside SGA.

This is the MVP — four skills picked because they're the most reusable across teammates. The broader plan is a full open-source release covering the whole skill library, which needs a heavier sanitization pass; this repo is the seed for that.

## What's in here

| Skill | What it does | Standalone? |
|---|---|---|
| **clarify** | Forces a self-audit (`AskUserQuestion`) before Claude commits to an interpretation. Use when you want Claude to slow down and confirm before guessing. | ✅ Yes |
| **delegate** | Spawn a child Claude session in tmux for a scoped task. Includes cooperation verbs (`tell`/`fetch`/`close`/`status`) and a JSON registry for tracking. | ✅ Yes (requires `tmux`) |
| **chrome-validate** | Browser+PDF QA: screenshots, computed CSS, layout, links, network, PDF text-diff. Sub-skill of `/respond-html` and the pre-send-qa-gate workflow. | ✅ Yes (requires Chrome MCP) |
| **respond-html** | Render structured HTML responses (plans, audits, comparisons) instead of chat prose. Inline ✅/💬/❌ reactions + copy-as-markdown feedback. Chains to chrome-validate. | ⚠️ Chains to chrome-validate (also bundled here); also references `/dataviz` and `/frontend-design` which are NOT bundled |

## Install

```bash
# In your Claude Code config dir (usually ~/.claude/skills/):
cd ~/.claude/skills
git clone https://github.com/davidsimoes/claude-skills-shared.git _tmp
mv _tmp/{clarify,delegate,respond-html,chrome-validate} .
rm -rf _tmp
```

Or, if you'd rather keep the repo elsewhere and symlink (set `REPO_PATH` to wherever you want it):

```bash
REPO_PATH=~/path/to/claude-skills-shared
git clone https://github.com/davidsimoes/claude-skills-shared.git "$REPO_PATH"
for skill in clarify delegate respond-html chrome-validate; do
  ln -s "$REPO_PATH/$skill" ~/.claude/skills/$skill
done
```

Restart Claude Code. The skills register from `frontmatter.user-invocable: true` — no other config needed.

## Prerequisites

- **clarify**: nothing
- **delegate**: `tmux`; written assuming macOS, should work on Linux
- **chrome-validate**: `claude-in-chrome` MCP server (or `chrome-devtools-mcp` plugin as fallback); `pdftotext` (`brew install poppler`) for PDF subcommand; optional: `bats-core` + `shellcheck` to run the test suite at `chrome-validate/tests/`
- **respond-html**: `python3` for the smoke-test script; chrome-validate (bundled); optionally `/dataviz` and `/frontend-design` for full chain — without those it falls back to its own template, which covers most cases

## Adapting to your setup

These skills were authored for David's environment. Things you'll want to know:

- **Paths**: examples reference `~/dev/SGA/<project>/` and `~/dev/brain/projects/` — adjust to your own conventions. The skills don't enforce these paths; they use them as hints for project detection in `respond-html`.
- **Examples**: SKILL.md files mention real SGA client projects (Reservio, Orkla, BAPA, etc.) as illustrative examples. Read them as concrete cases, not required configurations.
- **Chained references**: some skills reference other skills David has (`/dataviz`, `/frontend-design`, `/close`, `/fresh-eyes`, `/pre-send-qa-gate`) that aren't in this repo. The bundled skills work without them — chains gracefully degrade.

## Roadmap

This MVP is the seed for a public open-source release of the broader skill library (~70 skills). That release needs a proper sanitization pass (strip client refs, generalize examples, remove personal IDs). Until then this repo stays private and David-flavored.

Feedback welcome — open an issue, ping David in Slack, or just edit + PR.
