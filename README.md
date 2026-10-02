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
- `glab` (GitLab) and/or `gh` (GitHub), **logged in** (`glab auth login` / `gh auth login`)
- `unzip` and `curl` for security-scan and second-opinion features (optional)

macOS and Linux. `bash` is invoked explicitly (3.2 or later), so your interactive shell
does not matter.

## Install

```bash
claude plugin marketplace add halindrome/claude-qa-manager
claude plugin install claude-qa-manager@halindrome
```

Restart Claude Code afterwards. `/qa-init` and `/qa-cycle` should then appear when you
type `/`.

Update with `claude plugin marketplace update halindrome && claude plugin update claude-qa-manager@halindrome`.

To try it without installing:

```bash
claude --plugin-dir /path/to/claude-qa-manager
```

## Quick start

Run these from Claude Code, inside a clone of the repository the MR/PR belongs to.

**1. Set the project up — once per repository.**

```
/qa-init
```

It checks your tools and forge login, then asks the two questions only you can answer:
which file(s), if any, *are* your database schema, and whether this is a monorepo whose
parts are reviewed separately. Most projects answer "none" and "no" and end up with no
config file at all, which is fine. It also offers to store an optional QA agent token
(see [below](#a-separate-qa-identity-optional)). Skipping `/qa-init` works for a plain
single repository, but it is the quickest way to find a missing login before a round
fails on one.

**2. Review a merge or pull request.**

```
/qa-cycle 123
```

`123` is the MR (GitLab) or PR (GitHub) number. The forge is detected from your `origin`
remote. In a monorepo, add the target name: `/qa-cycle 123 api`.

**3. Answer its questions.** A round stops and asks before anything you might not want:
applying fixes, continuing to another round, ending the cycle, approving.

`/qa-cycle --help` prints every argument and flag.

## What a round does

Know this before your first run, because a round works **in your current checkout**:

1. **Preflight** checks out the MR/PR's source branch, merges its target branch into it,
   and **pushes** that merge, because a branch behind its base produces false findings.
   Commit or stash your work first; uncommitted changes can block the checkout. If the merge would
   delete files unexpectedly, it stops and asks instead of pushing.
2. **The reviewer panel** — several reviewers, each with one lens — reads the change
   against the linked ticket's acceptance criteria (a Jira key or a forge issue in the
   description) or, failing that, a contract it writes from the MR/PR description.
3. **Fixes.** On **your own** MR/PR it offers to fix what was found, runs your tests
   (discovered from your Makefile, `package.json`, `go.mod` and similar), and pushes one
   commit per round. If it finds no test command, the round note says the fixes went
   unverified. On **someone else's**, it posts the report and leaves
   the fixes to the author unless you say otherwise.
4. **The round note** is posted as a comment on the MR/PR.
5. **Continue or stop.** After blocking findings are fixed it asks whether to run the next
   round. A clean round ends the cycle. So does `diminishing_returns`: the panel's
   signal that most of what it is finding is in code earlier QA rounds added, not in the
   change itself. Stopping there is a complete result, not a failure.
6. **Approval**, only if you configured a QA identity and every gate passes — CI green
   on the exact commit, round clean, no unacknowledged schema change — and you confirm.

To keep reviewing while you work on something else, give the MR/PR its own worktree
(`git worktree add ../review-123 <branch>`) and run `/qa-cycle` from there.

### Useful flags

| Flag | Effect |
|---|---|
| `--non-interactive` | Answers the mechanical questions for you and keeps going while rounds find and fix blocking issues (up to round 4). Never approves. |
| `--auto-approve` | Skips only the final "approve?" confirmation. Every gate still applies. |
| `--double` / `--triple` | Adds one or two second-opinion reviewers from other model providers. Needs `second_opinion.reviewers` configured. |

Flags apply to one invocation. Pass them again when you start the next round.

### A separate QA identity (optional)

Without a token, round notes post under your own forge account and approval never
happens. With one, notes and approvals come from a separate QA account, so they are not
mistaken for the author's. Fix commits always use your own credentials. Run `/qa-init`
to store one. It is checked against the forge
before it is saved, and kept outside the repository with mode 600.

## Configure

Zero configuration required for the common case: branches are derived at runtime from the
MR/PR itself. Everything else is optional and lives in
`.claude/skills/qa-cycle/config.json` in your project. See
[docs/CONFIGURING.md](docs/CONFIGURING.md).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

Apache-2.0. See [LICENSE](LICENSE).
