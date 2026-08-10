#!/usr/bin/env bash
# forge-github.sh — GitHub backend for the forge seam. See lib/forge.sh for the
# contract. The normalized shape is GitLab's, so the whole GitLab<->GitHub
# mapping lives in this file and nowhere else.
#
# Sourced by forge_init; never run directly.

forge_cli() { echo gh; }

# Token as an env-var PREFIX, never `gh auth login` — that mutates the user's
# own config, and a prefix is the only form that stays correct when the dev and
# QA identities are both used in one script. GH_TOKEN wins over the stored
# credential, which is exactly the override wanted.
_gh() {
  local token="$1"; shift
  if [ -n "$token" ]; then GH_TOKEN="$token" gh "$@"
  else gh "$@"; fi
}

# forge_auth_user [token] -> username
#
# `gh api user` rather than `gh auth status`: status prints the account the CLI
# is *configured* with, which is not necessarily the identity a supplied token
# resolves to. Asking the API is the only form that verifies the token itself —
# and verification is the point, since a stored-but-wrong QA token that looks
# configured is worse than no token at all.
forge_auth_user() {
  local out
  out=$(_gh "${1:-}" api user --jq '.login' 2>/dev/null | head -1)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# GitHub addresses a repo as owner/repo in the path — no encoding needed. The
# function exists so callers never branch on the forge.
forge_project_enc() { printf '%s' "$1"; }

# forge_view_mr <dir> <n> -> normalized JSON (GitLab's shape)
#
# The mapping, field by field:
#   author.login       -> author.username
#   headRefName        -> source_branch      baseRefName -> target_branch
#   OPEN/MERGED/CLOSED -> opened/merged/closed
#   isDraft            -> draft
#   changedFiles (int) -> changes_count (STRING — GitLab reports it as one, and
#                         downstream reads it with `--arg`, so emitting a number
#                         here would make the JSON shape forge-dependent)
#   statusCheckRollup  -> head_pipeline.status
#   body               -> description
#
# statusCheckRollup is an ARRAY of per-check results, not a single verdict —
# GitHub has no pipeline-level status. Collapsing it has to be conservative:
# any failure -> "failed", else anything unfinished -> "running", else
# "success", and an empty array means no checks are configured, which is
# "unknown" and NOT success. Reporting "success" for a PR that ran no checks
# would let the security-scan delta certify a scan that never happened.
# KNOWN DEFECT — ROADMAP.md D9, CASE-STUDIES.md §wrong-repo. Open as of 2026-08-10.
#
# This is the ONLY forge_* function that does not take the resolved `owner/repo`
# slug. Without `--repo`, `gh` falls back to its own remote resolution, which in a
# FORK checkout prefers the PARENT repository — so a round started against PR #1 of
# a fork fetches, describes, and reviews upstream's PR #1 instead. Observed live:
# preflight resolved `halindrome/jcode` correctly and then emitted a different,
# closed PR by another author, with every field internally consistent. Only a
# failed branch checkout stopped the panel from reviewing the wrong diff.
#
# Fix: take the slug as $1 like every sibling and pass `--repo "$slug"` (and/or
# export GH_REPO="$FORGE_PROJECT" in preflight after Step 0.3). Until then, callers
# in a fork checkout must set GH_REPO themselves.
forge_view_mr() {
  local dir="$1" n="$2" raw
  raw=$(cd "$dir" && gh pr view "$n" \
    --json title,author,headRefName,baseRefName,state,isDraft,changedFiles,statusCheckRollup,body \
    2>/dev/null) || return 1
  printf '%s' "$raw" | jq '
    def rollup:
      ( [ .statusCheckRollup[]? | (.conclusion // .state // "") | ascii_upcase ] ) as $s
      | if   ($s | length) == 0                                           then "unknown"
        elif ($s | any(. == "FAILURE" or . == "TIMED_OUT" or . == "CANCELLED" or
                       . == "ACTION_REQUIRED" or . == "STARTUP_FAILURE"))  then "failed"
        elif ($s | any(. == "PENDING" or . == "IN_PROGRESS" or . == "QUEUED" or
                       . == "WAITING" or . == "REQUESTED" or . == ""))     then "running"
        else "success" end;
    {
      title:          (.title // ""),
      author:         { username: (.author.login // "") },
      source_branch:  (.headRefName // ""),
      target_branch:  (.baseRefName // ""),
      state:          ((.state // "") | ascii_downcase
                       | if . == "open" then "opened" else . end),
      draft:          (.isDraft // false),
      changes_count:  ((.changedFiles // "") | tostring),
      head_pipeline:  { status: rollup },
      description:    (.body // "")
    }' 2>/dev/null || return 1
}

# forge_approvers <slug> <n> [token] -> usernames, one per line
#
# GitHub keeps the FULL review history, so a reviewer who approved and then
# requested changes still has an APPROVED row. Reduce to each reviewer's LATEST
# state before filtering, otherwise a withdrawn approval still reads as one —
# and this value gates whether the QA agent has already approved.
#
# `jq -s` FLATTEN, not a bare filter: under `--paginate` gh emits one JSON array
# PER PAGE, not one combined array (`--slurp` would combine them but needs
# gh >= 2.53, and a silent floor on the CLI version is not worth the tidier
# pipeline). Without the slurp, jq sees only the first page — so on a PR with
# more than a page of reviews the QA agent's own approval could go unseen.
forge_approvers() {
  local slug="$1" n="$2" token="${3:-}" raw
  raw=$(_gh "$token" api --paginate "repos/${slug}/pulls/${n}/reviews" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -s -r '
    [ .[] | .[]? ]
    | [ .[] | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED") ]
    | group_by(.user.login)
    | map(sort_by(.submitted_at) | last)
    | .[] | select(.state == "APPROVED") | .user.login' 2>/dev/null | sort -u
}

# forge_head_ci <slug> <n> [token] -> "<state> <sha>"
#
# state is one of: success | failed | running | none | unknown
# Contract and rationale: see the twin in forge-gitlab.sh. Probe LIVE at approval
# time — preflight's pipeline_status describes the head BEFORE this round's fix
# commit and would certify a commit no CI ever saw.
#
# GitHub has no single "blocking outcome" field, so it is derived. The order is
# load-bearing: a check that never produced a verdict outranks a real failure,
# a real failure outranks anything still in flight, and in-flight outranks
# success — so a rollup that is half-green never reports `success`.
#
# `did-not-run` is its OWN state, not a failure. cancelled / timed_out / stale /
# action_required mean the check reached a terminal state without judging the
# code; calling that `failed` tells the operator "fix it" about a job that never
# ran, which sends them looking for a defect that does not exist. It ranks
# FIRST because it is the least actionable-by-fixing and the most likely to be
# mistaken for a verdict — the same reasoning that gives the SAST helpers a
# `skipped:runner-unavailable` state instead of letting an unrun scan read clean.
#
# NEUTRAL and SKIPPED are neither: they are how a conditional workflow reports
# "did not apply", and treating them as red would block approval on every
# path-filtered job. Unlike GitLab there is no allow_failure equivalent in the
# rollup, so an advisory check reporting FAILURE will hold approval; that is the
# safe direction, and the operator can act on it.
forge_head_ci() {
  local slug="$1" n="$2" token="${3:-}" raw sha rollup
  raw=$(_gh "$token" api "repos/${slug}/pulls/${n}" 2>/dev/null) || return 1
  sha=$(printf '%s' "$raw" | jq -r '.head.sha // ""' 2>/dev/null) || return 1
  [ -n "$sha" ] || return 1
  rollup=$(_gh "$token" api "repos/${slug}/commits/${sha}/check-runs?per_page=100" 2>/dev/null) || return 1
  printf '%s %s\n' "$(printf '%s' "$rollup" | jq -r '
    [ .check_runs[]? | { s: (.status // ""), c: (.conclusion // "") } ] as $r
    | if   ($r | length) == 0                                              then "none"
      elif ($r | map(select(.c=="cancelled" or .c=="timed_out"
                         or .c=="stale"     or .c=="action_required"))
               | length) > 0                                              then "did-not-run"
      elif ($r | map(select(.c=="failure")) | length) > 0                 then "failed"
      elif ($r | map(select(.s!="completed")) | length) > 0               then "running"
      elif ($r | map(select(.c=="success" or .c=="neutral" or .c=="skipped"))
               | length) == ($r | length)                                 then "success"
      else "unknown" end' 2>/dev/null || echo unknown)" "$sha"
}

# forge_notes <slug> <n> [token] -> JSON array of {body: "..."}
#
# ISSUE comments, not PULL comments: a PR's conversation-tab comments live on
# the issues endpoint. `/pulls/{n}/comments` returns line-anchored review
# comments instead, which is a different thing and would miss every round note
# this plugin posts — silently resetting the round counter to 1.
forge_notes() {
  local slug="$1" n="$2" token="${3:-}" raw
  raw=$(_gh "$token" api --paginate "repos/${slug}/issues/${n}/comments?per_page=100" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -s '[ .[] | .[]? | { body: (.body // "") } ]' 2>/dev/null || return 1
}

# stdout is NOT swallowed: `gh pr comment` prints the new comment's URL there,
# and the deferred-findings approval path must link that note.
forge_post_note() { _gh "${4:-}" pr comment "$2" -R "$1" --body-file "$3"; }
# Empty token REFUSED here but tolerated by forge_post_note — see
# _forge_require_token in forge.sh for why the asymmetry is deliberate.
forge_approve()   { _forge_require_token forge_approve "${3:-}" || return 3
                    _gh "$3" pr review  "$2" -R "$1" --approve >/dev/null; }

# GitHub has no "unapprove" — an approval is withdrawn by DISMISSING the review,
# which needs the review id and a message. Find this identity's latest approval
# and dismiss that one; if there is none, there is nothing to withdraw and that
# is a success, not an error.
forge_unapprove() {
  _forge_require_token forge_unapprove "${3:-}" || return 3
  local slug="$1" n="$2" token="${3:-}" me id
  me=$(forge_auth_user "$token") || return 1
  id=$(_gh "$token" api --paginate "repos/${slug}/pulls/${n}/reviews" 2>/dev/null \
    | jq -s -r --arg me "$me" '
        [ .[] | .[]? | select(.user.login == $me and .state == "APPROVED") ]
        | sort_by(.submitted_at) | last | .id // empty') || return 1
  [ -n "$id" ] || return 0
  _gh "$token" api --method PUT "repos/${slug}/pulls/${n}/reviews/${id}/dismissals" \
    --field message="Approval withdrawn: new blocking findings in a later QA round." \
    --field event=DISMISS >/dev/null
}
