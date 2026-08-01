---
name: qa-cycle
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
| changing any of this | `references/design-notes.md`, `../../docs/CASE-STUDIES.md` |

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
| `mr_approved` | `MR_APPROVED` (Step 3B.6/3E) |
| `diff_scope.total_changed`,`diff_scope.is_tiny` | tiny-MR relax (Steps 2.5/3E) |
| `review_mode` (`manager`\|`sequential`) | Step 3A.1 routing (deterministic) |
| `lenses` (array, 3-6 names) | the lens panel the manager spawns (deterministic; Step 3A.1) |
| `schema.detected`,`schema.state`,`schema.evidence_path` | `SCHEMA_CHANGE_DETECTED` (Steps 3A.0.1/3E). `state` distinguishes a gate that ran from one that was never configured — only `checked` means it ran. |
| `sast.gate_state`,`sast.running`,`sast.report_path`,`sast.helper_reason` | `SAST_GATE_STATE`,`$SAST_REPORT` (Steps 2.5/3C/3E) |
| `contract.candidate_tickets`,`contract.title_ticket`,`contract.description_length` | Step 0.5 contract resolution |
| `docs_only` | Step 0.5 docs-only exemption |
| `round` | the round number for Step 3 — derived from the MR's posted `## QA Round N` notes (max + 1). Do NOT re-derive it by hand, and do not track it in the shell: every invocation is a fresh process, so a hand-tracked round silently resets to 1 and re-fires the round-1-only prompts on a late round. |
| `proportionality_path` | the `## Proportionality` section injected verbatim into every lens prompt (Step 3A / the manager). Never empty; preflight escalates its contents at `round >= 3`. |
| `forge` (`gitlab`\|`github`), `forge_cli` (`glab`\|`gh`) | which backend `lib/forge.sh` dispatches to, and which CLI it drives. Everything that touches the forge goes through `forge_*` — never call `glab`/`gh` directly, or the step works on one forge only. |
| `project`,`project_enc`,`qa_scratch` | as named |
| `commit_subject` | the Step 3B fix-commit subject, already rendered — scopeless in a single-project repo |
| `verify.command`,`verify.source`,`verify.state`,`verify.build_command` | the target's OWN test/build entry point, discovered from its Makefile / package.json / tox.ini / …. Step 3B runs it before committing. `state=none-found` means the project has no discoverable tests — report that, never treat it as a pass. |
| `layout.multi_target`,`layout.target_is_submodule` | whether this project HAS subprojects, and whether this target is one. Gate subproject wording (Step 4) on these; never assume a repo has parts. |

> `scope` is the target token; `diff_scope` is the diff numbers. preflight asserts the
> distinction before emitting, and Step 3B reads `.commit_subject` rather than either.
> Why the assertion exists: `references/design-notes.md`.

**Exit-code contract — honor it before anything else runs:**
- **`0`** — proceed. If `warnings` is non-empty, surface them.
- **`2`** — usage/config error **the operator can fix** (bad args, unknown target, missing tooling, unresolvable remote URL). STOP; fix and re-run.
- **`3`** — SOFT gate: **the sync merge itself deleted files** net-negative (`sync.unexpected_deletions=true`, "cut from a stale base"). Measured over the merge's own range (pre-merge tip..HEAD), NOT the MR's authored diff — so a legitimately deletion-heavy MR does not trip it. **The merge is left LOCAL and unpushed**, and `sync.deleted_files` lists the casualties. Do NOT proceed silently — present it via AskUserQuestion (rebuild-from-base vs. proceed anyway) with `sync.reason` + the deleted-file list, exactly as the old Step 2 warning intended. The predicate cannot distinguish "the base legitimately deleted these" from "my work is being reverted" — that judgment is the human's, which is why it asks.
- **`4`** — HARD STOP: the sync **could not be performed safely** (`sync.failed=true`; `sync.reason` says which — fetch/merge/push non-zero, merge conflict or dirty index, a failed checkout of the source branch, a dirty tree blocking that checkout, or a **protected source branch**). **No QA round may run** — a bad sync produces false findings. Report `sync.reason` and stop.
- **`5`** — INTERNAL failure: an invariant in preflight itself broke (jq build failed, the emitted JSON failed preflight's own shape assertion, or a diff-range endpoint would not resolve). This is a **bug in preflight**, not something the operator can fix by re-running — report it as such. Distinct from `2` so it cannot hide behind "usage error".

> **Known limitation — an MR sourced FROM a protected branch gets no automated QA.** preflight exits 4 and the round does not run; review it by hand. This is the *safe* failure and it is deliberate. Letting the round proceed read-only was tried and opened two holes at once: Step 3C's fix commit became reachable and pushed **straight to the protected branch** (`<feature-branch>` *is* the protected branch on that path), and because the checkout is skipped, the panel diffed an unrelated — often empty — `HEAD` and reported a **clean round on an MR it never read**, which could chain into an auto-approval. Supporting it properly needs preflight to export a three-dot diff range, every consumer to read that instead of hardcoding `..HEAD`, and Step 3C gated to report-only. That is a self-contained change deserving its own MR and its own QA.

**Warnings you must surface (`warnings[]`):**
- `unexpected_deletions` — pairs with exit 3 above.
- `sast_helper_failed` — the SAST helper exited non-zero (`sast.helper_reason` has the first stderr line). SKILL.md policy is that helper failure is a **MUST-ask-the-user** event (proceed without SAST vs. stop) — never silently continue.
- `sast_unrecognized_stub` — the helper exited 0 but emitted output preflight could not positively classify. `sast.gate_state` is `skipped:unknown`, which is **never** treated as a security review.
- `round_probe_failed:exit=<N>` — the MR-notes probe failed, so `round` fell back to `1` and is **not** trustworthy. A wrong round is not cosmetic: it re-fires the round-1-only prompts on a late round and renders the *light* proportionality tier on a round that had earned the strict one. Surface it and confirm the round number with the operator before running the panel — the posted `## QA Round N` notes on the MR are the ground truth. Never let a silent fallback pick the tier.

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
`--double`, `--triple`, `--reviewer=`, `--non-interactive`, `--auto-approve`.

Policy detail: `references/preflight-internals.md`.

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

Detail, including the wait-gate and the six-value contract: `references/sast.md`.

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
if a manager or lens **spawn is refused** in this runtime (no Agent nesting), fall
back to sequential Step 3A regardless of `review_mode`. `DOUBLE`/`TRIPLE` do
**not** change this routing — the manager runs the preflight-selected lens panel
regardless; the multi-model flags only add second-opinion shims inside it.

**Why a manager subagent, not the `Workflow` tool** — a clean main loop (the round's
fan-out, merge and render noise stays in the manager's own context) and hooks that reach
the lenses. Both verified to Agent depth 2; reviewer correctness depends on neither. See
`references/design-notes.md`.

So: **main spawns ONE `qa-manager` Agent** (background); the manager fans out
the `qa-reviewer` lenses named in preflight's `lenses` array **concurrently**
(all Agent calls in one message), merges/dedupes, renders
`$QA_SCRATCH/note-round<N>.md`, optionally posts it, and returns a compact verdict
+ a `decisions_needed` list. The panel is **preflight-selected** (3-6 lenses): the
three core lenses (contract-security, regression-edges, test-quality) always, plus
conditional lenses (schema-propagation, api-envelope, ui-styling, performance) per
the target's `lens_tags` and the live schema signal — capped at 6, the measured
Agent-grandchild concurrency ceiling, so the panel stays single-wave. The full
contract + the lens catalog live in `agents/qa-manager.md`; this step is
the main-loop side — how to invoke it and what to do with the verdict.

**Invoke it** with the Agent tool (`subagent_type: "qa-manager"`,
`run_in_background: true`), passing:

```
brief_path=<preflight.json .manager_brief_path>
post_note=<true|false>        # true = the manager posts the round note itself (hands-free)
non_interactive=<true|false>  # from --non-interactive; it still returns decisions_needed
DOUBLE=<t|f>  TRIPLE=<t|f>  reviewer_override=<qwen-local|"">
skip_contract_verification=<true|false>
```

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
  `note_posted=false` on a `post_note=true` round is expected in exactly one
  case: the `unapprove_before_post` decision below;
- resolves `unapprove_before_post` FIRST when present — run the Step 3B.6
  revocation, *then* post `note_path`. This ordering is the whole point of the
  decision: the findings must not appear on a still-approved MR;
- sets `SCHEMA_CHANGE_DETECTED=true` when the verdict's
  `schema_change_detected` is true (arms the Step 3E the schema-drift case gate);
- sets `ROUND_HAS_CRITICAL_OR_MAJOR` from `counts` (Step 3B.6);
- resolves each `decisions_needed` entry: `approval` → the Step 3E confirm;
  `fixes` → the Step 3B ownership-gated triage; `contract_disambiguation` →
  re-resolve Step 0.5; `sast_wait` → the Step 2.5 gate;
  `diminishing_returns` → present the panel's reasoning to the operator and ask
  whether to end the cycle. If they end it, every remaining confirmed
  critical/major finding must be explicitly deferred and enumerated in a posted
  note — that is what makes the Step 3E deferred-findings exit available. Do not
  silently continue to another round when this decision is raised; the panel
  judging its own output worthless is a result, not noise.
- **`--non-interactive`**: pre-answer the *defaultable* decisions without
  prompting — `sast_wait` → defer the round (`skipped:pipeline-running`),
  `fixes` → report-only (leave for the author), `contract_disambiguation` →
  take the highest-confidence candidate or BLOCK if none,
  `diminishing_returns` → surface it and **stop the cycle**, but defer NOTHING
  and do not approve (deferral is a human decision; see Step 3E),
  `unapprove_before_post` → just do it (revoke, then post; it needs no human
  judgment). **`approval` is NOT defaultable** — skip it unless `--auto-approve`
  was also passed. This is what lets a clean, non-approval round run fully
  hands-free: the manager does everything and `decisions_needed` resolves to
  no-op.

  **Two prompts are NEVER auto-answered, because `--non-interactive` may not
  invent a human's answer:**
  - The **schema-change rollout ACK** (Step 3E). Under `--non-interactive`,
    `SCHEMA_CHANGE_ACK` stays `false` and the run does not strand waiting on it:
    record approval status `blocked: schema change rollout not acknowledged`,
    finish the round (the note still posts), and stop before approval. Re-run
    interactively to acknowledge. Treating silence as an ACK is exactly the
    the schema-drift case failure mode.
  - The **exit-3 unexpected-deletions gate**, which asks whether a
    destructive-looking sync is intended. Under `--non-interactive`, do NOT
    proceed on a guess — stop the round and report `sync.reason`.

**Second-opinion shims (DOUBLE/TRIPLE)** run *inside* the manager as background
Bash, keeping the same per-reviewer non-blocking failure semantics as Step 3A.2
(non-zero exit OR missing/empty output → record, do not retry, never read a
failed shim as a zero-finding success). Their argv is unchanged; only their
launch site moves from main into the manager.

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
- `qa_introduced_blocking >= 2` → surface it to the user verbatim from the note. This
  cycle is largely fixing its own earlier fixes. **Report only**: do not recommend
  reverting or choose an approach — whether to revert, patch again, or stop is the
  human's, because the attribution cannot tell a wrong premise from a sloppy fix.

**Never manage round cost by downgrading the model** — a cheaper reviewer is a weaker
reviewer, which defeats the cycle. The levers are panel width (narrow a target's
`lens_tags`) and the trivial-MR gate. Cost analysis: `references/design-notes.md`.


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

1. Read each finding carefully. For findings marked "hypothetical" or "minor" with no confirmed reproduction, ask the user whether to fix them before proceeding.
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
   - **A new or changed test must be shown to fail without the fix.** Stash or revert the
     source change, run the test, confirm it FAILS, restore. A test that passes either way
     verifies nothing while looking like proof, and it is what lets a bad fix survive into
     the next round wearing a green tick.
   - If `verify.state` is `none-found`, do **not** treat that as clean: say in the round note
     that this round's fixes are unverified and why. That is a finding about the project, not
     a passing gate.
   - If the checks fail, fix that before committing. Do not commit a red tree and leave it to
     the next round.
5. Each QA round's fixes must be committed as a **single, separate commit** — do not amend previous commits:

```bash
cd <target-path>
git add <changed-files>
git commit -m "<preflight.json .commit_subject, verbatim>"
git push <remote> <feature-branch>
```

`.commit_subject` is already rendered — `fix(api): address QA round 3` where the project
defines named targets, `fix: address QA round 3` where it does not. Do not assemble it from
`.scope`: a scope is a multi-project concept, and a single-project repo has none.

If there are no actionable findings (all hypothetical or minor), skip the fix commit.


## Step 3B.6 — revoke an approval before posting a dirty re-round

Only relevant when `MR_APPROVED=true` and this round produced new confirmed
critical/major findings. The revocation must run **before** the round note posts, or the
findings appear on an MR still flagged approved.

A deferred-findings approval must NOT be revoked for re-finding the very findings that were
deferred — compare against the deferred set by title.

See `references/dirty-reround.md`.


### Step 3C — Post the QA report to the MR

Post the QA report as a **single comment** on the MR. The report body is:

- The merged report from Step 3A.3 when `DOUBLE=true` and at least one
  second-opinion reviewer succeeded, OR
- The Claude-only report (findings title prefix `[claude]` only) otherwise.

For every reviewer that was attempted but failed (non-zero exit or empty
output), append one line per failure inside the report body:

```
⚠ <tag> second-opinion review failed: <reason>. Proceeding without it.
```

where `<tag>` is the reviewer's tag (e.g. `do:deepseek-v4-pro`,
`do:openai-gpt-5.3-codex`, `qwen`). When `TRIPLE=true` and both
second-opinion reviewers failed, the comment still posts with the Claude-only
report plus two `⚠` lines.

Construct via a temp file to avoid shell quoting issues:

```bash
cat > "$QA_SCRATCH/note-round<N>.md" << 'EOF'
## QA Round <N>

<merged-or-claude-only report body>

<for each reviewer that was attempted but failed (`do:deepseek-v4-pro`,
`do:openai-gpt-5.3-codex`, or `qwen`): include one ⚠ line as described above>

<if Step 2.5 produced a $SAST_REPORT (regardless of whether it contained
findings), append a horizontal rule and then the verbatim contents of
$SAST_REPORT here so the MR comment carries both the human/agent QA report
AND the raw security delta. Keep the helper's "## NEW SAST findings" /
"## SAST review skipped" heading intact — the heading distinguishes this
section from the QA report above.>

<if Step 2.5 was skipped because the helper itself failed and the user
opted to continue, omit the SAST block entirely (do NOT post a stale or
empty section).>

<for EVERY commit Step 3B made this round, one trailer line each, full SHA. These
are the cycle's durable record of what IT changed, and the next round reads them
back to tell an MR defect from one a previous round of this cycle introduced. A
subject-pattern match cannot replace them: rebases, squashes and hand-edited
messages all break that, and this note survives them.

ONE LINE PER COMMIT, not one per round. A round is *supposed* to land a single
commit, but a follow-up fix is a normal thing to produce, and it happened on a real
round — the note recorded only the first, so the second's lines were invisible to
the next round's attribution and would have been reported as MR defects. Count the
commits you actually made; do not assume there was one.>
QA-Fix-Commit: <full SHA>
QA-Fix-Commit: <full SHA of any further fix commit this round>

---
<if QA_TOKEN_OK=true:>
*QA performed by <qa_auth_user from preflight.json when qa_token_ok, else the dev identity that posted> via Claude Code (<the model you are actually running as — not a literal copied from this file; a hardcoded id rots and misattributes the review. If you cannot determine it, write "Claude Code" with no parenthetical>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` where tag is the reviewer's tag, e.g. ` + do:deepseek-v4-pro` or ` + do:openai-gpt-5.3-codex` or ` + qwen3-14b (LM Studio)`>
<else (QA_TOKEN_OK=false): omit the "<username> via " prefix:>
*QA performed by Claude Code (<the model you are actually running as — see the note above>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` as above>

<if QA_TOKEN_OK=false, also include this warning line inside the comment body (above the footer):>
> ⚠ Posted with dev credentials — QA agent token unavailable.
EOF
cd <target-path>
# All forge writes go through the seam — it dispatches to glab or gh from
# preflight.json's `forge`. Never call glab/gh directly here: a hardcoded `glab`
# posts nothing on a GitHub PR, and the round note is what the NEXT round's
# number is derived from, so a silently unposted note resets the cycle to 1.
. "${CLAUDE_PLUGIN_ROOT}/lib/forge.sh"
forge_init "$(git remote get-url "$REMOTE")" "${CLAUDE_PLUGIN_ROOT}/lib"

# Pass the QA token when it verified, an empty token to fall back to the dev
# identity. The warning line above already explains the fallback in the comment.
if forge_post_note "$PROJECT" <MR_NUMBER> "$QA_SCRATCH/note-round<N>.md" \
     "$([ "$QA_TOKEN_OK" = "true" ] && printf '%s' "$QA_TOKEN")"; then
  echo "round note posted"
else
  # A failed post is NOT a posted note. Say so and stop rather than continuing
  # to Step 3D, which would offer round N+1 that preflight cannot derive.
  echo "ERROR: round note was NOT posted; do not proceed to the next round" >&2
fi
```


### Step 3D — Assess whether to continue

After each round, evaluate the findings:

- **If the round is clean** (no findings, or only hypothetical/minor with nothing to fix): announce the round came back clean. If this is at least round 2, tell the user the MR is ready to mark for review.
- **If critical or major confirmed findings were found and fixed** (own branch): announce that another round is required. Ask: *"Ready to run QA round <N+1>?"* If yes, post this round's note first (it is what makes the next derivation return N+1), then **re-run `preflight.sh`** and take the new `round` and the freshly rendered `proportionality.md` from it. Do NOT increment the round by hand and reuse the existing scratch files — preflight re-runs the sync and re-renders the mandate for the new round in the same pass, which is the only thing that keeps the round number and the proportionality tier in agreement (see Step 3).
- **If critical or major findings were reported but not fixed** (someone else's branch, report-only mode): announce the findings have been posted. The QA cycle pauses here — the author needs to apply fixes before further rounds can be meaningful. Tell the user: *"QA report posted. Once {author} addresses the findings, run `/qa-cycle {MR_NUMBER}` again to continue QA."* (append the target name only when
`.layout.multi_target` is true.)
- **After 4 rounds**: if findings persist beyond round 4, present a summary of remaining open issues and ask the user how to proceed.
- **On a `diminishing_returns` decision** (any round): stop and ask, regardless of round number. Do not roll into another round on the assumption that more review is always safer — the failure mode this catches is the opposite one. A useful check when deciding: **if most of this round's blocking findings target code an earlier QA round introduced rather than the change the MR exists to make, the cycle has stopped adding value.** Ending it there, with the remaining findings explicitly deferred and enumerated in a note, is a legitimate and complete outcome — see the Step 3E deferred-findings exit.

> **Staying in sync during QA rounds:** If the target branch advances while QA rounds are in progress, re-run Step 2 (sync) before each new round to keep the diff clean.


## Step 3E — approve the MR

Approve only when ALL hold:

- `QA_TOKEN_OK=true`;
- the round is **clean** (no confirmed critical/major) **OR** the deferred-findings exit
  applies;
- `round >= min_clean_round`, **OR** the tiny-diff relax matched;
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

Next steps:
- Mark the MR as ready for review (remove Draft status if applicable)
- <ONLY if .layout.target_is_submodule> Reference the new commit in the parent workspace
```

The two gated lines come from `preflight.json`'s `layout` block. Naming a target in a repo
that has exactly one, or mentioning a parent workspace to someone whose repo has no parent,
describes a structure the reader does not have — omit them rather than hedging them.

---

---

## Notes

Rationale, invariants, and the reasoning behind each guard: `references/design-notes.md`.
