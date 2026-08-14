# Sequential fallback and multi-model reviewers

**Read this only if** `review_mode == "sequential"` (a tiny diff, where one reviewer beats
the panel's overhead), an Agent spawn was refused so the panel is unavailable, or
`--double`/`--triple` was passed.

On the default path the `qa-manager` subagent owns the review, merge, and render, and its
agent definition already embeds these mandates and merge rules — none of this is needed.

### Step 3A — Launch the QA reviewer sub-agent

> **Sequential fallback.** This step and Step 3A.2 are the path taken only for a
> **trivial diff** or when Agent nesting is unavailable (see Step 3A.1). On the
> default path the `qa-manager` subagent owns the review, merge, and render,
> and returns a compact verdict — skip this step and Step 3A.2 entirely; the
> manager's agent def embeds the same lens mandates and Step 3A.3 merge rules.

**You own the round-level bookkeeping on this path.** The manager normally does it,
and on this path there is no manager — so without the four steps below a sequential
round reports no progress, contributes nothing to timing history, and has no
detection at all if the working tree changes underneath it. That gap is not
theoretical: every one of these was built for the panel and simply never reached the
fallback, which is the path every tiny MR takes.

Use **Bash** for each (a `>` redirect), not the `Write` tool — `Write` refuses to
overwrite a file it has not read this session, so it costs an error plus a read plus
a retry on a file you rewrite several times.

1. **Before spawning**, clear the previous round's per-reviewer files, stamp the
   fan-out time, and snapshot the tree. The scratch dir is keyed to the MR, not the
   round, so anything left behind is read as belonging to this round:
   ```bash
   rm -f "$QA_SCRATCH"/lens-*.json     # round N-1's results are NOT this round's
   date +%s > "$QA_SCRATCH/fanout"
   snap() { git -C "<target-abs>" rev-parse HEAD; git -C "<target-abs>" rev-parse --abbrev-ref HEAD
            git -C "<target-abs>" status --porcelain; }
   snap > "$QA_SCRATCH/tree-before.txt"
   ```
2. **Rewrite `status`** at every phase transition — `reviewing`, then `merging`,
   `rendering`, `posting`, `done`. Copy every field through from the line already
   there except `phase` and the completed count; `epoch_start`, `target_abs` and
   `lens_stall_seconds` are resolved by preflight and must not be re-derived:
   ```bash
   printf '%s|%s|%s|reviewing|%s|%s|%s|%s|%s\n' \
     "$mr" "$target" "$round" "$done" "$total" "$start" "$target_abs" "$lens_stall" \
     > "$QA_SCRATCH/status"
   ```
   The file's mtime is what proves the round is alive, so rewrite it even when the
   count has not moved.
3. **When the reviewer returns**, write its findings to
   `$QA_SCRATCH/lens-<name>.json` and re-snapshot the tree into `tree-after.txt`.
   If it differs from `tree-before.txt`, the reviewer wrote to the tree: report it,
   name the paths, and do **not** auto-revert — a reviewer's leftover and the
   author's own uncommitted work are indistinguishable.
4. **At the end of the round**, record the timing:
   ```bash
   bash "${CLAUDE_PLUGIN_ROOT}/lib/record-timing.sh" "$QA_SCRATCH"
   ```

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

Use `subagent_type: "claude-qa-manager:qa-reviewer"` — the agent defined in
`agents/qa-reviewer.md`, named with its plugin prefix. The bare `qa-reviewer` resolves
only while nothing else on the machine claims that name; where a sibling QA plugin is
installed the spawn fails outright, which is a hard stop mid-round. Pass a prompt
constructed from the template below (fill in all placeholders before calling the Agent
tool):

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
4. Read the MR/PR description via the forge seam (`forge_view_mr . <MR_NUMBER> | jq -r .description`)
   and any existing comments via `forge_notes "$PROJECT" <MR_NUMBER>`. Do not call `glab`/`gh`
   directly — the seam dispatches on the remote and works for both forges.
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
Key changes: <paste bullet summary of what the MR does, from forge_view_mr output>

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

### Where the shims run on the manager path

On the default (manager) path the second-opinion shims run *inside* the manager as
background Bash, not from the main loop. Their argv is unchanged and so are the
per-reviewer failure semantics below — non-zero exit OR missing/empty output → record it,
do not retry, and never read a failed shim as a zero-finding success. Only the launch site
moves. `--double`/`--triple` do not change review routing; they add reviewers inside
whichever path preflight selected.

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
branch via the forge seam's `forge_view_mr`, falling back to local `HEAD` with
a warning. (This
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
   whether to file a ticket. On this path **you** also owe Step 3C.5 the
   ledger append the manager would otherwise hand over — the end-of-cycle
   "Carried forward" report is built from that file, so skipping it here
   makes a sequential cycle end by reporting no observations at all.

The merged report replaces the Claude-only report for posting in Step 3C.
