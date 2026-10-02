# Contributing to claude-qa-manager

Thanks for considering a contribution. Bug reports, measurements from real review rounds,
and fixes are all welcome.

## Prerequisites

- Claude Code
- `bash` (3.2 or later), `git`, `jq`
- `gh` and/or `glab`, logged in, if you want to try a change against a real MR/PR

## Where things live

```text
skills/qa-cycle/   SKILL.md (the spine) + references/ (read on demand)
skills/qa-init/    thin setup skill; the mechanics are in lib/init.sh
agents/            qa-manager (runs one round), qa-reviewer (one lens)
lib/               preflight.sh, the forge seam, the panel driver, gates and helpers
config/            defaults.json, the shipped config layer
examples/          project-config templates
test/              preflight.test.sh, init.test.sh, no-private-identifiers.sh
docs/              CONFIGURING, CASE-STUDIES, ROADMAP
```

Read [docs/ROADMAP.md](docs/ROADMAP.md) before proposing a design change. It records
decisions already made and why, so they are not argued again. [CLAUDE.md](CLAUDE.md) is
the working guide for this repo, with the invariants below in full.

## Making a change

1. **Open an issue first** for anything non-trivial, so the approach can be agreed before
   you build it.
2. **Fork, then branch from `main`** (`fix/…`, `feat/…`, `docs/…`).
3. **Try it without installing:** `claude --plugin-dir /path/to/your/clone` loads your
   working copy for one session.
4. **Keep commits atomic**, one logical change each, in the form
   `type(scope): description` — types `feat`, `fix`, `docs`, `test`, `refactor`, `chore`.
5. **Run the checks** (next section) and open a PR against `main`.

## Checks

CI runs all of these on Ubuntu and macOS. Run them locally first:

```bash
bash test/preflight.test.sh          # ~4 min, real git fixtures; must end 0 failed
bash test/init.test.sh
bash test/no-private-identifiers.sh  # must print ok
claude plugin validate .
```

If you changed `skills/qa-cycle/SKILL.md`, also run
`claude --plugin-dir . plugin details claude-qa-manager` and report the on-invoke token
cost in the PR. The spine is kept deliberately small. New depth goes in `references/`,
which costs nothing until read, and a rise in the spine's cost needs a reason.

**Dogfood it.** For a change to review behaviour, run `/qa-cycle` on your own PR with
`--plugin-dir` pointing at your branch, and link the round notes in the PR description.

## Rules that are enforced in review

Each of these exists because breaking it shipped a real defect. Details and the
incidents behind them are in [CLAUDE.md](CLAUDE.md) and
[docs/CASE-STUDIES.md](docs/CASE-STUDIES.md).

- **An absent check never reports as a pass.** A gate that did not run says so
  (`skipped:not-configured`, `none-found`, `unconfirmed`), never `clean`. A new gate needs
  a "did not run" state.
- **Tests drive the real code.** Never copy production logic into a test and assert
  against the copy. Show the test fails without your fix — in an isolated copy of the
  tree, not the tree you are developing in.
- **Reconcile every site.** Before calling a fix done, search for every other place that
  states or does the same thing and fix those too.
- **State the rule, not the changelog.** Comments, `SKILL.md` and tests say what the code
  does now and why — not what it used to do. History goes in `docs/ROADMAP.md`.
- **A rule keeps its one-line rationale** next to it, so nobody deletes it without
  knowing what it bought.
- **Never cut review cost by using a cheaper model.** Narrow the lenses or the panel width
  instead.
- **Schema detection uses path checks only.** Do not add DDL content scanning.
- **Nothing private in any commit** — files, messages or author identity. The history is
  public and permanent. `test/no-private-identifiers.sh` scans all of it and fails on
  secret-shaped strings such as tokens and keys.

## Portability

The scripts run under macOS's bash 3.2 and under GNU userland on Linux. The traps that
have actually broken CI:

- `mktemp` templates need `XXXXXX`; GNU rejects `mktemp -t name`.
- `stat`: try the GNU form (`stat -c`) first — GNU `stat -f` means *filesystem* and
  succeeds with the wrong answer.
- Inside `$( … )`, write case patterns as `(pat)`; bash 3.2 misreads a bare `pat)`.
- `date`: `-r <epoch>` is BSD; fall back to `-d "@<epoch>"`.
- Use `grep -F` for literal text containing a backslash or backtick.
- Your interactive shell may be zsh, which does not word-split `$var`. Run scripts with
  `bash` explicitly and use arrays (`"${arr[@]}"`).

## Releasing (maintainers)

Bump the version in `.claude-plugin/plugin.json`, both places in
`.claude-plugin/marketplace.json`, and the status line in `README.md`. Installed copies
only update when the version changes.

## Reporting bugs

Open an issue with:

- `claude --version` and the plugin version
- your OS, and GitLab or GitHub
- the command you ran and what happened; for a round, the `warnings` and the relevant
  fields from `preflight.json` in the round's scratch directory

Remove tokens, internal hostnames and private repository names before you paste
anything.

## License

By contributing, you agree that your contributions will be licensed under the
[Apache-2.0 License](LICENSE).
