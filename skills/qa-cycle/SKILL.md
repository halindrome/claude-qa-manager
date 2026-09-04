---
name: qa-cycle
argument-hint: "<mr|pr-number> [target] [--double|--triple] [--reviewer=qwen-local] [--non-interactive] [--auto-approve] [--help]"
description: "Run a structured QA review cycle on a merge request or pull request: one round, then as many further rounds as the findings justify, up to approval. Takes the MR/PR number and an optional target name (e.g. /qa-cycle 123, or /qa-cycle 123 api in a monorepo). Each round runs a deterministic preflight (branch sync, ownership, round derivation, security-scan delta), fans out a 3-6 lens reviewer panel, posts a round note, and gates approval behind an explicit policy. Every finding is grounded in a linked ticket's acceptance criteria or a regression the diff introduces. Proportionality escalates with the round number and the panel can declare diminishing returns, so the cycle ends rather than looping forever. Branches derive from the MR/PR at runtime, so no configuration is required for a single repo; targets, schema paths, and QA-agent credentials come from optional layered config."
---

# QA cycle

Run a structured QA review cycle on a merge request or pull request: round 1, then further
rounds for as long as the findings justify one, ending in approval, a deferred-findings
exit, or a decision to stop. The steps below describe a single round; Step 3D decides
whether the cycle continues.

**How this file is organised.** This is the orchestration spine: what to do, in order, and
which value to read at each step. Deeper material lives in `references/` and is read only
when a step actually needs it — that keeps the cost of starting a round low. Every rule
here states its own one-line rationale; a rule whose justification lives only in a
reference file is a rule someone deletes later without knowing what it bought.

| Read when | File |
|---|---|
| preflight reports something surprising | `references/preflight-internals.md` |
| the target has `security_stage: true` | `references/sast.md` |
| a schema file changed, or the gate's reasoning is unclear | `references/schema-gate.md` |
| `review_mode == "sequential"`, no Agent nesting, or `--double`/`--triple` | `references/sequential-and-multimodel.md` |
| `MR_APPROVED=true` and this round found new blocking findings | `references/dirty-reround.md` |
| the round is approval-eligible | `references/approval.md` |
| a round produced observations | `references/observations.md` |
| `--help`, or no MR/PR number was given | `references/usage.md` |
| changing any of this | `references/design-notes.md`, `../../docs/CASE-STUDIES.md` |

---

## Step -1 — `--help`, or no MR/PR number

If argv has `--help`/`-h` or names no MR/PR number: print `references/usage.md` verbatim
and **stop** — no preflight, no spawn, no branch touched. It precedes Step 0.0 because
flags are parsed at Step 0, one step *after* preflight: in argv order a `--help` would
first sync a branch for a number nobody gave. Asking a question is not consenting to a
checkout.

---

## Configuration

Resolved by preflight from three layers (shipped defaults, user, project) and reported in
`preflight.json`. You do not read config files yourself. Most projects configure nothing;
see `docs/CONFIGURING.md`.

---

## Step 0.0 — Preflight (deterministic; run once per round, read the JSON)

The entire mechanical preamble is a single script — run it **once per round** (at the
start, and again before each subsequent round) instead of walking the model through each
shell step in its own turn. It is idempotent, and re-running it is what advances the
round and re-renders the proportionality tier together; see Step 3 and Step 3D:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh <MR_NUMBER> [TARGET]
```

It emits one JSON object to `$QA_SCRATCH/preflight.json` (and stdout) and
performs, deterministically, the mechanics that used to be Steps **0** (target +
base-branch resolution, MR inspection, ownership), **0.25** (QA-token resolve +
verify), **0.4** (`PROJECT`/`_ENC` + scratch dir), **0.7** (seed
`MR_APPROVED`), **2** (branch sync), **2.5** (the SAST driver — writes `sast.md`,
computes `sast.gate_state`), and **3A.0.1** (schema scan — writes
`schema-change.md`). Read `preflight.json` and hydrate the skill's variables from
it:

| JSON field | Skill variable(s) |
|---|---|
| `target_path`,`remote`,`scope`,`security_stage` | target registry values |
| `base_branch`,`base_branch_source` | `<base-branch>` (report the source) |
| `mr_title`,`mr_author`,`source_branch`,`target_branch`,`state`,`draft`,`changes_count`,`pipeline_status` | MR facts |
| `dev_user`,`is_own_branch` | `IS_OWN_BRANCH` (Step 3B ownership gate) |
| `qa_token_ok`,`qa_auth_user` | `QA_TOKEN_OK` (Steps 0.25/3C/3E) |
| `qa_token_env`,`qa_token_file`,`expected_qa_user` | how Step 0.25 resolves `QA_TOKEN` (env first, then file) and who it must resolve to. **Read these; never re-derive them** — a guessed name resolves EMPTY, and empty means "act as the developer". `CASE-STUDIES.md` §self-approval-fallback. |
| `mr_approved` | `MR_APPROVED` (Step 3B.6/3E) |
| `diff_scope.total_changed`,`diff_scope.is_tiny` | tiny-MR relax (Steps 2.5/3E) |
| `review_mode` (`manager`\|`sequential`) | Step 3A.1 routing (deterministic) |
| `lenses` (array, 3-6 names) | the lens panel the manager spawns (deterministic; Step 3A.1) |
| `schema.detected`,`schema.state`,`schema.evidence_path` | `SCHEMA_CHANGE_DETECTED` (Steps 3A.0.1/3E). `state` distinguishes a gate that ran from one that was never configured — only `checked` means it ran. |
| `sast.gate_state`,`sast.running`,`sast.report_path`,`sast.helper_reason` | `SAST_GATE_STATE`,`$SAST_REPORT` (Steps 2.5/3C/3E) |
| `contract.candidate_tickets`,`contract.title_ticket`,`contract.description_length` | Step 0.5 contract resolution |
| `docs_only` | Step 0.5 docs-only exemption |
| `round` | the round number for Step 3, derived from the MR's posted `## QA Round N` notes (max + 1). Never re-derive or shell-track it: each invocation is a fresh process, so a hand-tracked round resets to 1 and re-fires the round-1-only prompts late. |
| `proportionality_path` | the `## Proportionality` section injected verbatim into every lens prompt (Step 3A / the manager). Never empty; preflight escalates its contents at `round >= 3`. |
| `forge` (`gitlab`\|`github`), `forge_cli` (`glab`\|`gh`) | which backend `lib/forge.sh` dispatches to, and which CLI it drives. Everything that touches the forge goes through `forge_*` — never call `glab`/`gh` directly, or the step works on one forge only. |
| `project`,`project_enc`,`qa_scratch` | as named |
| `commit_subject` | the Step 3B fix-commit subject, already rendered — scopeless in a single-project repo |
| `verify.command`,`verify.source`,`verify.state`,`verify.kind`,`verify.build_command` | the target's OWN test/build entry point, discovered from its Makefile / package.json / tox.ini. Step 3B runs it before committing. `state=none-found` is not a pass; `kind=lint` is a linter, not a behavioural suite — run it and still report that nothing behavioural ran. |
| `layout.multi_target`,`layout.target_is_submodule` | whether this project HAS subprojects, and whether this target is one. Gate subproject wording (Step 4) on these; never assume a repo has parts. |

> `scope` is the target token; `diff_scope` is the diff numbers. preflight asserts the
> distinction before emitting, and Step 3B reads `.commit_subject` rather than either.
> Why the assertion exists: `references/design-notes.md`.

**Exit-code contract — honor it before anything else runs:**
- **`0`** — proceed. If `warnings` is non-empty, surface them.
- **`2`** — usage/config error **the operator can fix** (bad args, unknown target, missing tooling, unresolvable remote URL). STOP; fix and re-run.
- **`3`** — SOFT gate: the sync merge itself deleted files, net-negative (`sync.unexpected_deletions=true`). The merge is left **LOCAL and unpushed**; `sync.deleted_files` lists the casualties. Do NOT proceed silently — AskUserQuestion (rebuild-from-base vs. proceed anyway) with `sync.reason` and the deleted-file list. It asks because only a human can tell "the base deleted these" from "my work is being reverted".
- **`4`** — HARD STOP: the sync could not be performed safely (`sync.failed=true`; `sync.reason` says which). **No QA round may run** — a bad sync produces findings about a diff that is not the MR's. Report `sync.reason` and stop. An MR sourced FROM a protected branch lands here and gets no automated QA; that is deliberate.
- **`5`** — INTERNAL failure: an invariant inside preflight broke. A **bug in preflight**, not something re-running fixes — report it as such. Distinct from `2` so it cannot hide behind "usage error".

> Why each code is separate, and why the protected-source-branch case fails safe rather
> than degrading to read-only: `references/preflight-internals.md`.

**Warnings you must surface (`warnings[]`):**
- `unexpected_deletions` — pairs with exit 3 above.
- `sast_helper_failed` — the SAST helper exited non-zero (`sast.helper_reason` has the first stderr line). SKILL.md policy is that helper failure is a **MUST-ask-the-user** event (proceed without SAST vs. stop) — never silently continue.
- `sast_unrecognized_stub` — the helper exited 0 but emitted output preflight could not positively classify. `sast.gate_state` is `skipped:unknown`, which is **never** treated as a security review.
- `round_probe_failed:exit=<N>` — the notes probe failed, so `round` fell back to `1` and is **not** trustworthy. Not cosmetic: it re-fires round-1-only prompts and renders the *light* proportionality tier on a round that earned the strict one. Confirm the number with the operator before running the panel; the posted `## QA Round N` notes are ground truth.

**What still requires an LLM/interactive turn after preflight** (do these as before):
- **Step 0.5 — contract resolution.** Use `contract.title_ticket` / `candidate_tickets`: if present, `jira_get` + (synthesis / ambiguity AskUserQuestion); if `docs_only=true`, take the docs exemption; if `description_length < 200` and no ticket, BLOCK. preflight does only the mechanical ID extraction.
- The **round-1 skip-contract** AskUserQuestion + `--double` tip.
- The **SAST wait-gate** prompt (only when `sast.running=true` AND the round is approval-eligible) — the poll loop stays one Bash call.
- Argument flags (`--double`/`--triple`/`--reviewer=`) — parse from argv as in Step 0 (preflight does not consume them).

The sections below (Steps 0–0.7, 2, 2.5, 3A.0.1) remain the authoritative
**policy** — what each value means and how the gates behave — but their shell
**mechanics are now performed by preflight**. Do not re-run them by hand; read
the value from `preflight.json`.

---

---

## Step 0 — parse your own flags

Everything mechanical is preflight's; read its fields. Yours to parse from argv:
`--double`, `--triple`, `--reviewer=`, `--non-interactive`, `--auto-approve`
(`--help` was already handled at Step -1).

Policy detail: `references/preflight-internals.md`. The user-facing wording of every flag
is `references/usage.md`; change one and change both.

---

## Step 0.5 — Resolve the contract (JIRA lookup → synthesize → block)

Before any QA round runs, resolve a **contract** for this MR — the criteria the
reviewer will verify against. Four decision branches:

1. **Formal JIRA link on the MR.** Read the MR/PR through the forge seam
   (`forge_view_mr <target-path> <MR_NUMBER>`) and inspect `.description` for a JIRA
   URL or related-issue field. The seam normalizes GitLab and GitHub to one shape,
   so this branch does not need to know which forge it is on. If one is present, extract the ticket ID (e.g., `PROJ-1234`) and call
   `mcp__jira__jira_get` on it. Capture `summary`, `description`, and any
   acceptance-criteria custom fields. Record `contract_source=jira:<TICKET>`.

2. **Mentioned ticket ID in title or description.** If no formal link, regex-scan
   the MR title + description for `[A-Z]+-\d+`. For each match, call
   `mcp__jira__jira_get`. If one or more resolve successfully, ask the user via
   AskUserQuestion: *"Is `<TICKET>` (`<summary>`) the intended contract for this
   MR?"* Options: yes (use it) / no — try next candidate (if more) / none of
   these (proceed to synthesis). Record `contract_source=jira:<TICKET>` on
   confirmation.

3. **Synthesize from MR title + description.** If no ticket is found or the user
   declined all candidates, synthesize a contract from the MR title and
   description. Record `contract_source=synthesized`.

4. **BLOCK.** If the MR description is under ~200 characters AND no ticket was
   matched, STOP. Display: *"Cannot form a contract for this MR. Link a JIRA
   ticket or flesh out the MR description with acceptance criteria, then re-run
   `/qa-cycle`."* Do NOT fall back to freeform findings.

Always re-resolve the contract on each `/qa-cycle` invocation (including subsequent rounds) and overwrite `$QA_SCRATCH/contract.md`. A stale `contract.md` from a previous round MUST NOT be reused — the MR description or linked JIRA may have changed between rounds, and silently inheriting an out-of-date contract would let those changes slip past QA. The scratch directory is for cross-round artifacts whose authority does not change (e.g. per-round notes); the contract is not one of those.

Write the resolved contract to `$QA_SCRATCH/contract.md` (see Step 0.4 for the per-invocation scratch directory), formatted as:

```
# Contract (source: <jira:TICKET | synthesized>)

Ticket: <TICKET or "n/a">
Summary: <MR title or JIRA summary>

## Acceptance criteria
- <criterion 1>
- <criterion 2>
...
```

This file is passed to both the Claude reviewer (via the `## Contract` section
of the Step 3A prompt) and to every second-opinion shim
(`do-reviewer.sh` / `qwen-reviewer.sh`) via `--contract-file`.

---


Examine the changed file list.

**If the MR touches only documentation, CI config, or repo metadata** (e.g., `.md` files, `.gitlab-ci.yml`, `.gitignore`, `devbox.json`, `README`, `CLAUDE.md`, `package.json` version bumps only) — announce that the QA round requirement does not apply to this MR and offer to post a note on the MR confirming the exemption. Stop here unless the user wants to continue.

**Otherwise**, continue to Step 0.7.

---

---

## Step 2.5 — security-scan delta

preflight runs the helper and emits `sast.gate_state`, `sast.running`, `sast.report_path`.

Only `clean` means a scan actually ran. Every `skipped:*` value means it did not, and none
may be treated as a security review. Pass the report into the panel and include it in the
round note verbatim.

If `sast.running=true` **and** the round is approval-eligible, prompt before continuing —
approving with a running scan means the round certifies a security delta it never saw.

`skipped:runner-unavailable` means the scan jobs never got a runner. **Not waitable** — the
operator must retry them — and not a finding either: report it as "did not run", never as a
failure to fix. It exists because an unrun job uploads no artifact, and a missing artifact
used to print *"likely no NEW findings"* under a `## NEW SAST findings` header, so a scan
that never executed classified as `clean`.

**The security claim must name the commit it rests on.** preflight ran before this round's
fix commit existed, so `sast.*` describes the *pre-fix* head. If Step 3B commits, say so in
the note — quote the pipeline id and its sha — rather than writing an unqualified "no new
security findings". A round once asserted security-clean citing a pipeline for a commit two
ahead of the one it approved.

Detail, including the wait-gate and the state contract: `references/sast.md`.

---

## Step 3 — Run QA Round N

Seed the round number from `preflight.json`'s `round` field — do NOT start at 1 and do
NOT re-derive it by hand. preflight computes it from the MR's posted `## QA Round N`
notes (max + 1), which is the only source that survives a fresh process; a hand-tracked
counter silently resets to 1 on every invocation and re-fires the round-1-only prompts
on a late round.

**Never hand-increment the round for a subsequent round in the same session — re-run
`preflight.sh` instead** (it is idempotent, and Step 2's re-sync before each round is
required anyway). `preflight` derives the round from the notes posted so far AND renders
`proportionality.md` for that round in the same pass, so the two can never disagree.
Bumping the number in the shell escalates only the *number*: the already-written
`proportionality.md` still holds whatever tier was current at preflight time, so a
session rolling 2 -> 3 would inject the **light** mandate into a round-3 panel and the
escalation would silently no-op on the one transition it exists for. The round note for
round N must be posted before re-running preflight, since that note is what makes the
next derivation return N+1.

### Pre-round-1 only — skip-verification prompt + `--double` reminder


On **round 1 only** (and never on subsequent rounds):

1. Ask via AskUserQuestion: *"Skip Contract Verification for this MR? Default:
   No."* Options (default-first):
   - *"No, run Contract Verification (recommended)"* — sets
     `skip_contract_verification=false`.
   - *"Yes, skip"* — sets `skip_contract_verification=true`.

   Record the answer. It is passed to the reviewer prompt (and to the Qwen
   wrapper via `--skip-contract` when `true`). The same value applies to every
   round in this invocation; the question is NOT re-asked at round 2+.

2. If `DOUBLE=false`, emit this one-line notice (not a question):

   ```
   ◆ Tip: pass --double for a second-opinion review via DigitalOcean
     serverless inference (deepseek-v4-pro, ~$0.12/round), or --triple to
     add a third openai-gpt-5.3-codex review (~$0.30/round total). Requires
     DO_LLM_API_KEY env var. See ${CLAUDE_PLUGIN_ROOT}/lib/do-reviewer.sh.
   ```

   Suppress this notice when `DOUBLE=true` or when the current round is ≥ 2.


## Step 3A.0.1 — schema-change detection

Read `schema.detected` and `schema.state` from `preflight.json`; do not re-derive them,
and never scan diff content for DDL.

- `state = checked`, `detected = true` → set `SCHEMA_CHANGE_DETECTED=true`. This arms a
  **mandatory human approval gate**: the QA agent may add a second approval, never the
  first, and no flag relaxes it. Announce it to the operator immediately.
- `state = skipped:not-configured` → the gate **did not run**. That is an absent check, not
  a pass. Say so rather than implying the schema was verified.

A path check cannot catch code that reads a column the schema file never gained. That is
the `schema-propagation` lens's job, and when it reports one you MUST set
`SCHEMA_CHANGE_DETECTED=true` before the approval step.

Reasoning: `references/schema-gate.md`.


### Step 3A.1 — Delegate the round to the QA manager (default path)

This is the **default review path**. Routing is **deterministic from preflight**:
take this path when `review_mode == "manager"` (non-trivial diff), and the Step 3A
sequential fallback when `review_mode == "sequential"` (tiny diff — a single
reviewer beats the overhead). The one runtime exception preflight cannot predict:
if the **manager spawn is refused** in this runtime (no Agent nesting), fall back to
sequential Step 3A regardless of `review_mode`. That test is about the manager only:
the lenses are subprocesses, so nesting depth does not constrain the panel.
`DOUBLE`/`TRIPLE` do
**not** change this routing — the manager runs the preflight-selected lens panel
regardless; the multi-model flags only add second-opinion shims inside it.

**Why a manager subagent, not the `Workflow` tool** — a clean main loop, and hooks that
reach the lenses. Reviewer correctness depends on neither: `references/design-notes.md`.

So: **main spawns ONE `qa-manager` Agent** (background); it runs the panel with
`lib/run-panel.sh` (each lens a `claude -p` subprocess, so the model cannot invent a
model or forget a lens — the why is in that script's header), merges and dedupes,
renders `$QA_SCRATCH/note-round<N>.md`, optionally posts it, and returns a compact
verdict + a `decisions_needed` list. The panel is preflight-selected (3-6 lenses,
capped at 6). The full contract lives in `agents/qa-manager.md`; this step is the
main-loop side — how to invoke it and what to do with the verdict.

**Invoke it** with the Agent tool, `subagent_type: "claude-qa-manager:qa-manager"` and
**`run_in_background: true`** — not optional: a foreground return lands the whole round
in this context, the one thing the manager exists to prevent. A backgrounded agent
returns a stub and a transcript pointer you must never read. Pass:

```
brief_path=<preflight.json .manager_brief_path>
post_note=<true|false>        # true = the manager posts the round note itself (hands-free)
non_interactive=<true|false>  # from --non-interactive; it still returns decisions_needed
DOUBLE=<t|f>  TRIPLE=<t|f>  reviewer_override=<qwen-local|"">
skip_contract_verification=<true|false>
```

**Always the plugin-qualified `claude-qa-manager:` prefix**, wherever an agent is
spawned: a bare name resolves only while no sibling QA plugin claims it, and where one
does the spawn fails outright — observed live.

Everything else the manager needs — branches, diff range, lens panel, forge, every
scratch path, the token env/file pair, `mr_approved`, `approval_eligible` — is already
rendered in that brief by preflight. **Do not re-derive or re-type those values.** Only
the five above depend on this invocation's flags and your Step 3D/3E decisions, so only
they are passed here.

**Interactive vs. hands-free split.** The manager cannot call `AskUserQuestion`,
so it never approves, never applies fixes, and never disambiguates a contract —
it returns those as `decisions_needed`. The main loop:

- reads the compact verdict;
- if `post_note=false` **or `note_posted=false`**, posts `note_path` itself
  (Step 3C); otherwise the manager already posted — record `note_url`. A
  `note_posted=false` on a `post_note=true` round is expected in exactly two
  cases: the `unapprove_before_post` and `post_after_fixes` decisions below;
- resolves `unapprove_before_post` FIRST when present — run the Step 3B.6
  revocation, *then* post `note_path`. This ordering is the whole point of the
  decision: the findings must not appear on a still-approved MR;
- resolves `post_after_fixes` by running Step 3B, appending one `QA-Fix-Commit`
  trailer per commit it made to `note_path`, and posting *that* — the manager runs
  before any fix commit exists, so a note it posted could never carry the trailers
  and the next round's `qa_fix_commits` would come back empty. With
  `unapprove_before_post` too: revoke, fix, append, post — one post, not two;
- sets `SCHEMA_CHANGE_DETECTED=true` when the verdict's
  `schema_change_detected` is true (arms the Step 3E the schema-drift case gate);
- sets `ROUND_HAS_CRITICAL_OR_MAJOR` from `counts` (Step 3B.6);
- resolves each `decisions_needed` entry: `approval` → the Step 3E confirm;
  `fixes` → the Step 3B ownership-gated triage; `contract_disambiguation` →
  re-resolve Step 0.5; `sast_wait` → the Step 2.5 gate;
  `diminishing_returns` → present the reasoning and ask whether to end the cycle.
  If they end it, every remaining confirmed critical/major finding must be explicitly
  deferred and enumerated in a posted note — that is what makes the Step 3E
  deferred-findings exit available. Never continue silently when it is raised.
  **Put the case once, then take the answer.** If they want another round, run it —
  do not re-argue, and never write "the operator explicitly deferred" about a deferral
  you talked them into: consent recorded that way is indistinguishable from consent
  volunteered, and the note is the only record anyone reads later.
- **`--non-interactive`**: pre-answer only the decisions whose default is *mechanical* —
  it may never invent a human's answer. `approval` is not defaultable (needs
  `--auto-approve` too), and two prompts are never answered at all: the **schema-change
  rollout ACK** (silence is not an ACK — that is the schema-drift failure mode; record
  `blocked: schema change rollout not acknowledged`, finish the round, stop before
  approval) and the **exit-3 unexpected-deletions gate** (stop and report `sync.reason`;
  never guess at a destructive sync). Per-decision policy:
  `references/non-interactive.md`.

**What main does with the verdict** (the manager's own contract — merge rules, lens
failure handling, the verdict schema — lives in `agents/qa-manager.md`; do not restate
it here):

- `schema_change_detected: true` → set `SCHEMA_CHANGE_DETECTED=true` **before Step 3E**.
  This arms the schema gate; dropping it silently un-arms it.
- **All** lenses in `failed_lenses` → a FAILED round: no clean post, no approval, re-run.
  Some failed → the missing axes are not clean, and the note says so.
- Read `note_path` only if you need the markdown; the verdict alone drives Steps 3B-3E.
- `tree_mutated: true` → a lens wrote to the shared working tree during the review.
  **Stop before Step 3B.** Show the changed paths and ask the user what to keep: some
  of this round's findings may describe the mutation rather than the MR, and a fix
  commit would capture a lens's leftovers. Never auto-revert — you cannot distinguish
  a lens's stub from the author's own uncommitted work.
- `qa_introduced_blocking >= 2` → surface it verbatim from the note: this cycle is
  largely fixing its own earlier fixes. **Report only** — whether to revert, patch
  again, or stop is the human's, because attribution cannot tell a wrong premise from
  a sloppy fix. (At half or more of the blocking findings the manager also raises
  `diminishing_returns`, which is the decision that actually offers to stop.)

**Never manage round cost by downgrading the model** — a cheaper reviewer is a weaker
reviewer, which defeats the cycle. The levers are panel width (`lens_tags`) and the
trivial-MR gate. Why the panel is not N× a serialized review: `references/design-notes.md`.


## Step 3A / 3A.2 / 3A.3 — sequential fallback and extra reviewers

Not used on the default path. Take these only when `review_mode == "sequential"`, an Agent
spawn was refused, or `--double`/`--triple` was passed.

On this path **you** own the bookkeeping the manager would otherwise do — the `fanout`
stamp, rewriting `status` at each phase, the before/after tree snapshot, and
`record-timing.sh`. Skip them and the round reports no progress, detects no tree
change, and records no timing. The reference has the exact commands.

See `references/sequential-and-multimodel.md`.


### Step 3B — Apply fixes (ownership-gated)

Once the sub-agent returns its report:

**If `IS_OWN_BRANCH=false` (someone else's MR):**

Do NOT apply fixes automatically. Instead:
1. Present the findings to the user.
2. Ask via AskUserQuestion: *"This branch is authored by {author}. Would you like to apply fixes anyway, or just post the QA report for the author to address?"* Options:
   - **"Post report only (Recommended)"** — skip fixes, proceed to Step 3C to post the report. The author applies their own fixes.
   - **"Apply fixes anyway"** — proceed with fixes below, but include a note in the MR comment that fixes were applied by the QA reviewer and the author should review them.
3. If "Post report only" is selected, skip directly to Step 3C.

**If `IS_OWN_BRANCH=true` (your own MR):**

1. Read each finding carefully. For findings marked "hypothetical" or "minor" with no
   confirmed reproduction, ask the user whether to fix them before proceeding — with
   one exception and one warning, both about the cycle's own work:

   | the finding is | do |
   |---|---|
   | blocking (critical/major) | fix it, as below — unchanged |
   | minor + `qa_introduced` + `in_test_file` | **do not offer it as a fix.** Send it to the observations ledger (Step 3C.5) and the carried-forward list. Say you did. |
   | minor + `qa_introduced`, not a test file | ask — and say that fixing it costs a commit, a post, and another full panel |
   | minor, not `qa_introduced` | ask, as before |

   Why: a minor defect in test scaffolding an earlier round wrote is the largest single
   category of self-inflicted finding, and fixing one buys a round whose whole subject is
   that fix. The line is severity **plus location**, never "we wrote it, so skip it".

   **`in_test_file` absent is not `false`** — the sequential and `--double` paths never
   call `attribute-findings.sh`. Absent means unknown, so **ask**: reading a missing field
   as "not a test" diverts nothing while looking like a working rule (invariant 2).

   Measurements and the class breakdown: `references/fix-review.md`.
2. **Read `tooling.fix_mandate_path` from `preflight.json` before you edit anything.** It is
   never empty: it states whether a code-navigation graph is available this session and how
   to find every affected site under that regime. You are the only participant in the round
   who edits code and the only one who was not handed the navigation mandate — the lens
   reviewers got theirs at spawn and are forbidden from prescribing fixes. Follow it.
3. For confirmed and critical/major findings, fix them in the target codebase in this session.
   **A finding names one site; it does not bound the defect.** Reconcile every site, per the
   fix mandate — with a graph that means `trace_path` over the callers, without one it means a
   deliberate, and explicitly best-effort, text sweep. A fix that hardens the cited line while a
   sibling still asserts the opposite is the single most common defect this cycle re-finds, and
   it is what makes round N+1 pay a full panel to catch round N's fix.
4. **Run the project's own checks before committing.** `verify.command` in `preflight.json`,
   from the target directory; `verify.source` names the file it was discovered in
   (`verify.build_command` too when present). This is the step whose absence produces the
   tail-chasing pattern: a round's fix is otherwise unverified until the *next* round's full
   panel finds it broken.
   **This is the only place the suite runs** — lenses are forbidden from running it,
   so skipping here leaves the round with no execution evidence at all, and every
   claim in it rests on reading. If the detected command is unsafe to run at this
   point, that is what `targets.<name>.verify.command` is for: say so and ask,
   rather than skipping silently. See `docs/CASE-STUDIES.md` §unrun-suite.
   - **A new or changed test must be shown to fail without the fix, and you must see it
     fail FIRST** — read the failure message; it has to name the behaviour under test. A
     test that passes either way verifies nothing while looking like proof.
   - **A coverage-only test needs a check that can fail too.** Targeting code this round
     did NOT change makes the rule above pass for free, so mutate the code, confirm red,
     restore. That exemption is where the last cycle's surviving defects landed.
   - **The harness is where these tests break, not the assertions** — a wrong exit status,
     a `chdir` in a constructor, the wrong shell. Each looks like a code defect and costs
     a round.
   - **Put a new test where that subsystem's siblings live**, never at the suite root.
   - **Name the command you ran, verbatim, in the round note.** If it was narrower than
     CI, say so: a subset that passes locally and goes red in CI buys another round.
   - `verify.state == none-found` is **not** clean, and `verify.kind == "lint"` is **not**
     behavioural verification. Run the linter, but the note says no behavioural suite was
     found. If the project has a job the detector cannot derive, name it and say it did
     not run, or point `targets.<name>.verify.command` at it.
   - If the checks fail, fix that before committing. Never commit a red tree.

   Red-first traps, the harness failure catalogue, and the capture rule for this session's
   tooling: `references/test-authoring.md` and `fix-mandate.md`. **In a repo where the
   plugin runs from its own working tree, mutate a COPY for the red run** — a red-first
   check there ships a deliberate bug to any round running concurrently.
5. **Do not narrate the round in the source.** Comments, docblocks and README prose
   describing *what this round did or found* ("after round 2…", "the round-1 fix…")
   belong in the round note. Why: 35 self-inflicted findings a month, 6 blocking, were
   the previous round's own commentary being found false by the next panel. A comment
   explaining *why the code is as it is* stays; one reporting *what QA did* is a finding
   waiting to happen. Examples: `references/fix-review.md`.

6. Each QA round's fixes must be committed as a **single, separate commit** — do not
   amend previous commits, and **do not push yet**:

```bash
cd <target-path>
git add <changed-files>
git commit -m "<preflight.json .commit_subject, verbatim>"
```

The push moves to after Step 3B.5, so that a fix the review corrects is amended into
this round's own commit rather than landing as a second one. Two commits for one round
would inflate the `QA-Fix-Commit` trailers and misattribute the next round's blame.

`.commit_subject` is already rendered — `fix(api): address QA round 3` where the project
defines named targets, `fix: address QA round 3` where it does not. Do not assemble it from
`.scope`: a scope is a multi-project concept, and a single-project repo has none.

If nothing was actually fixed — no blocking findings, and the minors were either
ledgered or declined — skip the fix commit, and say in the round note that this round
changed no code. A round that fixed only minors is **not** a clean round; see Step 3D.


### Step 3B.5 — review this round's fix diff, then push (round >= 2)

**Skip on round 1** (`fix_review.state = skipped:round-1`) and when Step 3B made no
commit (`skipped:no-fix-commit`). Round 1's fixes sit on author code with a full panel
behind them; 0 of 106 measured round-1 records carried a self-inflicted finding.

From round 2 on, spawn **one** `claude-qa-manager:qa-reviewer` over just this round's
fix commit, before the note posts:

- `skip_contract_verification=true` — the full panel verified the contract this round;
- the explicit range `<fix-commit>^..<fix-commit>`, plus the finding titles it addressed;
- exactly two questions: **does this diff do what the finding asked**, and **does it
  leave a sibling site asserting the opposite** (invariant 4).

If it returns findings, fix them and **amend this round's not-yet-pushed commit** — one
commit per round. Then push:

```bash
cd <target-path>
git push <remote> <feature-branch>
```

Record in the note **both**:

- `fix_review.state` — `clean`, `findings`, or `skipped:<why>`. **A skipped review is
  never reported as a clean one** (invariant 2). It reports what the *reviewer* returned;
  an amend made for any other reason does not make it `findings`.
- `fix_review.reviewed_sha` — **the SHA the reviewer actually ran on**. Amending rewrites
  it, so this routinely differs from the `QA-Fix-Commit` trailer, and a reader who sees
  only the trailer will assume that is what was reviewed. Say which SHA was reviewed and
  what the amendment changed; do not re-run the lens to make them match.

Why one lens: runtime regressions in the cycle's own fixes are the only class a reviewer
must catch, and the alternative is a full panel finding them a round later. Same model as
the panel per invariant 6 — the saving is width, not strength.
Measurements, the class breakdown, and the `reviewed_sha` reasoning:
`references/fix-review.md`.


## Step 3B.6 — revoke an approval before posting a dirty re-round

Only relevant when `MR_APPROVED=true` and this round produced new confirmed
critical/major findings. The revocation must run **before** the round note posts, or the
findings appear on an MR still flagged approved.

A deferred-findings approval must NOT be revoked for re-finding the very findings that were
deferred — compare against the deferred set by title.

See `references/dirty-reround.md`.


### Step 3C — Post the QA report to the MR

**Step 3B runs FIRST, always** — the trailers below name commits that must already
exist, and the next round reads them off the *posted* note. On the manager path the
manager withholds the post on any round with findings and returns `post_after_fixes`;
fix, append the trailers to `note_path`, then post. `note_posted=true` means a clean
round already posted — do not post again, or the round counter advances twice.

Post the QA report as a **single comment** on the MR. The body is the merged report
from Step 3A.3 when `DOUBLE=true` and a second-opinion reviewer succeeded, else the
Claude-only report (findings prefixed `[claude]`). A reviewer that was attempted and
failed gets one `⚠` line inside the body — **never** counted as a zero-finding pass.

Then: append the verbatim `$SAST_REPORT` when Step 2.5 produced one, keeping its heading
so a later reader can tell whether a scan ran; **one `QA-Fix-Commit` trailer per commit**
Step 3B made, full SHA, because that is what the next round reads to tell an MR defect from
one this cycle introduced; and a footer naming who actually posted.

**Resolve `$QA_TOKEN` here** from preflight's `qa_token_env`/`qa_token_file` pair — it is
assigned nowhere else in the main loop, a guessed name resolves empty, and empty means
"act as the developer". `QA_TOKEN_OK` says preflight resolved a token, **not** that you
hold one: both were true while three notes posted as the developer under a footer claiming
the QA agent. The created note's author is the ground truth; your footer is not evidence.
Post through the forge seam, never `glab`/`gh` directly — a hardcoded `glab` posts
nothing on a GitHub PR, and an unposted note resets the next round's number to 1. **A
failed post is not a posted note**: say so and stop rather than continuing to Step 3D.

Body template, the token recipe, and the posting block: `references/round-note.md`.


### Step 3C.5 — carry this round's observations forward

Append every `relevance: observation` finding this round produced to
`$QA_SCRATCH/observations.md`, one line each, skipping a tag-stripped title already there:

```
- [R<round>] **<severity>** <title> — <area_file>:<line_low>
```

**Second inflow:** every minor finding Step 3B declined to fix because it was
`qa_introduced` **and** `in_test_file`, marked so a reader can tell the two apart:

```
- [R<round>] **minor** <title> — <area_file>:<line_low>  (QA-authored test scaffolding, not fixed)
```

These are *not* `relevance: observation` and must not be relabelled as such — relevance
is a factual classification, not a routing dial (`references/observations.md`). They
share the ledger because it is the carry-forward mechanism and Step 4 reports from it;
the marker is what keeps the two inflows distinguishable.

Manager path: its `observations` array. Sequential: your own merged report. Select on the
`relevance` axis, never on a heading — the two renderers do not spell that heading alike.

Why a ledger at all: an observation lives only in the round note that found it, so a
five-round cycle scatters them across five comments and round 1's is the least likely to
be read. This file is what Step 4 reports. Depth: `references/observations.md`.


### Step 3D — Assess whether to continue

After each round, evaluate the findings:

- **If the round is clean** (no findings, or only hypothetical/minor with nothing to fix): announce the round came back clean. If this is at least round 2, tell the user the MR is ready to mark for review.
- **If the only things fixed this round were minor**: not a clean round, and not
  automatically another one. Say what was fixed, then ask — noting that the next panel's
  main subject would be the commit just made. This bullet was missing: "clean" covers
  *nothing to fix* and the next bullet covers *critical/major fixed*, so a minor-only
  round fell between them and the cycle improvised another. 36 measured rounds were
  exactly that.
- **If critical or major confirmed findings were found and fixed** (own branch): announce that another round is required. Ask: *"Ready to run QA round <N+1>?"* If yes, post this round's note first (it is what makes the next derivation return N+1), then **re-run `preflight.sh`** and take the new `round` and the freshly rendered `proportionality.md` from it. Do NOT increment the round by hand and reuse the existing scratch files — preflight re-runs the sync and re-renders the mandate for the new round in the same pass, which is the only thing that keeps the round number and the proportionality tier in agreement (see Step 3).
- **If critical or major findings were reported but not fixed** (someone else's branch, report-only mode): announce the findings have been posted. The QA cycle pauses here — the author needs to apply fixes before further rounds can be meaningful. Tell the user: *"QA report posted. Once {author} addresses the findings, run `/qa-cycle {MR_NUMBER}` again to continue QA."* (append the target name only when
`.layout.multi_target` is true.)
- **After 4 rounds**: if findings persist beyond round 4, present a summary of remaining open issues and ask the user how to proceed.
- **On a `diminishing_returns` decision** (any round): stop and ask, regardless of round number. Do not roll into another round on the assumption that more review is always safer — the failure mode this catches is the opposite one. The manager now **computes** this rather than waiting to notice it: it raises the decision when `qa_introduced_blocking >= max(2, ceil(blocking_total / 2))`, i.e. **when at least half of this round's blocking findings target code an earlier QA round introduced rather than the change the MR exists to make.** That is the signal that the cycle has stopped adding value. Ending it there, with the remaining findings explicitly deferred and enumerated in a note, is a legitimate and complete outcome — see the Step 3E deferred-findings exit.

**Under `--non-interactive` that *"Ready to run round N+1?"* prompt is auto-answered yes**
— continuing after findings were fixed is what the policy already prescribes — but only
while the round is not clean, fixes were applied, `round < 4`, and no
`diminishing_returns`; the first failure stops the cycle at Step 4. The `round < 4` bound
is what keeps the default mechanical rather than invented: the *After 4 rounds* rule asks
the human, and an unaskable question may not be assumed answered. Everything the bullet
requires after the prompt still applies. Conditions in full: `references/non-interactive.md`.

> **Staying in sync during QA rounds:** If the target branch advances while QA rounds are in progress, re-run Step 2 (sync) before each new round to keep the diff clean.


## Step 3E — approve the MR

Approve only when ALL hold:

- `QA_TOKEN_OK=true`;
- the round is **clean** (no confirmed critical/major) **OR** the deferred-findings exit
  applies;
- `round >= min_clean_round`, **OR** the tiny-diff relax matched;
- **CI has finished and passed on the exact commit you are approving** — probe the forge
  live with `forge_head_ci` and check its sha against `HEAD`. `preflight.json
  .pipeline_status` predates this round's fix commit, so using it certifies code no CI saw;
  a round once approved while its own fix commit's pipeline was still running. `running`
  means wait, `none` means say so — neither is a pass;
- if `SCHEMA_CHANGE_DETECTED=true`: a human (neither author nor QA agent) has already
  approved on GitLab **and** the rollout checklist was acknowledged. No flag relaxes this.

Confirm with the operator before approving. `--auto-approve` skips only that confirm, never
a gate.

Never describe a deferred-findings approval as a clean round: it rests on an enumerated
note, and that note must exist and be linked before approving.

Full gate logic, comment wording, and the exit's preconditions: `references/approval.md`.

---

## Step 4 — Final status report

After the QA cycle ends (clean round or user decision to stop), output a summary:

```
## QA Cycle Complete — MR #<MR_NUMBER><, TARGET only if .layout.multi_target>

- Rounds completed: N
- Round N came back: clean / minor-only / hypothetical-only
- Fix commits added: N
- QA reports posted to MR: N
- Approval status: approved-by-qa-agent / not-approved / skipped (token unavailable)
- Stopped because: clean round / user stopped / diminishing returns / round cap / <gate>

### Carried forward — found, not fixed by this cycle
<the contents of $QA_SCRATCH/observations.md, verbatim — or the single line `none reported`>

Next steps:
- Mark the MR as ready for review (remove Draft status if applicable)
- <ONLY if .layout.target_is_submodule> Reference the new commit in the parent workspace
```

The two gated lines come from `preflight.json`'s `layout` block. Naming a target in a repo
that has exactly one, or mentioning a parent workspace to someone whose repo has no parent,
describes a structure the reader does not have — omit them rather than hedging them.

**Print the Carried-forward heading even when the ledger is empty**, with `none reported`
under it — unlike the two gated lines, which are omitted. A missing section reads as
"nothing was found", which is the same claim as "nothing ran", and an absent check must
never report as a pass. Nothing listed there blocks the MR; each entry is a ticket
candidate, and handing the reader that list is how the cycle ends.

What belongs there, why `hypothetical` findings deliberately do not, and the end-of-cycle
comment option: `references/observations.md`.

---

---

## Notes

Rationale, invariants, and the reasoning behind each guard: `references/design-notes.md`.
