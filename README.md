# claude-qa-manager

A Claude Code plugin for running **structured, multi-round QA** on a merge request or pull
request — and for knowing when to stop.

Most AI code review is a single pass that optimises recall: find every possible defect.
That works once. Run it in a loop and it degenerates, because each round's fixes become
the next round's unreviewed surface. This plugin is built around that failure mode.

## What it does

- **Deterministic preflight.** One shell script performs the whole mechanical preamble —
  branch sync, ownership detection, credential resolution, round derivation, security-scan
  delta — and emits a single JSON object. The model reads values; it does not re-derive them.
- **A reviewer panel, not a reviewer.** A manager subagent fans out 3–6 lenses
  (contract/security, regression edges, test quality, and conditional lenses) in parallel,
  merges and de-duplicates their findings, and returns a compact verdict. All the noise
  stays in the manager's context, not yours.
- **Contract grounding.** Every finding is anchored to a linked ticket's acceptance
  criteria or to a regression the diff introduces — not to reviewer taste.
- **Proportionality with teeth.** The reviewer objective is two-sided: findings are weighed
  against the cost of acting on them. The mandate escalates at round 3, and the panel can
  declare `diminishing_returns` — a first-class result meaning *stop*.
- **A gated approval path.** Clean rounds can auto-approve under an explicit policy;
  schema changes never can without a human in the loop.

## Why the stop rule exists

See [docs/CASE-STUDIES.md](docs/CASE-STUDIES.md). Short version: a 40-line credential fix
was reviewed to "convergence" over four rounds producing 6 / 3 / 10 / 14 findings. By round
4, **11 of 14 findings were about a test file an earlier QA round had added**. The diff had
grown 9x and the shipped behaviour had been correct since round 2. No individual finding
was wrong. The aggregate was worthless.

A reviewer that concludes "this change is correct" has produced a complete result. This
plugin is designed to let it say so.

## Status

**v0.3.1 — early.** Extracted from a private implementation that has run hundreds of real
review rounds, then generalised. The design is battle-tested; this packaging is new.

## Requirements

- Claude Code
- `git`, `jq`
- `glab` (GitLab) and/or `gh` (GitHub)
- `unzip` and `curl` for security-scan and second-opinion features (optional)

`bash` is invoked explicitly; the plugin does not assume your interactive shell.

## Install

```bash
claude plugin marketplace add halindrome/claude-qa-manager
claude plugin install claude-qa-manager@halindrome
```

Update with `claude plugin marketplace update halindrome && claude plugin update claude-qa-manager@halindrome`.

To try it without installing:

```bash
claude --plugin-dir /path/to/claude-qa-manager
```

## Configure

Zero configuration required for the common case: branches are derived at runtime from the
MR/PR itself. Everything else is optional and lives in
`.claude/skills/qa-cycle/config.json` in your project. See
[docs/CONFIGURING.md](docs/CONFIGURING.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
