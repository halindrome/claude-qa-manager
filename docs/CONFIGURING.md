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
             "security_stage": true, "lens_tags": ["schema", "api"] }
  }
}
```

`lens_tags` must be an **array**. A scalar silently disables every conditional lens for
that target, so preflight rejects it rather than degrading quietly. Known tags — these
are **tags, not lens names**; each enables the lens beside it:

| tag | enables lens |
|---|---|
| `schema` | `schema-propagation` |
| `api` | `api-envelope` |
| `ui` | `ui-styling` |
| `perf` | `performance` |

Writing the lens name (`ui-styling`) instead of the tag (`ui`) is the common mistake: it
is not fatal, but the tag is inert and preflight warns `unknown_lens_tags`. The
authoritative list is `KNOWN_LENS_TAGS_RE` in `lib/preflight.sh`.

## `contract` — where acceptance criteria come from

Every round verifies the MR against a contract: the linked ticket's acceptance criteria
when one can be found, otherwise criteria synthesized from the MR title and description.

```json
{ "contract": { "tracker": "auto", "ticket_pattern": "[A-Z]+-[0-9]+", "min_description_length": 200 } }
```

| `tracker` | references looked for | fetched by |
|---|---|---|
| `auto` (default) | — | `jira` when an MCP server or plugin named `jira` is registered, else `forge` |
| `jira` | ids matching `ticket_pattern` | the Jira MCP (`mcp__jira__jira_get`) |
| `forge` | `#123` and `…/issues/123` | the GitHub or GitLab CLI you already use for the MR |
| `none` | nothing | — always synthesized |

Set `tracker` explicitly when `auto` guesses wrong — most often a Jira MCP registered
under another name. `ticket_pattern` applies to `jira` only. An MR with no ticket and a
description shorter than `min_description_length` characters is blocked rather than
reviewed against nothing.

None of this degrades silently: an unknown `tracker`, an invalid `ticket_pattern`, and a
round whose referenced tickets could not be fetched each raise a warning, and the last
records `contract_source=ticket-unfetched` instead of a plain synthesized contract.

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

### Which model reviews

```json
{ "review": { "model": "opus", "lens_models": {}, "allowed_models": ["opus", "fable"] } }
```

These are the shipped defaults. Every lens runs on a **named** model — `lens_models[<lens
name>]`, else `model` — and never on your session's model, so starting `/qa-cycle` from a
Haiku session still gets a frontier panel. `allowed_models` is the floor: an enumerated
list, matched as a case-insensitive substring (`opus` admits `claude-opus-5` and
`opus[1m]`). Preflight exits 2 if any configured model, or an empty `model`, is not on it,
and `run-panel.sh` checks the model each lens *actually ran as*: a lens below the floor is
recorded as `model_below_floor` and its findings are discarded. The `qa-manager` and
`qa-reviewer` agents pin `model: opus` for the Agent-spawned paths (the manager itself,
the sequential fallback, the fix-diff review).

`allowed_models` replaces rather than extends the default (jq `*` does not merge arrays).
Widening it is a deliberate statement about which models may review — not a way to make
a round start.

## `verify` — how a fix is checked before it is committed

Normally **empty**. The target's own test entry point is *discovered* (Makefile `test`,
`scripts.test`, `tox.ini`, `go.mod`, …), because your project already declares how it is
tested and a copy kept here would drift.

```json
{ "verify": { "command": "", "timeout_seconds": 900 } }
```

`command` — set only when detection is wrong, and prefer the per-target form
`targets.<name>.verify.command`, which wins. An override must name **another entry point
the project already provides** — never a piece lifted out of a detected recipe. A `test`
target is an interface; its recipe may bring up a container, seed fixtures, or wait on a
database, and a partial invocation still exits zero, so what you lose is lost silently.

`timeout_seconds` — how long the run may take before it is killed (TERM, then KILL, on the
whole process group). Detection proves an entry point *exists*; it never proves the command
*terminates*, and nothing checks that it is autonomous. A `scripts.test` that resolves to a
watcher, or a suite that reads stdin, would otherwise block the round forever. The runner
closes stdin and exports `CI=1`, which handles most of it; this is the backstop.

### The learned bound

The flat ceiling is safe but blunt: a 20-second suite that wedges still burns the whole
allowance. So the bound is also learned from how long this target's gate has actually taken.

```json
{ "verify": { "baseline": {
    "min_samples": 3, "window": 10, "multiplier": 5, "floor_seconds": 60
} } }
```

`multiplier` × the median of the last `window` durations, never below `floor_seconds` and
never above `timeout_seconds`. Below `min_samples` there is no baseline and the run reports
`limit_source: configured` — it does not invent one. **`min_samples: 0` turns the learned
bound off** and leaves the flat ceiling. Per-target `targets.<name>.verify.baseline` wins,
and merges over these rather than replacing them.

These are defaults, not laws — they were first chosen against one project's suite, so tune
them to yours. Two rules govern what gets measured:

- **Only the declared `verify.command` is recorded.** A round runs other commands through
  the same helper — a red-first check on one test file is seconds where the suite is
  minutes — and pooling them would let the narrow run set the bound for the suite.
- **Only runs that terminated are recorded.** Recording a timeout would ratchet the bound
  upward using the number that means "this did not finish".

Durations live outside the repo, in `~/.config/claude-qa-manager/verify-timings/`: they are
observed local data, not configuration, and one machine's timings are wrong for another's
hardware. Delete a file there to reset that target's baseline.

A killed run reports `timeout`, which is **not** a pass: like `none-found` it means the
round has no execution evidence, and the round note says the fixes went unverified. Raise
`timeout_seconds` for a genuinely slow suite; for a watcher, name the non-watch entry point
in `command` instead.
