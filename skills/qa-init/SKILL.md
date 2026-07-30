---
name: qa-init
description: "Set up the current project to use claude-qa-manager. Detects the forge from the git remote, checks required tooling and authentication, writes the optional project config (targets for a monorepo, schema-gate paths), and walks the operator through storing a QA agent token. Use when someone asks to install, initialise, configure, or set up QA rounds in a repo, or when /qa-cycle reports missing configuration."
---

# Set up claude-qa-manager in this project

Deliberately thin. The mechanics live in `${CLAUDE_PLUGIN_ROOT}/lib/init.sh`, which is
tested; this file only decides *which* subcommand to run and asks the judgment
questions the script cannot answer for the operator.

**Never handle the QA token yourself.** Do not ask the operator to paste a token into
the conversation, do not read a token file, and do not echo one. Run
`init.sh token`, which prompts with terminal echo disabled, verifies the token against
the forge, stores it outside the repository at mode 600, and only then reports success.
A token pasted into a chat transcript is a leaked token.

## 1. Always start with the read-only check

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/init.sh" check
```

It writes nothing. Report its output, then act on what is missing:

- **Missing `git`/`jq`, or the forge CLI unauthenticated** — stop and tell the operator
  the exact command to run (`glab auth login` / `gh auth login`). Nothing else will work.
- **No `origin` remote** — the forge cannot be detected. Ask which forge they use before
  going further.
- **Everything present, no project config** — that is a *valid* state, not a problem.
  Branches derive from the MR/PR at runtime, so a single-repo project needs no config.
  Only continue to step 2 if they need the schema gate or monorepo targets.

## 2. Project config — ask, do not assume

Two questions genuinely need a human:

**Schema files.** Which path(s), if any, *are* the schema — the file(s) a provisioner
reads to create a new instance? This is not "which files contain SQL": migrations and
per-table artifacts are not the schema. If the answer is none, say plainly that the
schema gate will report `skipped:not-configured` on every round, and that this is an
absent check rather than a passing one.

**Monorepo targets.** Only if components are reviewed as separate MRs. Ask for each
component's path and the commit-message scope token, then write them into `targets`.
`examples/monorepo-submodules.json` is the shape.

Then:

```bash
QA_INIT_SCHEMA_FILES="<comma,separated,paths>" bash "${CLAUDE_PLUGIN_ROOT}/lib/init.sh" config
```

The script prints the merged result and asks before writing. It merges into any existing
config and never removes keys, so re-running is safe. For monorepo targets, edit the
written file directly afterwards — the script only handles the schema question.

## 3. QA agent token — optional, and fine to skip

Explain the trade-off, then let them choose:

- **With a token** — round notes and approvals are attributed to a QA identity, distinct
  from the author. Fix commits still use the operator's own credentials.
- **Without one** — everything still works; notes post under the operator's identity and
  approval is skipped entirely.

If they want one:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/lib/init.sh" token
```

This must run in a real terminal so the hidden prompt works. If the environment is not
interactive, tell them to run it themselves rather than working around it.

## 4. Confirm

Re-run `init.sh check` and report the result. Then tell them the entry point:
`/qa-cycle <MR-or-PR-number>`, plus a target name if they configured monorepo targets.
