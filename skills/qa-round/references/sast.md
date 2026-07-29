# Security-scan (SAST/SCA) delta

**Read this only when the target has `security_stage: true`.** Otherwise preflight writes
a stub, sets `sast.gate_state = skipped:no-stage`, and there is nothing here you need.

`sast.gate_state` is a six-value contract shared by preflight's own assertion and the
approval step. Only `clean` asserts that a scan actually ran; every `skipped:*` value
means it did not, and none of them may be treated as a security review.

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
