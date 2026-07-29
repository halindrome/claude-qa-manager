# Approval: gates, schema preconditions, and the deferred-findings exit

**Read this only on an approval-eligible round.** The spine states the gate conditions; the
detail here covers the schema-change preconditions, the deferred-findings exit, and the
exact comment wording, which must never present a deferred-findings approval as clean.

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
