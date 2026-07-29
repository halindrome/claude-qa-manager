---
name: qa-round
description: "Run a structured QA review round on a merge request or pull request. Takes the MR/PR number and an optional target name (e.g. /qa-round 123, or /qa-round 123 api in a monorepo). Runs a deterministic preflight (branch sync, ownership, round derivation, security-scan delta), fans out a 3-6 lens reviewer panel, posts a round note, and gates approval behind an explicit policy. Every finding is grounded in a linked ticket's acceptance criteria or a regression the diff introduces. Proportionality escalates with the round number and the panel can declare diminishing returns, so the cycle ends rather than looping forever. Branches derive from the MR/PR at runtime, so no configuration is required for a single repo; targets, schema paths, and QA-agent credentials come from optional layered config."
---

# MR QA Skill

Orchestrate the full MR QA process for a target repository merge request.

## Edits to this skill

`main` is the source of truth for `.claude/skills/mr-qa/`, `agents/qa-reviewer.md`, `.branchconfig.yaml`, and `scripts/create-coordinated-branch.sh`. New features and fixes land on `main` first. When a release branch (e.g. `release_patches`) is current, urgent skill patches MAY be made directly on that branch — but the same fix MUST then be applied to `main` (either as a follow-up commit on main, or via the standard release-into-trunk merge cycle when the release branch re-incorporates). The only sanctioned cross-branch divergence is in branch-config files (`.branchconfig.yaml` values and `the resolved config` per-target `branch:` / `protected_branches:` / `_production_reference` fields).

**Usage:** `/mr-qa <MR_NUMBER> <TARGET> [--double | --triple] [--reviewer=qwen-local]`

Multi-model QA flags (all opt-in, all per-invocation — pass again on round 2+
to keep them active):

- `--double` — Claude (primary) **+** DigitalOcean serverless inference running
  `deepseek-v4-pro`. ~$0.12 per typical MR round at DO list pricing. Different
  training lineage from Claude (catches a different class of issues), 1M-token
  context (handles huge MRs without truncation), code-strong. Requires
  `DO_LLM_API_KEY` env var. See `${CLAUDE_PLUGIN_ROOT}/lib/do-reviewer.sh`.
- `--triple` — `--double` plus a third reviewer running `openai-gpt-5.3-codex`
  (code-tuned, OpenAI lineage). ~$0.30 per round total. Three distinct model
  families catch the broadest class of issues.
- `--reviewer=qwen-local` — opt back into the legacy local LM Studio Qwen3-14b
  reviewer instead of (or in addition to) DO. See
  `${CLAUDE_PLUGIN_ROOT}/docs/qwen-reviewer.md`. Useful for offline review or
  testing without DO API costs.

Default (no flag): Claude reviews alone.

Supported targets are defined in `the resolved config` (monorepo + each submodule). Typical values: `api`, `webapp`, `mobile`, `sse`, `chatbot-orchestrator`, `mcp-server`, `monorepo`.

---

## Target configuration

The skill resolves a target in two layers:

1. **Target registry** — `the resolved config`. Static
   per-target metadata that doesn't change with monorepo branch context:
   - `targets.<name>.path` — working directory (e.g. `apps/api`, `.`)
   - `targets.<name>.remote` — git remote (usually `origin`)
   - `targets.<name>.scope` — commit-message scope token
   - `targets.<name>.base_branch` — fallback base branch (used only when
     `.branchconfig.yaml` is absent or doesn't list this path)
   - `targets.<name>.security_stage` — boolean; whether this target's CI
     pipeline runs the shared CI security template
     (`.gitlab-ci-security.yml`). Drives Step 2.5.
   - `protected_branches` — array; never push directly to these
   - `qa_agent` — credentials block for QA-attributed GitLab actions
     (see Step 0.25)
   - `sast_gate` — polling behaviour for the SAST helper (see Step 2.5)

2. **Current branch topology** — `.branchconfig.yaml` at the repo root.
   Declares the *current* base branch for each submodule on this monorepo
   branch. When present, this is authoritative for `base_branch`.

This split means you no longer edit `the resolved config` to switch between
dev-trunk and production-patches workflows — switching monorepo branches
(which carry different `.branchconfig.yaml` files) does that automatically.
Only edit `the resolved config` to add/remove a target or change its
path/remote/scope/protected list, or to update `qa_agent`/`sast_gate`/
`security_stage` policy.

---

## Step 0.0 — Preflight (deterministic; run once per round, read the JSON)

The entire mechanical preamble is a single script — run it **once per round** (at the
start, and again before each subsequent round) instead of walking the model through each
shell step in its own turn. It is idempotent, and re-running it is what advances the
round and re-renders the proportionality tier together; see Step 3 and Step 3D:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/lib/preflight.sh <MR_NUMBER> <TARGET>
```

It emits one JSON object to `$QA_SCRATCH/preflight.json` (and stdout) and
performs, deterministically, the mechanics that used to be Steps **0** (target +
base-branch resolution, MR inspection, ownership), **0.25** (QA-token resolve +
verify), **0.4** (`GITLAB_PROJECT`/`_ENC` + scratch dir), **0.7** (seed
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
| `schema.detected`,`schema.evidence_path` | `SCHEMA_CHANGE_DETECTED` (Steps 3A.0.1/3E) |
| `sast.gate_state`,`sast.running`,`sast.report_path`,`sast.helper_reason` | `SAST_GATE_STATE`,`$SAST_REPORT` (Steps 2.5/3C/3E) |
| `contract.candidate_tickets`,`contract.title_ticket`,`contract.description_length` | Step 0.5 contract resolution |
| `docs_only` | Step 0.5 docs-only exemption |
| `round` | the round number for Step 3 — derived from the MR's posted `## QA Round N` notes (max + 1). Do NOT re-derive it by hand, and do not track it in the shell: every invocation is a fresh process, so a hand-tracked round silently resets to 1 and re-fires the round-1-only prompts on a late round. |
| `proportionality_path` | the `## Proportionality` section injected verbatim into every lens prompt (Step 3A / the manager). Never empty; preflight escalates its contents at `round >= 3`. |
| `gitlab_project`,`gitlab_project_enc`,`qa_scratch` | as named |

> **`scope` vs `diff_scope` — do not merge these two keys.** Top-level `scope` is
> the **registry string**: the commit-message token from `the resolved config`
> (`api`, `monorepo`, …) that Step 3B interpolates into `fix(<scope>): …`.
> The **diff numbers** live under `diff_scope`. They were briefly the same key,
> and because jq keeps the *last* of a duplicate key, the registry string was
> silently destroyed — every consumer then had to re-read `the resolved config`
> by hand, which is the exact work preflight exists to remove. preflight now
> asserts `.scope|type=="string"` before it will emit, so the collision cannot
> return unnoticed.

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

## Step 0 — Parse arguments and inspect the MR

> **Mechanics superseded by Step 0.0 preflight** — the resolution below is
> performed by `preflight.sh`; read `base_branch`, `mr_*`, `is_own_branch`,
> etc. from `preflight.json`. The prose is retained as the authoritative
> description of *what* is resolved and *why*. Still parse the reviewer flags
> (`--double`/`--triple`/`--reviewer=`) from argv yourself.

Extract `MR_NUMBER`, `TARGET`, and the optional reviewer flags from the
invocation arguments. If `MR_NUMBER` or `TARGET` is missing, ask for it before
proceeding. Record:

- `DOUBLE=true` if `--double` **or** `--triple` appears anywhere in the argv,
  else `DOUBLE=false`. (Triple implies double — a second reviewer always runs
  when a third is requested.)
- `TRIPLE=true` if `--triple` appears anywhere in the argv, else `TRIPLE=false`.
- `REVIEWER_OVERRIDE` captures any `--reviewer=<id>` argument value. Recognized
  ids: `qwen-local` (route the second-opinion reviewer through the legacy local
  LM Studio Qwen path instead of DO). Unrecognized ids must trigger a STOP with
  a clear error.
- Accept both the `=`-joined and space-separated CLI forms — `--reviewer=qwen-local`
  and `--reviewer qwen-local` are equivalent. Reject lone `--reviewer` with no
  value as a STOP: `"--reviewer requires an id (e.g. --reviewer=qwen-local)."`

Also parse two hands-free flags (see Step 3A.1 — they control how the QA
manager's `decisions_needed` are resolved):
- `NON_INTERACTIVE=true` if `--non-interactive` (a.k.a. `--yes`) appears in argv.
  Pre-answers the *defaultable* gates without prompting (skip-contract=No,
  SAST-wait=defer, fixes=report-only, ambiguous contract=highest-confidence or
  BLOCK). A clean, non-approval round then runs fully hands-free.
- `AUTO_APPROVE=true` if `--auto-approve` appears in argv. ONLY this flag lets a
  clean approval-eligible round approve without the Step 3E AskUserQuestion
  confirm. Never implied by `--non-interactive` — approval is a safety invariant.

Documented argument surface:
`<MR_NUMBER> <TARGET> [--double | --triple] [--reviewer=qwen-local] [--non-interactive] [--auto-approve]`. All flags
are per-invocation — nothing is persisted between rounds; callers must pass the
flags again on subsequent rounds to keep multi-model QA active.

Load `the resolved config` and look up `targets.<TARGET>`. Resolve `<target-path>`, `<remote>`, and `<scope>` from that entry. If the target is not present, ask the user for the path and offer to add the entry.

Then resolve `<base-branch>` with this precedence:

1. If `.branchconfig.yaml` exists at the repo root:
   a. If `<target-path>` is `.` (the monorepo itself), use the top-level `base_branch:` field of `.branchconfig.yaml`.
   b. Otherwise, look up `submodule_branches.<target-path>.base_branch`. If present, use that value.
2. If neither produced a value, fall back to `targets.<TARGET>.base_branch` from `the resolved config`.

Implementation snippet (the resolver should behave equivalently to this):

```bash
RESOLVED_BASE=""
RESOLVED_SOURCE=""
CONFIG="$(git rev-parse --show-toplevel)/.branchconfig.yaml"
if [[ -f "$CONFIG" ]]; then
  if [[ "$TARGET_PATH" == "." ]]; then
    RESOLVED_BASE=$(awk '/^base_branch:/ { sub(/^base_branch:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[" ]/, ""); print; exit }' "$CONFIG")
  else
    RESOLVED_BASE=$(awk -v t="$TARGET_PATH" '
      /^submodule_branches:/ { in_sub = 1; next }
      in_sub && /^[^[:space:]]/ { in_sub = 0; current = "" }
      # Match any submodule key, then string-compare to t — this avoids
      # treating regex meta-chars in target paths (e.g. ".") as wildcards.
      in_sub && /^  [^[:space:]:].*:[[:space:]]*(#.*)?$/ {
        key = $0
        sub(/^  /, "", key); sub(/:[[:space:]]*(#.*)?$/, "", key)
        current = (key == t) ? t : ""
        next
      }
      in_sub && current == t && /^    base_branch:/ {
        sub(/^    base_branch:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[" ]/, "")
        print; exit
      }
    ' "$CONFIG")
  fi
  [[ -n "$RESOLVED_BASE" ]] && RESOLVED_SOURCE=".branchconfig.yaml"
fi
if [[ -z "$RESOLVED_BASE" ]]; then
  RESOLVED_BASE=$(jq -r --arg t "$TARGET" '.targets[$t].base_branch' the resolved config)
  RESOLVED_SOURCE="the resolved config fallback"
fi
```

Report which source was used (one line, e.g. `base_branch = main (from .branchconfig.yaml)` or `base_branch = master (from the resolved config fallback)`) so the user can confirm the skill picked up the right context.

Navigate into the target directory and fetch the MR details:

```bash
cd <target-path>
glab mr view <MR_NUMBER>
```

Capture: MR title, source branch name, target branch, list of changed files, and current status (open/draft/etc.).

**Determine branch ownership.** Extract the MR author from the `glab mr view` output. Then determine the current user:

```bash
glab auth status 2>&1 | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1
```

This `sed -nE` form is portable across BSD/macOS and GNU sed; the prior PCRE-`\K` invocation was GNU-grep-only and failed on macOS (`grep: invalid option -- P`).

Compare the MR author to the logged-in user. Set `IS_OWN_BRANCH=true` if they match, `IS_OWN_BRANCH=false` otherwise. This controls whether fixes are applied automatically (see Step 3B).

Also get the diff stat to assess scope. Use the MR's **actual target branch** (from `glab mr view`) — not necessarily the config's `base_branch` (report it to the user if they differ, since it may indicate the MR is targeting production patches while the config is set for dev trunk, or vice versa):

```bash
cd <target-path>
git fetch <remote>
git diff <remote>/<target-branch>..<remote>/<feature-branch> --stat 2>/dev/null | tail -5
```

---

## Step 0.25 — Resolve QA agent credentials

Before any QA round runs, resolve credentials for **QA-attributed GitLab actions** (posting round notes, approving the MR). Fix commits and branch syncs continue to use the user's normal `glab`/dev token — only the actions enumerated below use the QA agent token.

1. **Load the `qa_agent` block** from `the resolved config`. Capture `token_env`, `token_file`, `expected_username`, and the `approval` sub-block.

2. **Resolve the token.** First check the env var named by `token_env` (default `QA_AGENT_TOKEN`):

   ```bash
   # Guard against empty/unset token_env — bash ${!var:-} errors with
   # "bad substitution" when var is empty (e.g. user dropped qa_agent.token_env
   # from the resolved config to disable env-var lookup).
   QA_TOKEN=""
   if [ -n "$token_env" ]; then
     QA_TOKEN="${!token_env:-}"   # e.g. ${QA_AGENT_TOKEN:-}
   fi
   ```

   If empty, read `token_file` (expand `~`). If the file does not exist or is empty, set `QA_TOKEN_OK=false` and continue:

   ```bash
   if [ -z "$QA_TOKEN" ]; then
     token_path="${token_file/#\~/$HOME}"
     if [ -s "$token_path" ]; then
       QA_TOKEN="$(tr -d '[:space:]' < "$token_path")"
       if [ -z "$QA_TOKEN" ]; then
         echo "warn: $token_path exists but contains no non-whitespace content; treating as no token available." >&2
       fi
     fi
   fi
   ```

3. **Verify the token.** If a token was found, probe identity with the QA token and extract the resolved username with the same pattern Step 0 uses for the dev token.

   The verification probe MUST use the `GITLAB_TOKEN=$QA_TOKEN` env-var-prefix form so it invokes `glab` under the QA agent identity — the same shape `qa_glab()` uses (see step 4 below). Falling back to plain `glab` here resolves the dev token and produces a silent false-negative `QA_TOKEN_OK=false` even when the QA token is valid: `glab auth status` would report the dev user, the `$QA_AUTH_USER != $expected_username` branch would fire, and the skill would then degrade approvals + QA comments to the dev identity for no real reason. The env-var-prefix invocation form is therefore a hard rule, not a stylistic preference.

   ```bash
   if [ -n "$QA_TOKEN" ]; then
     QA_AUTH_USER=$(GITLAB_TOKEN="$QA_TOKEN" glab auth status 2>&1 \
       | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1)
     if [ -z "$QA_AUTH_USER" ]; then
       echo "warn: QA agent token did not return a username from 'glab auth status'." >&2
       QA_TOKEN_OK=false
     elif [ "$QA_AUTH_USER" != "$expected_username" ]; then
       echo "warn: QA agent token resolved to '$QA_AUTH_USER' (expected '$expected_username'). Falling back to dev token." >&2
       QA_TOKEN_OK=false
     else
       QA_TOKEN_OK=true
     fi
   else
     QA_TOKEN_OK=false
   fi
   ```

   Note: the `sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1` extraction is the same form Step 0 uses for the dev token, so the two probes stay symmetric and portable across BSD/macOS and GNU userspaces. On mismatch, auth failure, or empty `QA_TOKEN`, set `QA_TOKEN_OK=false` and continue — the downstream paths in Step 3C and Step 3E both branch on `QA_TOKEN_OK`.

4. **Helper convention.** When `QA_TOKEN_OK=true`, the rest of this skill treats this shell function as the way to invoke QA-attributed `glab` calls:

   ```bash
   qa_glab() { GITLAB_TOKEN="$QA_TOKEN" glab "$@"; }
   ```

   When `QA_TOKEN_OK=false`, fall back to plain `glab` for the comment-posting paths and **skip approval entirely** (see Step 3E).

5. **Identity scope.** `IS_OWN_BRANCH` detection in Step 0 stays anchored to the **dev token's** logged-in user, not the QA agent. The QA agent is never the MR author — do not use `qa_glab` for the auth/identity probe in Step 0.

---

## Step 0.4 — Scratch directory

Every `/tmp/...` path the skill writes (contract file, reviewer outputs, SAST report, posted MR notes) MUST live under a per-invocation scratch directory so two concurrent QA rounds cannot clobber each other. Two failure modes this prevents: the same MR number across different repos (e.g. !1085 on `example-org/example-repo` vs `example-org/example-workspace`), and parallel rounds on different MRs that share an output filename.

Define `QA_SCRATCH` once at this step and reference it from every downstream step:

```bash
# Resolve GITLAB_PROJECT here (early) so the scratch-dir hash below includes
# the project disambiguator. Step 2.5 references the same variable without
# recomputation. (Prior versions resolved this only in Step 2.5, which left
# the hash input collapsing to an empty string — defeating cross-project
# disambiguation that Step 0.4 promises.)
GITLAB_PROJECT=$(cd <target-path> && git remote get-url <remote> \
  | sed -E 's,^.*[/:]([^/]+/[^/]+)\.git$,\1,')

# Pick whichever sha256 tool the platform provides (macOS/BSD: shasum -a 256;
# GNU/Linux: sha256sum). Dispatch outside the pipe with literal argv so the
# block is shell-portable: bash splits unquoted parameter expansions on
# whitespace by default, but zsh does NOT (zsh sees `| $CMD |` as a single
# command name including any embedded spaces, e.g. literal "shasum -a 256",
# which fails with "command not found" and silently produces an empty hash —
# defeating the entire purpose of the scratch-dir namespacing).
QA_SCRATCH_INPUT=$(printf '%s|%s|%s' "$(pwd)" "$GITLAB_PROJECT" "$MR_NUMBER")
if command -v shasum >/dev/null 2>&1; then
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | shasum -a 256 | awk '{print $1}' | cut -c1-12)
else
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | sha256sum     | awk '{print $1}' | cut -c1-12)
fi
QA_SCRATCH="/tmp/mr-qa-${QA_SCRATCH_HASH}-${MR_NUMBER}"
mkdir -p "$QA_SCRATCH"
```

- `GITLAB_PROJECT` is resolved at the top of this block (was previously deferred to Step 2.5). Step 2.5 reuses this same variable without recomputing it.
- `QA_SCRATCH` is per-invocation. A subsequent `/mr-qa` run on the same MR from the same `cwd` reuses the same dir — that's intentional, so the contract file and earlier round outputs are still discoverable on `--resume`-style flows.
- Treat the directory as ephemeral: nothing depends on its contents persisting beyond the invocation.

Canonical filenames inside `$QA_SCRATCH` (all literal):

| Step | Filename |
|---|---|
| 0.5 | `$QA_SCRATCH/contract.md` |
| 2.5 | `$QA_SCRATCH/sast.md` |
| 3A.2 reviewer 2 | `$QA_SCRATCH/r2-round<N>.md` |
| 3A.2 reviewer 3 | `$QA_SCRATCH/r3-round<N>.md` |
| 3C posted note | `$QA_SCRATCH/note-round<N>.md` |

---

## Step 0.5 — Resolve the contract (JIRA lookup → synthesize → block)

Before any QA round runs, resolve a **contract** for this MR — the criteria the
reviewer will verify against. Four decision branches:

1. **Formal JIRA link on the MR.** Run `glab mr view <MR_NUMBER> --output json`
   and inspect the MR body / GitLab link mechanism for a JIRA URL or related-issue
   field. If one is present, extract the ticket ID (e.g., `PROJ-1234`) and call
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
   `/mr-qa`."* Do NOT fall back to freeform findings.

Always re-resolve the contract on each `/mr-qa` invocation (including subsequent rounds) and overwrite `$QA_SCRATCH/contract.md`. A stale `contract.md` from a previous round MUST NOT be reused — the MR description or linked JIRA may have changed between rounds, and silently inheriting an out-of-date contract would let those changes slip past QA. The scratch directory is for cross-round artifacts whose authority does not change (e.g. per-round notes); the contract is not one of those.

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

## Step 0.7 — Seed MR_APPROVED from GitLab

`MR_APPROVED` defaults to `false` on every fresh shell, so on a re-invocation
of `/mr-qa` after a prior round that auto-approved, the skill would otherwise
think the MR is unapproved and never trigger the dirty-reround unapprove flow
(Step 3B.6). Seed it from GitLab here so the state survives across
invocations.

When `QA_TOKEN_OK=true`, query GitLab for the current approval state under
the QA agent identity:

```bash
# URL-encode the project path for the GitLab API (e.g. example-org/example-repo
# → example-org%2Fexample-repo).
GITLAB_PROJECT_ENC=$(printf '%s' "$GITLAB_PROJECT" | sed 's,/,%2F,g')

# Pull every approver username the API surfaces under approval_state. Use
# multiple jq paths with `// empty` so we tolerate the different shapes
# GitLab returns across versions/MR rule configurations:
#   - .rules[].approved_by[].username        (per-rule approvers)
#   - .approved_by[].user.username           (top-level approvers list)
APPROVED_BY=$(qa_glab api "projects/${GITLAB_PROJECT_ENC}/merge_requests/${MR_NUMBER}/approval_state" 2>/dev/null \
  | jq -r '
      [ (.rules[]?.approved_by[]?.username // empty),
        (.approved_by[]?.user.username // empty) ]
      | .[]
    ' 2>/dev/null | sort -u)

if printf '%s\n' "$APPROVED_BY" | grep -qx "$QA_AUTH_USER"; then
  MR_APPROVED=true
else
  MR_APPROVED=false
fi
```

When `QA_TOKEN_OK=false`, the QA agent identity is unavailable so the
unapprove flow is disabled regardless — keep `MR_APPROVED=false` and skip the
query:

```bash
if [ "$QA_TOKEN_OK" != "true" ]; then
  MR_APPROVED=false
fi
```

This makes the dirty-reround unapprove gate in Step 3B.6 actually fire when
a prior `/mr-qa` invocation (or even an out-of-band approval by the QA agent
via the GitLab UI) left the MR in an approved state.

---

## Step 2 — Sync the feature branch with the base branch

This is mandatory before any QA round. A branch that is behind its base produces false findings.

```bash
cd <target-path>
git fetch <remote>
git checkout <feature-branch>
git merge <remote>/<target-branch> --no-edit
git push <remote> <feature-branch>
```

After pushing, verify the resulting diff is limited to intended changes:

```bash
cd <target-path>
git diff <remote>/<target-branch>..HEAD --stat
```

Report the diff stat to the user. If the diff contains unintended deletions or reversions after syncing, warn: *"The branch may have been cut from a stale base. Consider rebuilding from the current base tip."* Ask the user to confirm before proceeding.

---

## Step 2.5 — Fetch security findings (auto-skipped when not applicable)

**Per-target opt-in.** Before running the helper, read `targets[<TARGET>].security_stage` from `the resolved config`. When it is `false` (or absent), this target's CI pipeline does not yet include the shared CI security template (`.gitlab-ci-security.yml`) — currently `sse` and the workspace itself fall here. Skip the helper call entirely, write the minimal stub directly, and continue:

```bash
# Assign the report path first so BOTH branches below have a valid target.
SAST_REPORT="$QA_SCRATCH/sast.md"

# SAST_GATE_STATE summarizes how the SAST gate resolved for this round.
# Step 3E's approval comment branches on it. preflight.sh assigns it; this list,
# preflight's shape assertion, and Step 3E's case whitelist MUST agree — all
# three enumerate the same six values. Possible values:
#   clean                      — a real delta was computed against a FINISHED
#                                pipeline (incl. an empty finding set). This is
#                                the ONLY value that asserts a scan actually ran;
#                                it must never be a fallthrough default.
#   skipped:no-stage           — security_stage=false for this target, or the
#                                pipeline has no security jobs
#   skipped:no-pipeline        — no pipeline exists on the MR yet. ROUTINE right
#                                after preflight pushes the sync merge.
#   skipped:pipeline-running   — security jobs still in progress (waitable)
#   skipped:helper-failed      — helper exited non-zero
#   skipped:unknown            — helper exited 0 but emitted output preflight
#                                could not positively classify. Never treated as
#                                a security review.
# There is deliberately NO bare "unknown" default: an unclassifiable state must
# be named as a skip, because the fallthrough default used to be `clean` — which
# certified scans that never ran.
SAST_GATE_STATE="skipped:unknown"

SECURITY_STAGE=$(jq -r --arg t "<TARGET>" '.targets[$t].security_stage // false' the resolved config)
if [ "$SECURITY_STAGE" != "true" ]; then
  cat > "$SAST_REPORT" <<EOF
## SAST review not applicable

Target \`<TARGET>\` has \`security_stage: false\` in \`the resolved config\`. No CI security stage is wired for this target, so no SAST/SCA delta is computed. Update the flag when the shared CI security template lands for this target.
EOF
  SAST_GATE_STATE="skipped:no-stage"
else
  # security_stage=true → run the helper (existing logic in the block below).
  # SAST_GATE_STATE will be updated below based on helper outcome and gate
  # branch taken (clean / skipped:pipeline-running / skipped:helper-failed).
  :
fi
```

When `SECURITY_STAGE=true`, fall through to the helper-invocation block below; otherwise skip directly to the "Forwarding the report" section since `$SAST_REPORT` already carries the stub.

This avoids two failure modes the gate was never meant to cover:
- Targets with no security CI at all (the helper would have eventually said "no security stage detected" anyway, but only after the pipeline finished — meanwhile the gate would have prompted the user to wait pointlessly).
- A workspace/monorepo MR that only bumps submodule pointers, which has nothing to scan.

For targets where `security_stage: true`, run the SAST/SCA delta helper to compute NEW security findings introduced by this MR vs the checked-in baselines. The helper auto-detects which scanners ran in the MR's latest pipeline (per the shared `.gitlab-ci-security.yml` template), downloads each scanner's artifact, and diffs against the baseline files in the working tree.

```bash
# $GITLAB_PROJECT already set in Step 0.4 (resolved from the submodule's git
# remote so the helper can hit the right project regardless of how the target
# is named in the resolved config — e.g. "mobile" target → example-org/example-repo).
# $SAST_REPORT was already set at the top of Step 2.5.

bash ${CLAUDE_PLUGIN_ROOT}/lib/fetch-sast-findings.sh \
  --project "$GITLAB_PROJECT" \
  --mr "$MR_NUMBER" \
  --target-path "<target-path>" \
  --output "$SAST_REPORT"
```

The helper writes its full report to `$SAST_REPORT` (and to stdout). It always exits 0 on normal completion regardless of finding count; non-zero only on tool/API failure.

**Behavior (only reachable when `security_stage: true`):**
- Pipeline still running/pending → helper writes a "SAST review skipped" stub that carries a `**<status>**` token (either `Pipeline #<N> is **<status>** and no security jobs have been created yet` or `Security scans are still in progress (overall pipeline #<N>: **<status>**)`). Both are matched by the running-marker regex `\*\*(running|pending|created|preparing|scheduled|waiting_for_resource)\*\*`. See the gate below. (The no-security-stage stub deliberately carries NO `**status**` token, so the same regex excludes it.)
- No security stage detected even though `security_stage: true` → helper writes a "no security stage" stub. This signals a config drift (the flag claims security exists but the pipeline doesn't run the jobs); surface this to the user as a warning but continue without gating.
- Security stage ran → helper writes a `## NEW SAST findings` block per scanner, severity-grouped, with file/line citations. Continue.

### Pipeline-still-running gate

After the helper runs, inspect `$SAST_REPORT` for the running-pipeline marker. If it's present AND the current round is approval-eligible AND `sast_gate.wait_on_approval_round` is true in `the resolved config`, prompt the user before continuing — approving an MR with a still-running SAST pipeline means the QA round certifies zero security delta.

```bash
# Running-marker regex MUST match the helper's ACTUAL output. The helper's two
# waitable skip-stubs each carry a `**<status>**` token; its no-stage stub and
# its clean report do NOT — so this single regex is precise. (Prior versions
# grepped for the literal phrase `is still **<status>**`, which the helper never
# emits, so the gate silently never fired on a genuinely-running scan.)
SAST_RUNNING_RE='\*\*(running|pending|created|preparing|scheduled|waiting_for_resource)\*\*'
SAST_GATE_RUNNING=$(grep -Eq "$SAST_RUNNING_RE" "$SAST_REPORT" && echo true || echo false)

# Read sast_gate config
SAST_GATE_ENABLED=$(jq -r '.sast_gate.wait_on_approval_round // true' the resolved config)
POLL_INTERVAL=$(jq -r '.sast_gate.poll_interval_seconds // 90' the resolved config)
MAX_WAIT=$(jq -r '.sast_gate.max_wait_seconds // 900' the resolved config)
ASK_BEFORE_WAIT=$(jq -r '.sast_gate.ask_user_before_wait // true' the resolved config)
MIN_CLEAN_ROUND=$(jq -r '.qa_agent.approval.min_clean_round // 2' the resolved config)
TINY_RELAX=$(jq -r '.qa_agent.approval.tiny_mr_relax_to_round_1 // false' the resolved config)
TINY_MAX=$(jq -r '.qa_agent.approval.tiny_mr_max_lines_changed // 50' the resolved config)
```

Determine **approval-eligibility for this round** using the same rule as Step 3E:

- `N >= MIN_CLEAN_ROUND`, OR
- `TINY_RELAX = true` AND total lines changed (insertions + deletions from `git diff --stat`) `<= TINY_MAX`.

**Branching:**

- **Gate disabled, OR round is not approval-eligible:** continue silently with the skipped stub. Don't burden the user on early rounds with infra waits. Set `SAST_GATE_STATE="skipped:pipeline-running"` so Step 3E's approval comment reflects that this round did not certify a security delta.

- **Gate enabled AND round is approval-eligible AND running marker present:** call AskUserQuestion (when `ASK_BEFORE_WAIT=true`):

  > *"SAST pipeline is still running. This round is approval-eligible — approving now means the QA round certifies zero security delta. What do you want to do?"*
  > Options (default-first):
  > - **"Wait up to `<MAX_WAIT/60>` min (Recommended)"** — poll every `POLL_INTERVAL` seconds until the pipeline lands or the wait ceiling hits.
  > - **"Proceed without SAST"** — continue with the skipped stub. Set `SAST_GATE_STATE="skipped:pipeline-running"`; Step 3E approval comment will note `SAST: skipped:pipeline-running`.
  > - **"Defer this round"** — STOP the skill with a hint: *"Re-run `/mr-qa <MR> <target>` once the pipeline lands."* Do NOT post a partial round note; nothing has been committed yet to the MR.

  When `ASK_BEFORE_WAIT=false`, skip the prompt and start the poll loop directly.

- **Poll loop (chosen "Wait"):**

  ```bash
  WAITED=0
  while [ "$WAITED" -lt "$MAX_WAIT" ]; do
    sleep "$POLL_INTERVAL"
    WAITED=$((WAITED + POLL_INTERVAL))
    bash ${CLAUDE_PLUGIN_ROOT}/lib/fetch-sast-findings.sh \
      --project "$GITLAB_PROJECT" \
      --mr "$MR_NUMBER" \
      --target-path "<target-path>" \
      --output "$SAST_REPORT"
    if ! grep -Eq "$SAST_RUNNING_RE" "$SAST_REPORT"; then
      break
    fi
  done
  ```

  - Cadence is fixed at `POLL_INTERVAL=90s` by default — chosen to amortize the Anthropic prompt-cache 5-minute TTL (≈3 polls per cache window) instead of burning the cache every minute.
  - If the loop exits because of `MAX_WAIT` (still-running marker still present), re-prompt the user with the same three options (the user can extend the wait by choosing "Wait" again).
  - The poll loop is permitted because the entire `while … sleep 90 … done` is **one** Bash invocation — the harness sees a single long-running command, not many short sleeps. Splitting this into one Bash call per poll would be a forbidden "chain shorter sleeps to work around the block" pattern; do not refactor it that way.

- **Pipeline lands during the wait:** continue with the populated `$SAST_REPORT`. If the helper now emits `## NEW SAST findings`, the reviewer sub-agent in Step 3A sees them normally. Set `SAST_GATE_STATE="clean"` — the gate produced a delta against a finished pipeline (whether or not findings are present).

When the helper completes against a finished pipeline on the first try (no running marker), also set `SAST_GATE_STATE="clean"`.

### Helper failure

If the helper itself fails (missing `glab`/`jq`/`unzip`, unreadable target path), report the failure to the user and ask whether to proceed without SAST review or stop. Do NOT silently swallow helper failures. If the user opts to proceed, set `SAST_GATE_STATE="skipped:helper-failed"` so Step 3E's approval comment surfaces the skip reason.

### Forwarding the report

Pass `$SAST_REPORT` into Step 3A as the `## Security findings (NEW vs baseline)` section of the reviewer prompt. Also include it as a top-level section in the MR comment in Step 3C so the source-of-truth list is visible to the MR author and reviewers regardless of how the agent interprets it.

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

### Step 3A.1 — Delegate the round to the QA manager (default path)

This is the **default review path**. Routing is **deterministic from preflight**:
take this path when `review_mode == "manager"` (non-trivial diff), and the Step 3A
sequential fallback when `review_mode == "sequential"` (tiny diff — a single
reviewer beats the overhead). The one runtime exception preflight cannot predict:
if a manager or lens **spawn is refused** in this runtime (no Agent nesting), fall
back to sequential Step 3A regardless of `review_mode`. `DOUBLE`/`TRIPLE` do
**not** change this routing — the manager runs the preflight-selected lens panel
regardless; the multi-model flags only add second-opinion shims inside it.

**Why a manager subagent (not the `Workflow` tool).** Two reasons:

1. **A clean main loop, hands-free.** A subagent runs the whole noisy round —
   lens fan-out, merge, render, post — in **its own** context; only a compact
   verdict returns to main. Agent nesting to depth 2 (manager → lens
   grandchildren) works here (verified).
2. **Hooks reach the lenses — spawn gate, inside-subagent gates, and startup
   injection all fire.** Verified in this environment: PreToolUse hooks fire inside
   Agent subagents at **depth 2** (a keyword-free grandchild spawn was hard-blocked
   by `agent-cmm-gate`), and PostToolUse fires inside subagents too. So a lens's own
   tool calls are governed by the same gates as the main thread — native `Grep` on
   source → `grep-cmm-gate`; non-exempt large Bash → `ctx-execute-enforcer` (bare
   `grep` is exempt) — on top of the `SubagentStart` code-navigation guidance
   injected into the manager and its lens grandchildren at startup (also verified to
   depth 2). `Workflow`-tool workers reportedly **bypass** these gates (not
   re-verified here) — the original reason to prefer the Agent path. Even so,
   reviewer **correctness does not depend on any of this**: it rests on the diff,
   the acceptance criteria, and definition-site evidence (see
   `agents/qa-reviewer.md`), so the panel still works if that tooling is
   absent.

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
`run_in_background: true`). Pass literal values + scratch **paths** (the manager
and its lenses read the files themselves — do not paste blobs):

```
target_abs=<target-abs>  mr=<MR_NUMBER>  round=<N>
feature_branch=<feature-branch>  target_branch=<target-branch>  diff_range=<remote>/<target-branch>..HEAD
lenses=<preflight.json .lenses array, verbatim — the panel to spawn>
gitlab_project=<gitlab_project>  gitlab_project_enc=<gitlab_project_enc>  qa_scratch=<QA_SCRATCH>
contract_path=<QA_SCRATCH>/contract.md  sast_path=<SAST_REPORT>  schema_change_path=<QA_SCRATCH>/schema-change.md
tool_mandate_path=<QA_SCRATCH>/tool-mandate.md
proportionality_path=<QA_SCRATCH>/proportionality.md
schema_change_detected=<true|false>  skip_contract_verification=<true|false>
DOUBLE=<t|f>  TRIPLE=<t|f>  reviewer_override=<qwen-local|"">
qa_token_ok=<true|false>  expected_qa_user=<qa_agent.expected_username>
qa_token_env=<qa_agent.token_env>    qa_token_file=<qa_agent.token_file>
mr_approved=<true|false>        # preflight's MR_APPROVED — gates the manager's post (see below)
approval_eligible=<true|false>  # YOU compute this — the manager cannot (see below)
unapprove_on_dirty_reround=<true|false>   # qa_agent.approval.unapprove_on_dirty_reround
sast_running=<true|false>       # preflight's sast.running — with the above, lets the manager raise sast_wait
post_note=<true|false>          # true = manager posts the round note itself (option 3 / hands-free)
non_interactive=<true|false>    # from --non-interactive; the manager still returns decisions_needed
```

**`approval_eligible` must be computed by main and passed in.** The manager's
`approval` and `sast_wait` decisions are both conditioned on the round being
approval-eligible, but eligibility depends on `min_clean_round`,
`tiny_mr_relax_to_round_1` and `diff_scope.is_tiny` — none of which the manager is
given, and none of which it can derive from `round` alone. Omit this and the
manager can never raise either decision, so the hands-free path silently never
approves anything. Compute it with the same rule Step 3E uses:

```
approval_eligible = (round >= qa_agent.approval.min_clean_round)
                    OR (qa_agent.approval.tiny_mr_relax_to_round_1 AND diff_scope.is_tiny)
```

Eligibility is *necessary*, not sufficient — Step 3E still re-checks every gate
(clean round, `QA_TOKEN_OK`, and the schema-change preconditions) before approving.
The manager only raises the decision; main decides it.

`qa_token_env` + `qa_token_file` are passed so the manager resolves the QA token
**env-var-first, then file** — the same order Step 0.25 uses. Passing only the
file path lets an env-only token resolve to empty, at which point `glab` silently
posts the round note under the **developer's** identity instead of the QA agent's.

`mr_approved` is what lets the manager honor the Step 3B.6 ordering rule: it must
NOT post a round that found new confirmed critical/major findings onto an MR the
QA agent has already approved. In that case it renders the note, returns
`note_posted=false` and a `decisions_needed` entry of kind `unapprove_before_post`,
and **main revokes the approval first and then posts** — see Step 3B.6.

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

**Hard invariants — the contract the manager MUST satisfy** (each is a defect a
real QA round caught; do not relax them):

1. **Compact structured hand-off.** The manager returns the compact verdict JSON
   defined in `agents/qa-manager.md` (counts, `schema_change_detected`,
   `contract_all_pass`, `failed_lenses`, `note_path`/`note_url`, `decisions_needed`)
   — NOT the raw lens output and NOT a human-facing report. The full round-note
   markdown lives in `note_path`; only the verdict crosses back into main. Lens
   output + merge/render text stay in the manager's context.
2. **Every downstream axis survives the merge** (else the panel regresses vs the
   sequential fallback): per-finding `relevance` (`contract|regression|observation`)
   → observations route into the note's `## Observations` section, never inflating
   the blocking counts; per-finding `schema_change` + a top-level
   `schema_change_detected` → the manager surfaces it in the verdict and main sets
   `SCHEMA_CHANGE_DETECTED=true` **before Step 3E** (arms the the schema-drift case gate — must
   not be silently dropped); a `contract_verification` table **owned by the
   `contract-security` lens only** (other lenses do not re-verify the contract —
   that duplicates split work and invites conflicting verdicts).
3. **A failed lens is never a clean review.** A lens that errors/returns empty is
   re-run once as a standalone `qa-reviewer`; if it fails again it goes in
   `failed_lenses`. **All** of them dead → a FAILED round (no clean post, no approval,
   re-run). Some dead → the note carries `⚠ lens(es) failed: <keys> — axes not
   covered this round` and the missing axes are never treated as clean; if
   `contract-security` is the casualty, render NO contract table and flag it.
4. **Never downgrade the lens model** (cost caveat below).

**Caveats:**

- **Cost — roughly comparable to a serialized review, not N× it.** The bulk of a
  review's tokens is iterative tool-call reasoning (read → search → reason); the
  panel **splits** that across lenses rather than duplicating it, so cumulative
  (context × turns) is roughly conserved. The genuine premium is in the margins:
  each lens re-reads the same diff/files (no shared prompt cache), each carries its
  own fixed preamble, and the manager adds one coordinating agent on top. A
  manager-owned round therefore costs a little **more total tokens** than the
  Workflow path (the manager is an extra agent) but keeps that spend — and the
  entire merge/render — **out of the main context**. If the pain is context
  pollution, this fixes it; if the pain is raw token count, it does not. For a
  large, read-heavy diff the read portion trends additive-per-lens (~N× on reads);
  the levers are **panel width** (preflight-selected, 3-6 — narrow a target's
  `lens_tags` rather than overriding the panel by hand) and the **trivial-MR gate**,
  never the model tier.
- **Do NOT downgrade the model to manage cost.** Each lens (and the manager)
  inherits the session model — a top-capability model, the deliberate QA quality
  bar (the round note attributes QA to Opus). Do not pass a lighter tier to save
  tokens: a cheaper reviewer is a weaker reviewer, which defeats the cycle.
- **Full context per lens.** Give every lens the **full** diff and context, not a
  slice — the lenses differ by *mandate*, not by *input*.
- **Fresh subagents each round.** Manager and lens grandchildren are all
  first-class Agent subagents; each round spawns a **fresh** manager + panel — no
  reused review context (the "fresh sub-agent per round" invariant holds). Project
  hooks reach them: the spawn gate, the inside-subagent PreToolUse/PostToolUse
  gates, and the `SubagentStart` injection all fire for the lenses (PreToolUse
  verified firing at depth 2 in this environment), so a lens is governed by the
  same guards as the main thread, plus the read-only constraint in its own agent
  def.
- **CMM/ctx usage is preflight-gated, not hardcoded.** The skill's prose carries
  **no** hardcoded tool dependency. `preflight.sh` probes whether CMM /
  Context-Mode are registered and writes `$QA_SCRATCH/tool-mandate.md`: an explicit
  "use these tools" mandate when they are available, an **empty file** when they are
  not. The manager (and the sequential Step 3A prompt) inject that file verbatim
  into every lens prompt — so when the tools are present the lenses are told,
  unconditionally, to use them (measured to flip lens adoption from 0 to
  substantial on a real code diff); when absent, nothing is injected and the lenses
  use Read/grep. The `agent-cmm-gate` spawn-gate still exempts both agent types via
  `.claude/cmm-agent-passthrough.txt` (keyword-free spawns pass), and the
  `SubagentStart` hooks add a soft nudge on top. This keeps the skill tool-agnostic
  — it works unchanged if that tooling is ever removed (the mandate file just goes
  empty).

### Step 3A — Launch the QA reviewer sub-agent

> **Sequential fallback.** This step and Step 3A.2 are the path taken only for a
> **trivial diff** or when Agent nesting is unavailable (see Step 3A.1). On the
> default path the `qa-manager` subagent owns the review, merge, and render,
> and returns a compact verdict — skip this step and Step 3A.2 entirely; the
> manager's agent def embeds the same lens mandates and Step 3A.3 merge rules.

**Use the Agent tool** to spawn a fresh sub-agent for the QA review. This is the critical step — do NOT display a prompt and ask the user to paste it elsewhere. Call the Agent tool directly.

> **Why the definition-site evidence requirement exists.** During a previous
> api QA cycle, four rounds of LLM review reported a function `mqttPublish`
> as the root cause of an MQTT-publish bug. Every finding cited `grep -n`
> evidence — the string appeared in comments and docs — but no definition of the
> symbol existed anywhere in the codebase. The LLM had fabricated it from
> adjacent context. Requiring every symbol-existence claim to cite the actual
> definition site (file + line of the definition, confirmed by opening the file)
> makes this class of fabrication trivially detectable, which is why the
> reviewer contract requires it. Do not strip it on grounds of verbosity — the
> cost is one line of evidence per finding; the avoided cost is rubber-stamping
> fabricated bugs.

Use `subagent_type: "qa-reviewer"` (the project-local agent defined in
`agents/qa-reviewer.md`). Pass a prompt constructed from the
template below (fill in all placeholders before calling the Agent tool):

```
You are a read-only QA reviewer. Do NOT modify any files, make commits, or push code.

Working directory: <absolute-path-to-target>
MR: #<MR_NUMBER>
Round: <N>
Feature branch: <feature-branch>
Target branch: <target-branch>
skip_contract_verification: <true|false>   # from the pre-round-1 AskUserQuestion

## Code navigation

<paste the entire contents of $QA_SCRATCH/tool-mandate.md here — the
code-navigation mandate emitted by preflight. It is EMPTY when CMM /
Context-Mode are not available (this section then contributes nothing and the
reviewer uses Read/grep); when they ARE available it instructs the reviewer to
use them. Paste verbatim; do not reword.>

## Proportionality

<paste the entire contents of $QA_SCRATCH/proportionality.md here — the
proportionality mandate emitted by preflight. Unlike the code-navigation
mandate this file is NEVER empty, and preflight escalates its contents at
round >= 3. Paste verbatim; do not summarize, reword, or soften it. It is the
counterweight to a reviewer objective that otherwise optimizes recall alone.>

## Contract

<paste the entire contents of $QA_SCRATCH/contract.md here — the contract
block produced by Step 0.5, including source tag, ticket ID, summary, and
the acceptance-criteria list. If skip_contract_verification=true, the
reviewer should skip the per-criterion verification table but still use the
criteria as semantic context.>

## Security findings (NEW vs baseline)

<paste the entire contents of $SAST_REPORT (i.e. $QA_SCRATCH/sast.md)
produced by Step 2.5 here. If the helper emitted a "SAST review skipped"
stub (pipeline still running, no security stage wired, etc.), include the
stub verbatim — the reviewer should mention the skip in its report. If the
helper failed and the user opted to proceed without SAST data, OMIT this
section entirely. Otherwise the section MUST be present so the reviewer can
weigh security findings alongside code-review findings.

When this section contains real findings, the reviewer SHOULD:
- For each NEW finding, weigh whether the MR introduces it intentionally
  (e.g., a deliberate new dependency with a known CVE the team will track
  separately) or whether it's a regression that should block.
- Cite the finding ID + severity in any related review finding (e.g., a
  code-review finding about a new dependency should reference the OSV
  advisory ID surfaced here).
- Treat trivy_config Dockerfile/k8s misconfigs as findings that need
  per-instance triage even when no baseline exists.
- Treat semgrep top-N findings as advisory inputs (no per-finding baseline
  exists yet); call them out only when severity is HIGH/CRITICAL or when
  they intersect changed files.>

## Schema change

schema_change_detected: <true|false>   # from Step 3A.0.1

<Paste the contents of $QA_SCRATCH/schema-change.md here — preflight writes it
either way, and it states whether a configured schema file changed, and whether the gate ran at all.>

**The schema is whatever `schema.files` names.** Preflight decides
`schema_change_detected` from that path check; do not re-derive it, and do NOT scan
the diff for DDL keywords — that matches test fixtures, comments and even test
labels, and it was tried and removed (see `docs/CASE-STUDIES.md` §schema-drift).
Migrations and per-table artifacts are not the schema.

Emit a dedicated `## Schema Change` section in your report:

- State whether the MR changes `the configured schema file`, and if so whether the change
  looks complete and self-consistent within that file.
- **Your distinct job — the part no file check can do:** flag **code-only schema
  dependencies**, i.e. changed code that reads or writes a column or table not
  present in `the configured schema file`, even when the template did not change. That is
  exactly the failure that broke the release production (the schema-drift case:
  `properties.processIndividually` shipped without the template carrying the
  column). Report it as blocking (relevance `regression`, category
  `schema-change`) — and say so even when `schema_change_detected` is false, so
  the orchestrator can arm the Step 3E gate.
- Do NOT approve or judge rollout readiness — that is the human operator's gate.
  Your job is to surface the change and its propagation status accurately.

## Your process

1. Run `git log <remote>/<target-branch>..HEAD --oneline` to understand the commit narrative.
2. Run `git diff <remote>/<target-branch>..HEAD --stat` to see all changed files.
3. Read each functionally significant changed file in full — not just the diff. Understand
   surrounding context, callers, and invariants. Skip mechanical one-liner additions
   (e.g. `standalone: false`) unless you spot something wrong.
4. Run `glab mr view <MR_NUMBER>` for the MR description and any existing comments.
5. Act as devil's advocate: for each change ask — what happens when input is
   empty/null/huge? What if a network call fails mid-flight? What if the user
   navigates away? Are downstream callers of modified functions still compatible?
6. Check test coverage: does any new service or component lack a spec file?

## Hard constraints

- DO NOT modify any files, create commits, or push code
- DO NOT prescribe what to test upfront — discover what matters by reading the code
- DO NOT dismiss findings as "pre-existing" — if a bug is visible in a file touched
  by the MR, report it. The orchestrator decides what to fix.

## MR context

Title: <MR title>
Key changes: <paste bullet summary of what the MR does, from glab mr view output>

## Report format — return findings in exactly this structure

### Finding 1: <Title>
- **Area:** `<file>` (lines X–Y)
- **What was tested:** <description>
- **Expected:** <behavior>
- **Actual / Risk:** <issue>
- **Severity:** critical / major / minor
- **Status:** confirmed / hypothetical

[repeat for each finding]

### Summary
| Severity | Count |
|---|---|
| Critical | N |
| Major | N |
| Minor | N |
| **Total** | **N** |

If no findings, output: ### No Issues Found
```

Wait for the Agent tool to return its report before proceeding.

### Step 3A.2 — Second-opinion review(s) (when `DOUBLE=true`)

> **Sequential fallback.** On the default path the `qa-manager` subagent runs
> these shims itself (as background Bash, inside its own context) and folds their
> `$QA_SCRATCH/r*-round<N>.md` outputs into the merge — do not run them from main.
> This step's sequential invocation applies only on the trivial-diff / no-nesting
> fallback where main runs the reviewers directly.

When `DOUBLE=true`, after the Claude reviewer returns, invoke one or two
additional reviewers. The contract file was produced in Step 0.5 and is
referenced by all reviewers.

**Reviewer selection (resolved from Step 0 flags):**

| Flag combination | Reviewer 2 | Reviewer 3 |
|---|---|---|
| `--double` (default) | `do-reviewer.sh` model `deepseek-v4-pro` | — |
| `--triple` | `do-reviewer.sh` model `deepseek-v4-pro` | `do-reviewer.sh` model `openai-gpt-5.3-codex` |
| `--double --reviewer=qwen-local` | `qwen-reviewer.sh` (local LM Studio) | — |
| `--triple --reviewer=qwen-local` | `qwen-reviewer.sh` (local LM Studio) | `do-reviewer.sh` model `openai-gpt-5.3-codex` |

**Reviewer 2 — DigitalOcean DeepSeek (default for `--double`):**

`do-reviewer.sh` requires `DO_LLM_API_KEY` in the environment; if unset, the
shim exits 64 and Step 3C treats this as a non-blocking failure.

The shim reviews the range `origin/<target>..origin/<source>` — it reads the
diff AND each changed file's contents from the MR's **source branch ref**, not
from the local working-tree `HEAD`. Always pass `MR_SOURCE_BRANCH=<feature-branch>`
(as shown below) so the review matches the MR even when the submodule working
tree is checked out on another branch. If omitted, the shim resolves the source
branch via `glab mr view`, falling back to local `HEAD` with a warning. (This
guards the historical failure mode where a stray working-tree checkout caused
the second-opinion reviewer to review an unrelated changeset.)

```bash
CONTRACT_FILE="$QA_SCRATCH/contract.md"
R2_OUT="$QA_SCRATCH/r2-round<N>.md"

cd <target-path>
MR_TARGET_BRANCH=<target-branch> \
MR_SOURCE_BRANCH=<feature-branch> \
${CLAUDE_PLUGIN_ROOT}/lib/do-reviewer.sh \
  --mr <MR_NUMBER> \
  --target <TARGET> \
  --round <N> \
  --contract-file "$CONTRACT_FILE" \
  --model "deepseek-v4-pro" \
  $( [ "<skip_contract_verification>" = "true" ] && echo --skip-contract ) \
  --output "$R2_OUT"
```

**Reviewer 2 alternative — local Qwen (when `REVIEWER_OVERRIDE=qwen-local`):**

```bash
MR_TARGET_BRANCH=<target-branch> \
MR_SOURCE_BRANCH=<feature-branch> \
${CLAUDE_PLUGIN_ROOT}/lib/qwen-reviewer.sh \
  --mr <MR_NUMBER> \
  --target <TARGET> \
  --round <N> \
  --contract-file "$CONTRACT_FILE" \
  $( [ "<skip_contract_verification>" = "true" ] && echo --skip-contract ) \
  --output "$R2_OUT"
```

**Reviewer 3 — DigitalOcean GPT-5.3-Codex (only when `TRIPLE=true`):**

```bash
R3_OUT="$QA_SCRATCH/r3-round<N>.md"

cd <target-path>
MR_TARGET_BRANCH=<target-branch> \
MR_SOURCE_BRANCH=<feature-branch> \
${CLAUDE_PLUGIN_ROOT}/lib/do-reviewer.sh \
  --mr <MR_NUMBER> \
  --target <TARGET> \
  --round <N> \
  --contract-file "$CONTRACT_FILE" \
  --model "openai-gpt-5.3-codex" \
  $( [ "<skip_contract_verification>" = "true" ] && echo --skip-contract ) \
  --output "$R3_OUT"
```

**Failure handling (per reviewer, applied independently):**

If a reviewer's wrapper exits non-zero OR its output file is missing/empty: treat as
a **non-blocking failure**. Do NOT retry. Record the failure reason (exit
code and first stderr line). Step 3C will append a one-line
`⚠ <reviewer-tag> second-opinion review failed: <reason>` note. A failing
second-opinion NEVER blocks the round — proceed with whichever reviewers
succeeded.

### Step 3A.3 — Tag-merge findings (when multiple reviewers ran)

When the Claude report plus one or more successful second-opinion outputs
are available, produce a unified report via this merge procedure. The
output of each second-opinion shim already carries its own tag prefix
(`[do:deepseek-v4-pro]`, `[do:openai-gpt-5.3-codex]`, `[qwen]`, etc.); the
merge logic treats every non-Claude reviewer symmetrically.

Let `R` = set of successful reviewer outputs other than Claude (1 or 2
entries). Each `r ∈ R` has a tag prefix `[<tag-r>]` already applied.

1. **Parse** each report into an ordered list of findings. Each finding has:
   `title`, `area_file` (normalized path), `line_range` (low,high — inclusive;
   0,0 if absent), plus the full markdown body.
2. **Prefix** every Claude finding title with `[claude]`. Second-opinion
   findings keep their existing reviewer tag.
3. **Dedupe overlap.** Two findings `A` and `B` are the "same" iff:
   - `A.area_file == B.area_file` AND line ranges overlap (any intersection),
     OR
   - their titles are identical after stripping the leading reviewer-tag
     prefix (the regex `^\[[^]]+\]\s*`, which matches any bracketed tag
     including merged forms like `[claude|do:deepseek-v4-pro]`) and
     lowercasing.
   Apply pairwise between Claude and each `r ∈ R`, and also between every pair
   of second-opinion reviewers when `TRIPLE=true`.
4. **Merge** overlapping groups: keep the most detailed body (default to
   Claude's when present, else the longest non-Claude body). Rewrite the
   prefix to a `|`-joined list of every tag that flagged it, e.g.
   `[claude|do:deepseek-v4-pro|do:openai-gpt-5.3-codex]`. For each concurring
   non-primary reviewer whose wording differed, append a short
   `_<tag> concurred:_` line with that reviewer's finding title.
5. **Unmatched** findings keep their single tag. Group unmatched
   second-opinion findings by tag and append under sub-headings like
   `### <tag>-only findings` (e.g. `### do:deepseek-v4-pro-only findings`),
   after the merged/Claude list.
6. **Contract verification tables.** If multiple reports contain a contract
   table AND they agree row-by-row, keep Claude's table. If any disagree,
   keep Claude's but append a `_<tag> differed on:_` note per disagreeing
   reviewer, listing the row names.
7. **Observations** (pre-existing bugs in touched files) from any reviewer
   go into a dedicated `## Pre-existing issues discovered` section of the
   merged report, so the orchestrator (and ultimately the user) can decide
   whether to file a ticket.

The merged report replaces the Claude-only report for posting in Step 3C.

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
2. For confirmed and critical/major findings, proceed to fix them in the submodule codebase in this session.
3. Each QA round's fixes must be committed as a **single, separate commit** — do not amend previous commits:

```bash
cd <target-path>
git add <changed-files>
git commit -m "fix(<scope>): address QA round <N>"
git push <remote> <feature-branch>
```

Where `<scope>` is `preflight.json`'s top-level **`scope`** string (e.g., `api`, `webapp`, `mobile`, `monorepo`) — the registry value preflight already resolved from `the resolved config`. Read it from `preflight.json`; do not re-read the registry by hand. Note it is `.scope`, **not** `.diff_scope` (which carries the diff numbers).

If there are no actionable findings (all hypothetical or minor), skip the fix commit.

### Step 3B.6 — Revoke approval before posting a dirty re-round note

Before Step 3C posts the round note, decide whether this round needs to
revoke a prior approval. On a "dirty re-round" — i.e. a round that surfaced
new critical or major confirmed findings AFTER a prior round had auto-approved
the MR — the unapprove MUST run before the round note posts, otherwise the
new findings would be posted while the MR is still flagged "approved" by the
QA agent (a visible inconsistency in GitLab).

**First, set `ROUND_HAS_CRITICAL_OR_MAJOR` from the Step 3A report.** The
orchestrator MUST inspect the merged report (or the Claude-only report if
`DOUBLE=false` / both second-opinion reviewers failed) and set the variable
according to this rule:

- `ROUND_HAS_CRITICAL_OR_MAJOR=true` iff the report's Summary table shows
  `Critical > 0` OR `Major > 0` AND those findings carry `Status: confirmed`
  (not `hypothetical`). The hypothetical column does not count.
- `ROUND_HAS_CRITICAL_OR_MAJOR=false` otherwise (no findings, only minor,
  or only hypothetical critical/major).

Set the variable explicitly before the gate below — do NOT rely on an
unset variable evaluating to empty string, which would silently disable
this entire step.

```bash
# A "dirty re-round" is a round that (a) found new critical/major confirmed
# findings AND (b) is running after a prior round had auto-approved the MR.
# Gated by qa_agent.approval.unapprove_on_dirty_reround in the resolved config.
UNAPPROVE_ON_DIRTY=$(jq -r '.qa_agent.approval.unapprove_on_dirty_reround // false' \
  the resolved config)

# ROUND_HAS_CRITICAL_OR_MAJOR was set by the orchestrator just above, based
# on the merged/Claude-only report from Step 3A. If the orchestrator failed
# to set it, treat as false (safer default — we'd rather under-revoke than
# over-revoke), but also emit a warning so the bug surfaces.
if [ -z "${ROUND_HAS_CRITICAL_OR_MAJOR:-}" ]; then
  echo "warn: ROUND_HAS_CRITICAL_OR_MAJOR not set by orchestrator; defaulting to false." >&2
  ROUND_HAS_CRITICAL_OR_MAJOR=false
fi

# A deferred-findings approval (Step 3E) is approved WITH critical/major findings
# open, by deliberate human decision. Re-running /mr-qa then re-finds those same
# findings, which would trip the guard below and silently revoke the approval —
# posting a note calling them "new" when they are the very findings the operator
# deferred. That undoes the exit on the next run, so the guard must fire only on
# findings that are genuinely NEW relative to the deferred set.
#
# ROUND_HAS_NEW_CRITICAL_OR_MAJOR: true iff at least one confirmed critical/major
# finding this round is NOT in the deferred set recorded with the prior approval.
# With no prior deferral the set is empty and this collapses to the old behaviour.
#
# The orchestrator sets ROUND_HAS_NEW_CRITICAL_OR_MAJOR explicitly, the same way it
# sets ROUND_HAS_CRITICAL_OR_MAJOR above — this is a judgment over two finding lists,
# not a shell computation, so do NOT invent a helper to stand in for it:
#
#   - No prior deferral recorded on this MR  -> set it equal to
#     ROUND_HAS_CRITICAL_OR_MAJOR (the old behaviour, unchanged).
#   - A prior deferral exists -> read the deferred-findings note from the MR, then set
#     it true iff at least one confirmed critical/major finding THIS round is absent
#     from that note. Match on title, not on finding id: ids are assigned per round
#     and are not stable across rounds, so an id-only match would silently swallow a
#     genuinely new finding that happened to reuse an id.
#   - Cannot read the prior note -> set it true (revoke). Failing closed here re-opens
#     an approval that may be stale, which is recoverable; failing open leaves a real
#     regression sitting under a green approval, which is not.
if [ -z "${ROUND_HAS_NEW_CRITICAL_OR_MAJOR:-}" ]; then
  echo "warn: ROUND_HAS_NEW_CRITICAL_OR_MAJOR not set by orchestrator; falling back to ROUND_HAS_CRITICAL_OR_MAJOR." >&2
  ROUND_HAS_NEW_CRITICAL_OR_MAJOR="$ROUND_HAS_CRITICAL_OR_MAJOR"
fi

if [ "$QA_TOKEN_OK" = "true" ] \
   && [ "$MR_APPROVED" = "true" ] \
   && [ "$ROUND_HAS_NEW_CRITICAL_OR_MAJOR" = "true" ] \
   && [ "$UNAPPROVE_ON_DIRTY" = "true" ]; then
  cd <target-path>
  if qa_glab mr unapprove <MR_NUMBER>; then
    # F-09: exit-check the revocation comment too, matching Step 3E's pattern.
    if qa_glab mr note <MR_NUMBER> \
        -m "⚠ Approval revoked: round <N> found critical/major findings beyond those previously deferred."; then
      MR_APPROVED=false
    else
      echo "warn: revocation note POST failed but unapprove succeeded — MR is un-approved on GitLab but has no audit comment for this round." >&2
      MR_APPROVED=false
    fi
  else
    echo "warn: qa_glab mr unapprove failed; leaving MR_APPROVED=true and proceeding." >&2
  fi
fi
```

The variable `MR_APPROVED` carries the seeded value from Step 0.7 (across
invocations) and any in-invocation approval/unapprove transitions. Step 3E's
unapprove branch is now redundant — it has been removed there to keep the
single source of truth for revocation in this step.

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

---
<if QA_TOKEN_OK=true:>
*QA performed by <qa_agent.expected_username from the resolved config> via Claude Code (<the model you are actually running as — not a literal copied from this file; a hardcoded id rots and misattributes the review. If you cannot determine it, write "Claude Code" with no parenthetical>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` where tag is the reviewer's tag, e.g. ` + do:deepseek-v4-pro` or ` + do:openai-gpt-5.3-codex` or ` + qwen3-14b (LM Studio)`>
<else (QA_TOKEN_OK=false): omit the "<username> via " prefix:>
*QA performed by Claude Code (<the model you are actually running as — see the note above>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` as above>

<if QA_TOKEN_OK=false, also include this warning line inside the comment body (above the footer):>
> ⚠ Posted with dev credentials — QA agent token unavailable.
EOF
cd <target-path>
if [ "$QA_TOKEN_OK" = "true" ]; then
  # Post as the QA agent so the comment is attributed to it.
  qa_glab mr note <MR_NUMBER> -m "$(cat "$QA_SCRATCH/note-round<N>.md")"
else
  # Fall back to the dev token. The warning line above already explains
  # why the comment is being posted under the dev identity.
  glab mr note <MR_NUMBER> -m "$(cat "$QA_SCRATCH/note-round<N>.md")"
fi
```

### Step 3D — Assess whether to continue

After each round, evaluate the findings:

- **If the round is clean** (no findings, or only hypothetical/minor with nothing to fix): announce the round came back clean. If this is at least round 2, tell the user the MR is ready to mark for review.
- **If critical or major confirmed findings were found and fixed** (own branch): announce that another round is required. Ask: *"Ready to run QA round <N+1>?"* If yes, post this round's note first (it is what makes the next derivation return N+1), then **re-run `preflight.sh`** and take the new `round` and the freshly rendered `proportionality.md` from it. Do NOT increment the round by hand and reuse the existing scratch files — preflight re-runs the sync and re-renders the mandate for the new round in the same pass, which is the only thing that keeps the round number and the proportionality tier in agreement (see Step 3).
- **If critical or major findings were reported but not fixed** (someone else's branch, report-only mode): announce the findings have been posted. The QA cycle pauses here — the author needs to apply fixes before further rounds can be meaningful. Tell the user: *"QA report posted. Once {author} addresses the findings, run `/mr-qa {MR_NUMBER} {SUBMODULE}` again to continue QA."*
- **After 4 rounds**: if findings persist beyond round 4, present a summary of remaining open issues and ask the user how to proceed.
- **On a `diminishing_returns` decision** (any round): stop and ask, regardless of round number. Do not roll into another round on the assumption that more review is always safer — the failure mode this catches is the opposite one. A useful check when deciding: **if most of this round's blocking findings target code an earlier QA round introduced rather than the change the MR exists to make, the cycle has stopped adding value.** Ending it there, with the remaining findings explicitly deferred and enumerated in a note, is a legitimate and complete outcome — see the Step 3E deferred-findings exit.

> **Staying in sync during QA rounds:** If the target branch advances while QA rounds are in progress, re-run Step 2 (sync) before each new round to keep the diff clean.

### Step 3E — Approve the MR

`MR_APPROVED` was seeded from GitLab in Step 0.7 and may have been flipped to
`false` by Step 3B.6 (dirty re-round revocation). It is the single source of
truth for whether the QA agent has currently approved this MR.

**Schema-change approval gate (mandatory — runs first).** If
`SCHEMA_CHANGE_DETECTED=true` (set in Step 3A.0.1, or set by the orchestrator
after a reviewer code-only-dependency finding), this MR is **never
auto-approved by the QA agent alone**. A schema change is the *one* case that
requires a real human in the GitLab approval loop — schema changes have broken
production (the schema-drift case), so a person, not just the agent, must sign off. Two
conditions must BOTH hold before the QA agent may add its (additive, second)
approval:

1. **A human GitLab approval already exists.** Confirm at least one approver
   that is neither the MR author nor the QA agent (`expected_username`) has
   approved **on GitLab**. A chat acknowledgement is NOT a GitLab approval and
   does NOT satisfy this requirement.

   ```bash
   # Use the /approvals endpoint — it reflects approvals more reliably than
   # /approval_state, which has been observed to lag (return an empty
   # approved_by) immediately after a human approves.
   HUMAN_APPROVERS=$(qa_glab api \
     "projects/${GITLAB_PROJECT_ENC}/merge_requests/${MR_NUMBER}/approvals" 2>/dev/null \
     | jq -r --arg author "$MR_AUTHOR" --arg qa "$expected_username" \
         '[.approved_by[]?.user.username | select(. != $author and . != $qa)] | length')
   if [ "${HUMAN_APPROVERS:-0}" -ge 1 ]; then SCHEMA_HUMAN_APPROVED=true; else SCHEMA_HUMAN_APPROVED=false; fi
   ```

   (`MR_AUTHOR` is the MR author captured in Step 0; `expected_username` and the
   `qa_glab` helper come from Step 0.25; `GITLAB_PROJECT_ENC` from Step 0.7.)

2. **The rollout/base-file checklist is acknowledged.** Present an
   `AskUserQuestion`:

   > *"⚠️ This MR contains a **schema change**. Confirm before approval: (1) the
   > change is propagated to the base file the upgrade reads (`the configured schema file`
   > — the single file that IS the schema), and (2) the cluster Dev/Prod
   > Template DB will be refreshed per `docs/runbooks/schema-change-rollout.md`
   > before rollout. Acknowledge?"*
   > Options:
   > - **"No, not yet (Recommended default)"** — sets `SCHEMA_CHANGE_ACK=false`.
   > - **"Yes, acknowledged"** — sets `SCHEMA_CHANGE_ACK=true`.

Record both `SCHEMA_HUMAN_APPROVED` and `SCHEMA_CHANGE_ACK` in the round note
(Step 3C) and in `$QA_SCRATCH`. The QA agent may approve a schema-change MR only
when BOTH are `true`. If either is false, the MR MUST NOT be approved this round
no matter how clean it is:

- `SCHEMA_HUMAN_APPROVED=false` → record approval status
  `blocked: schema change needs a human GitLab approval first` and tell the
  operator to obtain a human GitLab approval, then re-run `/mr-qa` so the QA
  agent can add its second approval.
- `SCHEMA_CHANGE_ACK` not `true` → record
  `blocked: schema change rollout not acknowledged`.

This gate is independent of `QA_TOKEN_OK`: the schema change and its
human-approval requirement must be surfaced even when the skill cannot approve
on its own (in which case the human approves manually in GitLab and the operator
merges after the rollout is handled). When `SCHEMA_CHANGE_DETECTED=false`, skip
this gate entirely — `SCHEMA_CHANGE_ACK` and `SCHEMA_HUMAN_APPROVED` are not
applicable, and **no human GitLab approval is required**: the QA agent approving
on its own after a clean, approval-eligible round is the expected, sanctioned
path for non-schema MRs.

**Approval gate.** Consider approving only when ALL of these hold:

- `QA_TOKEN_OK=true` (the QA agent token resolved and verified in Step 0.25).
- If `SCHEMA_CHANGE_DETECTED=true`, then BOTH `SCHEMA_CHANGE_ACK=true` AND `SCHEMA_HUMAN_APPROVED=true` (a human — neither the MR author nor the QA agent — has already approved on GitLab; see the schema-change gate above). For non-schema MRs (`SCHEMA_CHANGE_DETECTED=false`), **no** human GitLab approval is required — QA-agent-alone approval after a clean round is the sanctioned path.
- The current round is **clean** — no confirmed critical or major findings (hypothetical/minor are OK) — **OR** the deferred-findings exit below applies.

  **Deferred-findings exit.** When `qa_agent.approval.allow_deferred_findings_exit` is true, a round with open confirmed critical/major findings is still approval-eligible if BOTH hold:

  1. The manager raised a `diminishing_returns` decision for this round (or the operator declared one), and
  2. **every** remaining confirmed critical/major finding has been explicitly deferred by the operator via AskUserQuestion, and each one is **enumerated by id and title in a posted note** before the approval.

  This exists because the stop-rule and the gate otherwise contradict each other: `diminishing_returns` means "stop with findings open", the gate demands a clean round, so following the panel's own recommendation made an MR permanently unapprovable — an endless cycle turned into a stuck one. That is a worse failure than the one the stop-rule was added to fix.

  Deferral is a **human** decision. The skill never infers it: `--non-interactive` must NOT defer findings (treat the round as not approval-eligible and stop), and `--auto-approve` skips only the final confirm, never the per-finding deferral. A finding that is deferred but not written into the note has not been deferred — the audit trail is the whole point, since the approval now rests on it rather than on the absence of findings.

  The approval comment MUST say the approval rests on deferred findings and point at the note listing them. Never present a deferred-findings approval as a clean round.

  **Posting the enumeration note (do this BEFORE the approve).** The note is not
  optional prose — it is the entire evidentiary basis for the approval, so the exit is
  not available until it exists and its URL is captured. Nothing else in the skill posts
  it: the round note (Step 3C) lists what was *found*, not what the operator chose to
  *defer*, and those are different sets.

  After the operator has deferred every remaining confirmed critical/major finding via
  AskUserQuestion, record each one's id and title, post them as a single note, and
  capture its URL into `DEFERRED_NOTE_URL` (Step 3E's approval comment interpolates it):

  ```bash
  # DEFERRED_FINDINGS: one "id<TAB>title" line per operator-deferred finding.
  # Refuse to proceed on an empty list — an approval citing an empty note is worse
  # than no approval, because it looks audited.
  if [ -z "${DEFERRED_FINDINGS:-}" ]; then
    echo "error: deferred-findings exit taken but no findings were enumerated. Refusing to approve." >&2
    DEFERRED_FINDINGS_EXIT=false
  else
    {
      echo "## Deferred findings — round <N>"
      echo
      echo "The QA cycle ended on a \`diminishing_returns\` decision. The operator has"
      echo "explicitly deferred the confirmed critical/major findings below. They are"
      echo "**open, not fixed.** The approval that follows rests on this list."
      echo
      printf '%s\n' "$DEFERRED_FINDINGS" | while IFS="$(printf '\t')" read -r _id _title; do
        printf -- '- **%s** — %s\n' "$_id" "$_title"
      done
    } > "$QA_SCRATCH/deferred-round<N>.md"

    # Capture the note URL. `glab mr note` prints it on success; fall back to the
    # MR URL rather than interpolating an empty string into the approval comment.
    DEFERRED_NOTE_URL=$(qa_glab mr note <MR_NUMBER> \
      -m "$(cat "$QA_SCRATCH/deferred-round<N>.md")" 2>/dev/null \
      | grep -oE 'https://[^[:space:]]+' | head -1)
    if [ -z "$DEFERRED_NOTE_URL" ]; then
      echo "error: could not post or resolve the deferred-findings note. Refusing to approve." >&2
      DEFERRED_FINDINGS_EXIT=false
    else
      DEFERRED_FINDINGS_EXIT=true
    fi
  fi
  ```

  If either guard fires, `DEFERRED_FINDINGS_EXIT` stays `false` and the approval gate
  does not pass — the round ends unapproved, which is the correct outcome when the
  audit trail could not be written.
- Either:
  - Round number `N >= qa_agent.approval.min_clean_round`, OR
  - `qa_agent.approval.tiny_mr_relax_to_round_1=true` AND `diff_scope.is_tiny=true` (preflight computed it: `diff_scope.total_changed <= qa_agent.approval.tiny_mr_max_lines_changed`).

When the gate passes AND `MR_APPROVED=false`, confirm via AskUserQuestion before approving:

- On a **clean** round:
  > *"Round N came back clean. Approve MR as `<qa_agent.expected_username>`?"*
- On the **deferred-findings exit** (do not call it clean — it is not):
  > *"Round N ended on diminishing returns with `<K>` confirmed critical/major finding(s)
  > deferred and enumerated in `<note-url>`. Approve MR as
  > `<qa_agent.expected_username>` on that basis?"*

> Options (either wording):
> - **"Yes, approve (Recommended)"** — proceed to approve.
> - **"Skip approval"** — leave the MR unapproved; do not ask again this round.

**`--auto-approve` skips that confirm** (`AUTO_APPROVE=true` from argv, Step 0)
— it is the *only* thing that does, and it is what makes a clean round fully
hands-free. It skips the **prompt**, never a **gate**: every bullet in the
approval gate above still has to pass, so `--auto-approve` with an unverified QA
token, or on a round below `min_clean_round`, still does not approve. On a round
with confirmed critical/major findings it does not approve **either**, with one
deliberate exception: the deferred-findings exit, which requires a human to have
deferred each finding one by one — `--auto-approve` skips only the final confirm,
never those deferrals, so it cannot reach that path on its own. In particular it
does **not** relax the
schema-change gate — when `SCHEMA_CHANGE_DETECTED=true`, `SCHEMA_HUMAN_APPROVED`
and `SCHEMA_CHANGE_ACK` are hard preconditions, and `SCHEMA_CHANGE_ACK` is
sourced from a real human answer, so a schema-change MR can never be approved by
`--auto-approve` alone. That is deliberate: the schema-drift case broke production precisely
because a schema change shipped without a human in the loop.

```
if gate passes AND MR_APPROVED=false:
    if AUTO_APPROVE:  approve without prompting
    else:             AskUserQuestion (above); approve only on "Yes, approve"
```

On approve, branch the comment text on `SAST_GATE_STATE` (set in Step 2.5)
so the audit trail records whether the approval certifies a real SAST delta
or merely the QA code review. Wrap the approve + comment in exit-code checks
so a partial failure (e.g. approve succeeds but the note POST fails) does not
leave `MR_APPROVED` lying about the on-server state:

```bash
cd <target-path>

# SAST_GATE_STATE must be one of the terminal values preflight can emit. This
# whitelist is the CONSUMER side of a producer/consumer contract: the producer is
# preflight.sh's own shape assertion, which validates `.sast.gate_state` against
# the same six values before it will emit preflight.json.
#
# KEEP THESE TWO LISTS IDENTICAL. They drifted once already: a fix added
# `skipped:no-pipeline` + `skipped:unknown` to the producer and its assertion but
# not here, so a clean, approval-eligible round hard-exited 7 with a diagnostic
# blaming Step 2.5 — which had in fact assigned correctly. `skipped:no-pipeline`
# is a ROUTINE state (preflight pushes the sync merge; GitLab has not created the
# pipeline yet), so this was reachable on the normal path.
case "${SAST_GATE_STATE:-}" in
  clean|skipped:no-stage|skipped:no-pipeline|skipped:pipeline-running|skipped:helper-failed|skipped:unknown) ;;
  *)
    echo "error: SAST_GATE_STATE='${SAST_GATE_STATE:-<unset>}' is not a terminal state preflight can emit. Producer/consumer drift — reconcile this list with preflight.sh's shape assertion. Refusing to approve." >&2
    exit 7
    ;;
esac

# Build the approval comment text. Two independent axes:
#   DEFERRED_FINDINGS_EXIT — did this approval come via the deferred-findings exit
#                            rather than a clean round? Set true by the operator when
#                            that exit was taken; $DEFERRED_NOTE_URL points at the
#                            posted note enumerating the deferred findings.
#   SAST_GATE_STATE        — whether a real SAST delta was computed.
#
# The deferred branch is NOT optional decoration: a deferred-findings approval rests on
# that enumerated note, not on the absence of findings, so calling it a "clean round"
# posts a false statement into the audit trail — which is exactly what the exit's own
# rule forbids. Never collapse these two branches back into one.
if [ "${DEFERRED_FINDINGS_EXIT:-false}" = "true" ]; then
  APPROVE_NOTE="✅ Approved by QA agent after round <N> — **NOT a clean round**. This approval rests on confirmed critical/major findings that the operator explicitly deferred; they are enumerated in ${DEFERRED_NOTE_URL}. It does not assert those findings were fixed."
else
  APPROVE_NOTE="✅ Approved by QA agent after clean round <N>."
fi
if [ "$SAST_GATE_STATE" != "clean" ]; then
  APPROVE_NOTE="$APPROVE_NOTE (SAST: ${SAST_GATE_STATE})."
fi

if qa_glab mr approve <MR_NUMBER>; then
  if qa_glab mr note <MR_NUMBER> -m "$APPROVE_NOTE"; then
    MR_APPROVED=true
  else
    echo "warn: mr approve succeeded but approval-comment POST failed; MR is approved on GitLab but the audit comment was not recorded." >&2
    MR_APPROVED=true
  fi
else
  echo "warn: qa_glab mr approve failed; leaving MR_APPROVED=$MR_APPROVED unchanged." >&2
fi
```

**Unapprove on a dirty re-round** is handled in Step 3B.6 (it must run before
the round note posts so the new findings are not posted on an approved MR).
This step only handles the approve transition.

When `QA_TOKEN_OK=false`, skip this step entirely — record the approval status as `skipped (token unavailable)` for Step 4.

---

## Step 4 — Final status report

After the QA cycle ends (clean round or user decision to stop), output a summary:

```
## QA Cycle Complete — MR #<MR_NUMBER> — <submodule>

- Rounds completed: N
- Round N came back: clean / minor-only / hypothetical-only
- Fix commits added: N
- QA reports posted to MR: N
- Approval status: approved-by-qa-agent / not-approved / skipped (token unavailable)

Next steps:
- Mark the MR as ready for review (remove Draft status if applicable)
- Ensure the submodule commit is referenced in the parent workspace (if required)
```

---

## Notes

- **Never push to protected branches** — the authoritative list is `protected_branches` in `the resolved config`. The MR's own target branch is also off-limits regardless of whether it appears in that list. Only push to the feature branch.
- **Each fix commit must be separate** — never amend commits after a QA round is posted.
- **Fresh sub-agent per round** — each Agent tool call is a new invocation with no prior context, which is what produces unbiased findings. Never reuse a session that already reviewed the branch. This holds for the Step 3A.1 workflow path too — each round spawns a fresh reviewer panel.
- **The round is delegated to a QA manager subagent (default path)** — Step 3A.1 spawns one `qa-manager` Agent that fans out the **preflight-selected** `qa-reviewer` panel (3-6 lenses, from `preflight.json`'s `lenses` array) **concurrently** as its own Agent grandchildren, merges/renders/posts in its own context, and returns only a compact verdict to main. Lens choice is deterministic (three core lenses always + conditional lenses per the target's `lens_tags` and the live schema signal, capped at 6) — not model judgment, the same principle as `review_mode`. This replaces the earlier `Workflow`-tool fan-out to keep all lens/merge/render noise out of the main context (cleaner main loop; slightly higher total tokens — the manager is one extra agent). The panel is the default whenever the diff is non-trivial (sequential Step 3A fallback only for a tiny diff, or if Agent nesting is unavailable); `--double`/`--triple` only add second-opinion shims *inside* the manager. Every lens (and the manager) keeps the session's top-capability model — QA never downgrades to a cheaper tier; manage per-round cost via panel width and the trivial-MR skip, not model choice. `--non-interactive` (defaultable gates auto-answered) + `--auto-approve` (skips the Step 3E confirm on an otherwise-passing round) make a clean round fully hands-free — **neither flag can bypass the schema-change human-approval gate**. The review path comes from preflight's `review_mode`; the concurrency comes from the manager's Agent fan-out. **The skill does not use the `Workflow` tool at all** — the old detection step, its `workflows_supported` field, and the `detect-workflows-support.sh` helper were deleted rather than left as dead weight explaining why they were dead.
- **A cycle may end with findings open.** `diminishing_returns` + the Step 3E deferred-findings exit are a matched pair and neither works alone: the stop-rule tells you to stop with findings open, and the exit is what lets such an MR still be approved. Shipped without the exit (as it briefly was), the stop-rule only converted an endless cycle into a stuck one — the MR became permanently unapprovable, which is worse than the problem it solved. The price of the exit is that approval now rests on an enumerated deferral list in a posted note rather than on the absence of findings, so that note is load-bearing: a deferred finding that is not written down has not been deferred.
- **Proportionality is injected on every round, and escalates.** preflight always writes `$QA_SCRATCH/proportionality.md`; Step 3A and the manager inject it verbatim as a `## Proportionality` section of every lens prompt, by the same titled-section rule as the code-navigation mandate. It exists because the reviewer contract optimizes **recall** — assume slop, find every substantive bug — with nothing on the other side of the scale. Measured on gitops-ansible !12, a 40-line credential fix: round 1 produced 6 findings, all in the role; round 2 added a variable round 3 then removed (net zero across two rounds); round 3's fix added a 230-line test play, and **round 4 was 11 of 14 findings about that test play**. The diff grew 9x, the shipped behaviour had been correct since round 2, and no individual finding was wrong — the aggregate was worthless. The mandate stays light at rounds 1-2, where real defects still surface, and tightens at `round >= 3` where the value curve flattens. At the strict tier it also asks the lens to say outright when most of its blocking findings target code an *earlier QA round* introduced; the manager raises that as a `diminishing_returns` decision, and it is a legitimate reason to end the cycle with findings still open. A reviewer that concludes "this change is correct" has produced a complete result.
- **Code-navigation tooling is injected, never assumed** — the skill's *correctness* does not depend on CMM/context-mode being installed. preflight probes whether they are registered and writes `$QA_SCRATCH/tool-mandate.md`: a "use these" block when they are available, **empty** when they are not. Step 3A / the manager inject that file verbatim as a `## Code navigation` section of the lens prompt, so with no tooling present the prompt says nothing about it and the lens simply uses Read/grep — the review is correct either way. The agent *definitions* stay tool-agnostic; the tool names live only in preflight's mandate emitter. (Delivery detail that matters: the mandate must land as a **titled `## Code navigation` section**. Measured on a real diff — no mandate: 0 tool calls; the same text as a detached preamble above a `---` divider: 0, ignored; as a titled section: ~9. Adoption is substantial but stochastic, not exhaustive.)
- **Submodule context:** When the target is a submodule, remind the user after the QA cycle that a parent workspace commit may be needed to update the submodule reference if the branch has new commits. Skip this note when the target is `monorepo`.
- **Switching trunks vs. patches:** This now happens automatically when you switch monorepo branches — each branch carries its own `.branchconfig.yaml` declaring its base branches. `the resolved config` is only edited to add/remove a target or change its path/remote/scope, or to update the `qa_agent` / `sast_gate` / `security_stage` policy. The `_production_reference` block in `the resolved config` is historical and can be removed once every active monorepo branch has a `.branchconfig.yaml`.
- **Two GitLab identities:** QA notes and approvals run under the QA agent token (`qa_agent` block in `the resolved config`); git pushes and fix commits stay on the user's dev token. If the QA agent token is missing, the skill degrades gracefully — posts notes with the dev token and skips approval.
