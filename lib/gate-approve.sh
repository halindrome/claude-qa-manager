#!/usr/bin/env bash
# gate-approve.sh — decide whether the Step 3E approval preconditions hold.
#
# Usage:
#   gate-approve.sh <scratch-dir> --round-blocking <true|false> [flags]
#     --round-blocking <bool>   round_has_critical_or_major, from the round verdict
#     --schema-ack <bool>       operator acknowledged the rollout/base-file checklist
#     --deferred-exit <bool>    approving via the deferred-findings exit, not a clean round
#     --deferred-note-url <url> the posted note enumerating the deferred findings
#
# Exit: 0 approve-allowed | 1 REFUSED | 2 usage | 5 internal
# Prints one JSON object on stdout either way. The exit code and `.decision`
# always agree; callers may use either.
#
# WHY THIS EXISTS. Approval is the highest-stakes thing the tool does -- it is the
# output that enters someone's audit trail as "this was reviewed". Its five
# preconditions are all mechanically checkable, and until now all five were
# checked by a model READING PROSE in references/approval.md. That is the same
# shape as every other defect this project has recorded: a check whose execution
# depends on remembering to perform it.
#
# IT FAILS CLOSED, AND THAT IS THE WHOLE DESIGN. Any check this script cannot
# EVALUATE is `unevaluable`, and any unevaluable check refuses. An approval gate
# that passes when it cannot see is not a gate -- it is the "absent check reports
# as a pass" failure (invariant 2) applied to the one decision where fabricating a
# result is worst. Degrading a note loses information; degrading an approval
# INVENTS it. See docs/CASE-STUDIES.md §self-approval-fallback.
#
# WHAT IT DOES NOT DO. It does not approve, and it never will. It establishes
# premises; a human still decides. `decision: "approve"` means "the preconditions
# hold", not "go ahead" -- Step 3E still asks. Moving the confirmation itself into
# a script was considered and rejected: the operator's judgement is the point of
# the gate, not an obstacle to it.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die_usage()    { echo "gate-approve.sh: $1" >&2; exit 2; }
die_internal() { echo "gate-approve.sh: $1" >&2; exit 5; }

S="${1:-}"
[ -n "$S" ] || die_usage "usage: gate-approve.sh <scratch-dir> --round-blocking <true|false> [flags]"
shift
[ -d "$S" ] || die_usage "no such scratch dir: $S"
PF="$S/preflight.json"
[ -f "$PF" ] || die_usage "no preflight.json in $S"

ROUND_BLOCKING=""; SCHEMA_ACK=""; DEFERRED_EXIT="false"; DEFERRED_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --round-blocking)    ROUND_BLOCKING="${2:-}"; shift 2 ;;
    --schema-ack)        SCHEMA_ACK="${2:-}"; shift 2 ;;
    --deferred-exit)     DEFERRED_EXIT="${2:-}"; shift 2 ;;
    --deferred-note-url) DEFERRED_URL="${2:-}"; shift 2 ;;
    *) die_usage "unknown flag: $1" ;;
  esac
done

# ---------------------------------------------------------------------------
# Reasons accumulate as JSON objects. `unevaluable` is a FIRST-CLASS state, not a
# variant of fail: "CI failed" and "I could not reach the forge" are different
# facts, and collapsing them either sends someone hunting a defect that does not
# exist or certifies code nothing examined. Both refuse; only the wording differs,
# and the wording is what the operator acts on.
# ---------------------------------------------------------------------------
REASONS=""
_add() {  # $1 check, $2 pass|fail|unevaluable, $3 detail
  REASONS="${REASONS}$(jq -nc --arg c "$1" --arg s "$2" --arg d "$3" \
    '{check:$c, state:$s, detail:$d}')
"
}
BLOCKERS=0
_pass() { _add "$1" pass        "$2"; }
_fail() { _add "$1" fail        "$2"; BLOCKERS=$((BLOCKERS+1)); }
_unev() { _add "$1" unevaluable "$2"; BLOCKERS=$((BLOCKERS+1)); }

pf() { jq -r "$1 // empty" "$PF" 2>/dev/null; }

MR=$(pf '.mr'); PROJECT=$(pf '.project'); REMOTE=$(pf '.remote')
TARGET_ABS=$(pf '.target_abs'); MR_AUTHOR=$(pf '.mr_author')
EXPECTED_QA_USER=$(pf '.expected_qa_user')
QA_TOKEN_OK=$(pf '.qa_token_ok'); APPROVAL_ELIGIBLE=$(pf '.approval_eligible')
SCHEMA_DETECTED=$(pf '.schema.detected')
QA_TOKEN_ENV=$(pf '.qa_token_env'); QA_TOKEN_FILE=$(pf '.qa_token_file')

# --- the caller's own inputs, validated rather than assumed -----------------
# A missing --round-blocking is unevaluable, never "assume clean". The verdict
# knows this value; a caller that omits it has not read the verdict.
case "$ROUND_BLOCKING" in
  false) _pass round-clean "no confirmed critical or major findings this round" ;;
  true)
    if [ "$DEFERRED_EXIT" = "true" ] && [ -n "$DEFERRED_URL" ]; then
      _pass round-clean "round has blocking findings, but the deferred-findings exit applies and the enumerating note is at $DEFERRED_URL"
    elif [ "$DEFERRED_EXIT" = "true" ]; then
      _fail round-clean "deferred-findings exit claimed without --deferred-note-url; the exit rests on that posted note, not on the absence of findings"
    else
      _fail round-clean "round has confirmed critical or major findings"
    fi ;;
  *) _unev round-clean "--round-blocking not supplied or not a boolean (got '${ROUND_BLOCKING}')" ;;
esac

# --- token ------------------------------------------------------------------
if [ "$QA_TOKEN_OK" = "true" ]; then
  _pass qa-token "preflight resolved and verified the QA agent token"
else
  _fail qa-token "qa_token_ok is not true; approving without it acts as the developer identity"
fi

# Resolve the token the way preflight documents: env FIRST, then file. Given only
# the file, an env-only token resolves empty -- and an empty token is exactly the
# self-approval fallback. We need it here to PROBE, not to approve.
QA_TOKEN=""
if [ -n "$QA_TOKEN_ENV" ]; then
  eval "QA_TOKEN=\${$QA_TOKEN_ENV:-}"
fi
if [ -z "$QA_TOKEN" ] && [ -n "$QA_TOKEN_FILE" ]; then
  _tf="${QA_TOKEN_FILE/#\~/$HOME}"
  [ -f "$_tf" ] && QA_TOKEN=$(tr -d '[:space:]' < "$_tf" 2>/dev/null)
fi

# --- approval eligibility ---------------------------------------------------
case "$APPROVAL_ELIGIBLE" in
  true)  _pass approval-eligible "preflight computed the round as approval-eligible" ;;
  false) _fail approval-eligible "preflight computed this round as not yet approval-eligible (min_clean_round)" ;;
  *)     _unev approval-eligible "approval_eligible missing from preflight.json" ;;
esac

# --- schema gate ------------------------------------------------------------
# Non-schema MRs need NO human approval: QA-agent-alone after a clean round is the
# sanctioned path. Schema MRs need both the checklist ack and a human approval
# that is neither the author nor the QA agent.
if [ "$SCHEMA_DETECTED" != "true" ]; then
  _pass schema-gate "no schema change detected; QA-agent-alone approval is the sanctioned path"
elif [ "$SCHEMA_ACK" != "true" ]; then
  _fail schema-gate "schema change detected and --schema-ack is not true; the rollout/base-file checklist is unacknowledged"
else
  _pass schema-gate "schema change detected and the rollout checklist is acknowledged (human approval checked separately below)"
fi

# ---------------------------------------------------------------------------
# Live forge probes. Everything below needs the seam; if it will not load, every
# remaining check is unevaluable and the gate refuses. That is the correct
# outcome: "I could not ask" is not "the answer was yes".
# ---------------------------------------------------------------------------
FORGE_OK=false
if [ -n "$TARGET_ABS" ] && [ -d "$TARGET_ABS" ] && [ -f "$HERE/forge.sh" ]; then
  # shellcheck disable=SC1090
  . "$HERE/forge.sh" 2>/dev/null || true
  _url=$(git -C "$TARGET_ABS" remote get-url "${REMOTE:-origin}" 2>/dev/null)
  if [ -n "$_url" ] && command -v forge_init >/dev/null 2>&1 \
     && forge_init "$_url" "$HERE" 2>/dev/null; then
    FORGE_OK=true
  fi
fi

CI_STATE=unknown; CI_SHA=""; HEAD_SHA=""; CI_MATCH=false
HUMAN_APPROVERS=""
if [ "$FORGE_OK" != "true" ]; then
  _unev ci "could not load the forge seam or resolve the remote; CI state is unknown"
  [ "$SCHEMA_DETECTED" = "true" ] && _unev schema-human-approval "could not probe approvers"
else
  # CI must be probed LIVE at approval time. preflight's pipeline_status describes
  # the head as it was BEFORE this round's fix commit existed, so consuming it
  # here certifies a commit no CI ever saw -- observed once, on a round approved
  # while the pipeline for its own fix commit was still running.
  if _ci=$(forge_head_ci "$PROJECT" "$MR" "$QA_TOKEN" 2>/dev/null); then
    read -r CI_STATE CI_SHA <<EOF
$_ci
EOF
  else
    CI_STATE=unknown; CI_SHA=""
  fi
  HEAD_SHA=$(git -C "$TARGET_ABS" rev-parse HEAD 2>/dev/null)
  [ -n "$CI_SHA" ] && [ "$CI_SHA" = "$HEAD_SHA" ] && CI_MATCH=true

  case "$CI_STATE" in
    success)
      if [ "$CI_MATCH" = "true" ]; then
        _pass ci "CI succeeded on ${CI_SHA}, which is HEAD"
      else
        # Worse than no answer: CI ran, and it ran on different code.
        _fail ci "CI succeeded on ${CI_SHA:-<none>} but HEAD is ${HEAD_SHA:-<unknown>} — CI ran on different code"
      fi ;;
    running)      _fail ci "CI is still running; wait and re-probe. Never approve pending CI" ;;
    failed)       _fail ci "CI failed on ${CI_SHA:-HEAD}; this round put that commit there" ;;
    did-not-run)  _fail ci "the pipeline was cancelled, timed out, or never got a runner — there is no verdict to act on. Ask for a re-run rather than a fix" ;;
    none)         _fail ci "no CI exists for this MR. That is a finding about the project, never a pass" ;;
    *)            _unev ci "CI probe returned '${CI_STATE:-<empty>}'" ;;
  esac

  # Human approval, required ONLY for a schema change, and it must be a human who
  # is neither the MR author nor the QA agent -- otherwise "a human approved" is
  # satisfied by the two identities the gate exists to exclude.
  if [ "$SCHEMA_DETECTED" = "true" ]; then
    if _appr=$(forge_approvers "$PROJECT" "$MR" "$QA_TOKEN" 2>/dev/null); then
      HUMAN_APPROVERS=$(printf '%s\n' "$_appr" | awk 'NF' \
        | grep -v -x -F "${MR_AUTHOR:-__none__}" \
        | grep -v -x -F "${EXPECTED_QA_USER:-__none__}" || true)
      if [ -n "$HUMAN_APPROVERS" ]; then
        _pass schema-human-approval "approved by $(printf '%s' "$HUMAN_APPROVERS" | tr '\n' ' ')"
      else
        _fail schema-human-approval "no approver other than the MR author and the QA agent"
      fi
    else
      _unev schema-human-approval "could not read approvers from the forge"
    fi
  fi
fi

DECISION=refuse
[ "$BLOCKERS" -eq 0 ] && DECISION=approve

printf '%s\n' "$REASONS" | jq -s \
  --arg decision "$DECISION" \
  --arg ci_state "$CI_STATE" --arg ci_sha "$CI_SHA" --arg head_sha "$HEAD_SHA" \
  --argjson ci_match "$CI_MATCH" \
  --arg expected_qa_user "$EXPECTED_QA_USER" --arg mr_author "$MR_AUTHOR" \
  --argjson blockers "$BLOCKERS" \
  '{ decision: $decision,
     blockers: $blockers,
     ci: { state: $ci_state, sha: $ci_sha, head_sha: $head_sha, matches_head: $ci_match },
     identities: { expected_qa_user: $expected_qa_user, mr_author: $mr_author },
     reasons: . }'

[ "$DECISION" = "approve" ] && exit 0
exit 1
