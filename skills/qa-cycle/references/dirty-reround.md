# Revoking an approval before posting a dirty re-round

**Read this only when `MR_APPROVED=true`** — i.e. a previous round approved the MR and
this round found new blocking findings. On every other round it is a no-op.

Ordering is the whole point: the revocation must happen BEFORE the round note posts, or
the new findings appear on an MR still flagged approved.

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
# open, by deliberate human decision. Re-running /qa-cycle then re-finds those same
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
  # Through the seam. On GitHub there is no "unapprove": forge_unapprove
  # DISMISSES the QA identity's own latest approving review, which is the same
  # outcome. Nothing to dismiss counts as success — there is no approval left to
  # revoke, which is the state this block wants.
  printf '%s\n' "⚠ Approval revoked: round <N> found critical/major findings beyond those previously deferred." \
    > "$QA_SCRATCH/revoke-note.md"
  if forge_unapprove "$PROJECT" <MR_NUMBER> "$QA_TOKEN"; then
    # F-09: exit-check the revocation comment too, matching Step 3E's pattern.
    if forge_post_note "$PROJECT" <MR_NUMBER> "$QA_SCRATCH/revoke-note.md" "$QA_TOKEN" >/dev/null; then
      MR_APPROVED=false
    else
      echo "warn: revocation note POST failed but unapprove succeeded — the MR/PR is un-approved on the forge but has no audit comment for this round." >&2
      MR_APPROVED=false
    fi
  else
    echo "warn: forge_unapprove failed; leaving MR_APPROVED=true and proceeding." >&2
  fi
fi
```

The variable `MR_APPROVED` carries the seeded value from Step 0.7 (across
invocations) and any in-invocation approval/unapprove transitions. Step 3E's
unapprove branch is now redundant — it has been removed there to keep the
single source of truth for revocation in this step.
