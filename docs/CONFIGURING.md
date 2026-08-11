# Configuring

**Most projects need no configuration.** Branches are derived from the MR/PR at runtime,
so a single repo with an `origin` remote works out of the box. Everything below is
optional.

The fastest path is `/qa-init`, or directly:

```bash
bash lib/init.sh check    # read-only: what is present, what is missing
bash lib/init.sh config   # write/update the project config
bash lib/init.sh token    # store + verify a QA agent token
```

## Resolution order

Three layers, shallow-merged per top-level key, later winning. jq's recursive merge means
a project can override one nested key without restating its block.

| Layer | Path | Holds |
|---|---|---|
| shipped | `config/defaults.json` | policy defaults |
| user | `~/.config/claude-qa-manager/config.json` | credentials, approval policy |
| project | `<repo>/.claude/skills/qa-cycle/config.json` | targets, schema paths |

The split is deliberate: a project should never restate credentials, and a user config
should never need to know a repo's layout. The project file contains no secrets and
belongs in version control.

## `forge` — only needed when the hostname does not say

The forge is detected from the `origin` remote: a URL containing `gitlab` selects the
GitLab backend, `github` selects GitHub. That covers gitlab.com and github.com with no
configuration at all.

It does **not** cover a self-hosted GitLab at `git.example.com` or a GitHub Enterprise
instance — neither hostname contains either string. Rather than guess (a GitHub repo
driven through `glab` fails ten steps later in ways that look like an auth problem),
preflight stops with exit 2 and asks you to say which it is:

```json
{ "forge": "gitlab" }
```

`QA_FORGE=gitlab|github` in the environment overrides the config key for a single run.

## `schema.files` — the one setting worth stopping for

```json
{ "schema": { "files": ["db/template.sql"], "runbook": "docs/runbooks/schema.md" } }
```

These are the file(s) a provisioner reads to create a new instance. A change to one arms
a **mandatory human approval gate**: the QA agent may add a second approval but never the
first, and no flag relaxes it.

**This is not "files containing SQL."** Migrations and per-table artifacts are not the
schema. Matching is by path only — never by content — because content scanning matches
DDL in test fixtures, comments, and even test labels. See
[CASE-STUDIES.md](CASE-STUDIES.md) §schema-drift for what that cost.

**Either spelling of a monorepo path works.** For a target rooted at `apps/api`, both
`apps/api/db/template.sql` and `db/template.sql` match — the target's own path prefix is
stripped before matching. This used to matter: a submodule target's `git diff` prints
`db/template.sql`, so a superproject-relative config matched nothing and the gate reported
`detected=false, state=checked` on an MR that *did* change the schema.

**Leaving it empty is a real choice with a real consequence.** The gate reports
`schema.state = skipped:not-configured`, which is an *absent* check, not a passing one.
Nothing silently claims to have verified your schema.

Note the gate only catches changes *to* those files. Code that reads a column the schema
file never gained is caught by the `schema-propagation` review lens instead — enable it
with a target's `schema` lens tag.

## `targets` — only for a monorepo

Needed only when components are reviewed as independent MRs. `scope` is the
commit-message token used for fix commits (`fix(<scope>): address QA round N`).

```json
{
  "targets": {
    "api": { "path": "apps/api", "remote": "origin", "scope": "api",
             "security_stage": true, "lens_tags": ["schema", "api-envelope"] }
  }
}
```

`lens_tags` must be an **array**. A scalar silently disables every conditional lens for
that target, so preflight rejects it rather than degrading quietly. Known tags:
`schema`, `api-envelope`, `ui-styling`, `performance`.

## `qa_agent` — optional second identity

Used only for round notes and approvals. Fix commits and pushes always use the
developer's own credentials.

```json
{ "qa_agent": { "token_env": "QA_AGENT_TOKEN",
                "token_file": "~/.config/claude-qa-manager/qa-agent-token",
                "expected_username": "qa-bot" } }
```

Resolution is env var first, then file. `expected_username` is verified at preflight; a
mismatch degrades to the developer identity and skips approval rather than posting under
the wrong name.

Use `lib/init.sh token` rather than writing the file by hand — it verifies the token
against the forge *before* storing it, sets mode 600, and records the resolved username.
A stored-but-wrong token is worse than none, because the setup looks complete while
every note posts under the wrong identity.

**Never commit a token.** It lives outside the repo; `.gitignore` covers `*token*` as a
backstop, and CI fails on secret-shaped literals.

## `qa_agent.approval` — when the agent may approve

```json
{ "qa_agent": { "approval": {
    "min_clean_round": 2,
    "tiny_mr_relax_to_round_1": true,
    "tiny_mr_max_lines_changed": 50,
    "unapprove_on_dirty_reround": true,
    "allow_deferred_findings_exit": true } } }
```

`allow_deferred_findings_exit` is the escape hatch for a cycle that ends on diminishing
returns with findings still open. Without it, taking the panel's own advice to stop makes
an MR permanently unapprovable — an endless cycle becomes a stuck one. It requires a
human to defer each remaining finding explicitly, enumerated in a posted note. See
[CASE-STUDIES.md](CASE-STUDIES.md) §stop-rules-need-exits.

## `review` — panel shape

```json
{ "review": { "max_lenses": 6, "proportionality_strict_from_round": 3 } }
```

`max_lenses` is capped at 6, the measured concurrency ceiling for agent grandchildren,
which keeps the panel a single wave. To narrow a review, narrow a target's `lens_tags` —
**never** manage cost by downgrading the model. A cheaper reviewer is a weaker reviewer,
which defeats the point of the cycle.
