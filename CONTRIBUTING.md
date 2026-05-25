# Contributing

Thanks for considering a contribution. This repo is small and opinionated — keep it that way.

## Quick links

- New skill? See [Adding a skill](#adding-a-skill).
- Editing an existing skill? See [Editing a skill](#editing-a-skill).
- Tests, hooks, security? See [Quality bar](#quality-bar).
- PR mechanics? See [Pull requests](#pull-requests).

## Repo shape

```
claude-skills-shared/
├── README.md
├── LICENSE                       # MIT
├── CONTRIBUTING.md               # this file
├── .githooks/
│   └── pre-push                  # optional security scan (see below)
└── <skill-name>/
    ├── SKILL.md                  # required
    ├── references/               # optional — sub-spec files referenced from SKILL.md
    ├── templates/                # optional — file skeletons the skill fills in
    ├── scripts/                  # optional — extracted bash/python/etc.
    ├── tests/                    # optional but expected for non-trivial scripts
    └── hooks/                    # optional — Claude Code hooks the skill installs
```

## Adding a skill

1. **Pick a name.** Lowercase, hyphenated, ideally one or two words. Matches the directory name.
2. **Write the SKILL.md** with frontmatter:

   ```yaml
   ---
   name: my-skill
   description: "One-paragraph description. Lead with the problem it solves, then the trigger conditions: 'Use when the user says X', 'Y', '/my-skill'."
   user-invocable: true
   disable-model-invocation: false
   ---
   ```

   The description is what Claude Code uses to decide whether to invoke the skill. Be specific about trigger phrases. See existing skills for examples — `clarify`, `chrome-validate`, and `respond-html` have the most polished descriptions.

3. **Body structure (recommended):**
   - One-line "what this is".
   - "When to use" section.
   - Numbered steps if the skill has a procedure.
   - "Anti-patterns" or "What this skill does NOT do" near the end.
   - "Why this exists" at the bottom, for context.

4. **If your skill has non-trivial shell logic, extract it.** Put the bash in `scripts/<name>.sh` and add a `tests/<name>.bats` suite. See `chrome-validate/scripts/` and `fresh-eyes/scripts/persist.sh` for the pattern. Markdown bash blocks that ship more than 2-3 lines of branching logic are a smell — extract them.

5. **Update the root `README.md`:**
   - Add a row to the relevant table (Output & QA / Discipline & meta-review / Workflow — or add a new category if needed).
   - Update the "N skills" count in the intro paragraph and section header.
   - Add to install instructions (the brace-expansion list + the for-loop list).
   - Add to the prerequisites table if your skill has requirements.
   - Update the chain diagram if your skill composes with others.

## Editing a skill

- **Match the existing prose style.** Terse, second-person where possible, prefers prose over heavy lists.
- **Don't add em dashes (—).** They're an AI-writing tell. Use commas, periods, or hyphens (-) instead.
- **Don't add unnecessary headers.** If a section only has 2-3 lines, fold it into the parent.
- **Keep SKILL.md files self-contained** — if you reference a script or template, put it in the same skill's directory. No cross-skill file dependencies.
- **Sanitize ruthlessly.** No personal names beyond generic "you" / "the user". No internal client names, internal channel IDs, paths that assume a specific knowledge base layout. The repo's pre-push hook will catch some of this; your eyes will catch more.

## Quality bar

### Tests

Non-trivial shell scripts (more than ~30 lines, or any branching logic that's load-bearing) ship with bats tests. Pattern:

- `<skill>/scripts/<name>.sh` — the script
- `<skill>/tests/<name>.bats` — the test suite
- `<skill>/tests/run-tests.sh` — a runner that does `bash -n`, `shellcheck`, `bats tests/`

Prerequisites for running tests: `brew install bats-core shellcheck` (macOS) or your distro's equivalent.

CI is not currently set up — run tests locally before opening a PR.

### Pre-push security scan

A `.githooks/pre-push` script ships with the repo. Enable it locally:

```bash
git config core.hooksPath .githooks
```

What it does on every `git push`:

1. Reads the to-be-pushed commit range.
2. Greps the added lines for an always-on API-key regex sweep (GitHub PATs, OpenAI/Stripe secrets, AWS keys, JWTs, Slack tokens, etc.).
3. If you've set `GIT_OS_BLOCKLIST=/path/to/your/blocklist.md`, also greps for any literal patterns from the `## §2+` sections of that file.
4. Blocks the push if anything matches.

The hook is opt-in (no `core.hooksPath = .githooks` → no scan). Bypass once with `git push --no-verify` if needed (not recommended).

If you maintain a personal blocklist of internal IDs / client names / etc. — point `GIT_OS_BLOCKLIST` at it. The format is `- \`pattern\`` lines under `## §<digit>` headings.

### Sanitization checklist (before opening a PR)

- [ ] No client names, internal team names, real people's names beyond yours
- [ ] No paths that assume a specific personal knowledge base (`~/dev/brain/...`, etc.)
- [ ] No internal channel IDs, portal IDs, API keys, tokens, webhook URLs
- [ ] Examples use generic placeholders (`acme-corp`, `example.com`, `<your-project>`) or short realistic strings
- [ ] "David" / specific maintainer names → "you" or "the user"
- [ ] Em dashes (—) replaced with commas, periods, or hyphens

## Pull requests

- One concern per PR. A new skill is one concern. A README cleanup is another. Don't bundle.
- Title in imperative mood, under 60 chars. "Add foo skill" beats "Adding foo skill which does bar".
- PR body: what changed (1-2 sentences), why (1-2 sentences), testing notes if relevant. No marketing prose.
- For new skills: include a screenshot or example output in the PR body if the skill produces visible artifacts.
- Co-authoring credit (`Co-Authored-By:`) is fine if a meaningful chunk was written with an AI assistant. Don't force it.

## License

Contributions are licensed under the MIT License (see [LICENSE](./LICENSE)). By submitting a PR, you confirm you have the right to license your contribution this way.
