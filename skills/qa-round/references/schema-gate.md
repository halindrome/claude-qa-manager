# Schema-change detection and the approval gate

Preflight emits `schema.detected` and `schema.state`; the spine reads them. This file is
the reasoning — why the check is a path check and nothing more, and why the gate cannot be
relaxed by any flag. See also `docs/CASE-STUDIES.md` §schema-drift.

### Step 3A.0.1 — Schema-change detection (drives the Step 3E approval gate)

Schema changes have repeatedly broken production — the the schema-drift case
`properties.processIndividually` change shipped without the cluster template DB
being refreshed, so production tenants never got the column and every the release
instance broke. Every round therefore runs a deterministic scan and records
whether this MR touches the database schema. The result (`SCHEMA_CHANGE_DETECTED`)
drives the **mandatory human approval gate** in Step 3E: a schema-change MR is
**never auto-approved**.

**The schema is whatever `schema.files` names** — the file(s) a provisioner reads
to create a new instance. The scan is one path check per configured file, and
preflight performs it (emitting `schema.detected` and `schema.state`); read those
values, do not re-run the check by hand:

```bash
# What preflight does. Shown so the rule is legible — not to be re-implemented.
# With schema.files EMPTY the gate does not run and reports
# schema.state=skipped:not-configured. That is NOT a pass: an unconfigured gate
# reporting "clean" would certify a check that never happened.
SCHEMA_FILES="$(git diff --name-only --no-renames "$DIFF_RANGE" \
  | grep -E "$CONFIGURED_SCHEMA_PATHS_RE" || true)"
# --no-renames is load-bearing: without it git prints only a rename's DESTINATION,
# so `git mv db/template.sql db/renamed.sql` + an ALTER slips through un-gated.
[ -n "$SCHEMA_FILES" ] && SCHEMA_CHANGE_DETECTED=true || SCHEMA_CHANGE_DETECTED=false
```

> **Do NOT reintroduce a DDL content scan.** This step used to also glob `sql/`
> and `*.sql` and grep the diff CONTENT for DDL keywords. That matched DDL in any
> non-`.md` file — test fixtures, code comments, even test *labels* — so MRs
> touching zero SQL were reported as schema changes and armed the human-approval
> gate over a `printf` string. Defending it required a self-trip guard, a regex
> extractor and behavioural probes; that machinery produced five QA findings of
> its own and protected nothing real. A path check cannot match a comment. See
> root `CLAUDE.md` rule 13.
>
> `apps/api/sql/` (including `migrations/` and `alters/`) is **not** the
> live schema — see rule 13 for why, including the misleading README/Makefile
> there.

Write the evidence to `$QA_SCRATCH/schema-change.md` (preflight already does):
whether `the configured schema file` changed, and if so that the MR requires human
approval and a cluster Dev/Prod Template DB refresh before rollout.

When `SCHEMA_CHANGE_DETECTED=true`, **immediately announce to the operator**:

> ⚠️ **Schema change detected in this MR.** It will NOT be auto-approved; it
> requires explicit human approval at Step 3E and a rollout confirmation. See
> `docs/runbooks/schema-change-rollout.md`.

> **Code-only schema dependencies are NOT detectable here, by design.** the schema-drift case
> was code reading a column that never reached the template — no file-list check
> and no content regex ever caught that. The `schema-propagation` **review lens**
> catches it, and it runs on every `api` MR via that target's `schema`
> lens_tag, independent of this flag. When the lens reports one, the orchestrator
> MUST set `SCHEMA_CHANGE_DETECTED=true` before Step 3E so the gate fires.
