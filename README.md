# claude-skills-shared

Four skills for [Claude Code](https://docs.claude.com/en/docs/claude-code) — small, focused tools that change how an agent works in your terminal. Each is a single `SKILL.md` (plus supporting scripts/templates where needed) that Claude Code auto-loads when its description matches what you're asking for.

## What's a Claude Code skill?

A skill is a markdown file with frontmatter (`name`, `description`, `user-invocable: true`) plus optional supporting files. When Claude Code starts a session it indexes every skill in `~/.claude/skills/`. When your request matches a skill's trigger phrases — or when you type the skill's slash command (e.g. `/clarify`) — Claude invokes it. From the agent's side, "invoking a skill" means loading the SKILL.md content and following its instructions.

Skills compose. One skill can chain to another by reading its file or calling its slash command. Two of the skills here chain to each other; the rest are standalone.

## The four skills

| Skill | Problem it solves | Standalone? |
|---|---|---|
| [`clarify`](./clarify/) | Agents make unilateral assumptions on ambiguous requests, then have to redo work when the assumption was wrong. `clarify` is a structural forcing function: when invoked, the agent MUST stop, audit the request for ambiguity / scope creep / unilateral tradeoffs / irreversible-action risk, and ask via `AskUserQuestion` before continuing. | ✅ Pure prose, no scripts. |
| [`delegate`](./delegate/) | Long-running or parallelizable work in a single Claude Code session crowds the main context. `delegate` spawns a child Claude session in tmux with a scoped task, registers it in a JSON file, and gives you cooperation verbs (`tell`, `fetch`, `status`, `close`) to drive it from the parent. No MCP dependency — works with any Claude Code install + tmux. | ✅ Needs `tmux`; macOS-tested, should work on Linux. |
| [`chrome-validate`](./chrome-validate/) | "Looks good" isn't QA. Before sending an HTML or PDF to a client, you need evidence: actual screenshots, computed CSS values, real link liveness, PDF text-diff checks. `chrome-validate` packages six subcommands (`visual`, `css`, `layout`, `links`, `pdf`, `network`) + an `all` suite-mode that runs them sequentially, each with paste-able evidence. | ✅ Needs Chrome MCP (`claude-in-chrome` or `chrome-devtools-mcp`); `pdftotext` for the PDF subcommand. |
| [`respond-html`](./respond-html/) | When a chat reply has implicit structure (plan, audit, comparison, proposal), the chat format buries it. `respond-html` writes a self-contained HTML artifact with reading-optimized layout, inline ✅/💬/❌ reactions per section/callout/decision-block, and a one-click "copy feedback as markdown" button. The user reacts in the browser, pastes the markdown back to chat, the agent iterates. | ⚠️ Chains to `chrome-validate` for QA (bundled here). Also references `/dataviz` and `/frontend-design` for delegation paths — those aren't in this repo and the skill gracefully degrades without them. |

## Install

Drop the four skill dirs into your Claude Code skills directory:

```bash
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

Restart Claude Code. The skills register via their `user-invocable: true` frontmatter — no other config needed. Test with `/clarify` in a session; the agent should announce it's invoking the skill.

## Prerequisites

| Skill | Required | Optional |
|---|---|---|
| `clarify` | Nothing | — |
| `delegate` | `tmux` | — |
| `chrome-validate` | Chrome MCP server (`claude-in-chrome` or the `chrome-devtools-mcp` plugin), `pdftotext` for the PDF subcommand (macOS: `brew install poppler`) | `bats-core` + `shellcheck` to run the test suite in `chrome-validate/tests/` |
| `respond-html` | `python3` (for the smoke-test generator) | `chrome-validate` (bundled — used as a post-render QA gate); `/dataviz` and `/frontend-design` (NOT bundled — used for delegation paths, but the skill works without them) |

## Glossary

A few terms used in the skills that might not be obvious:

- **Skill** — a markdown file with frontmatter that Claude Code auto-loads. See [Claude Code docs](https://docs.claude.com/en/docs/claude-code/sub-agents) for the canonical reference.
- **MCP** — Model Context Protocol. The standard for tool servers in the Claude ecosystem. `claude-in-chrome`, `chrome-devtools-mcp`, and others are MCP servers.
- **Frontmatter** — the YAML block at the top of a SKILL.md (`---` delimited). `user-invocable: true` is what makes a skill callable via slash command.
- **Reactable unit** (in `respond-html`) — a section, callout, or decision-block in the rendered HTML that has its own ✅/💬/❌ button row.
- **Gravity tag** (in `respond-html`) — one of 8 tags (stern, decisive, balanced, distinctive, editorial, measured, light, multidimensional) that picks the font pair + accent for the artifact based on the content's weight.

## How the skills relate

```
                  ┌──────────────┐
                  │   clarify    │   (standalone)
                  └──────────────┘

                  ┌──────────────┐
                  │   delegate   │   (standalone, needs tmux)
                  └──────────────┘

                  ┌─────────────────┐
                  │  respond-html   │── delegates to ──▶ /dataviz, /frontend-design (NOT bundled)
                  └────────┬────────┘
                           │ post-render QA gate
                           ▼
                  ┌─────────────────┐
                  │ chrome-validate │   (standalone, needs Chrome MCP)
                  └─────────────────┘
```

You can install any subset. Installing only `respond-html` without `chrome-validate` is fine — the validation step will surface a "setup gate FAIL" and the rest of the artifact still renders.

## Background

These skills were extracted from a working agentic-development setup. Examples and prose in the SKILL.md files reflect that origin (mention of decks, tenders, Czech-language QA in `chrome-validate`'s PDF subcommand, etc.), but the skills themselves are domain-agnostic — they don't assume any particular workflow or industry.

If something feels too tied to the original context, that's a sanitization miss worth flagging. Open an issue or PR.

## Contributing

PRs welcome. Conventions:

- Match the existing prose style in each SKILL.md (terse, second-person where possible).
- Keep SKILL.md files self-contained — if you reference a script or template, put it in the same skill's directory.
- Add tests for any non-trivial shell logic (`chrome-validate` ships a bats-core suite — follow that pattern).
- Avoid em dashes (—) in markdown if you can; they're an AI-writing tell.

## License

MIT. See [LICENSE](./LICENSE).
