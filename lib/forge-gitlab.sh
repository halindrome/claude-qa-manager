#!/usr/bin/env bash
# forge-gitlab.sh — GitLab backend for the forge seam. See lib/forge.sh for the
# contract and for why the normalized shape is GitLab's (this file is therefore
# almost a passthrough; forge-github.sh carries the mapping cost).
#
# Sourced by forge_init; never run directly.

forge_cli() { echo glab; }

# Every call that needs the QA identity takes the token as its last argument and
# passes it as an env-var PREFIX rather than switching a global auth state.
# `glab auth login` mutates the user's own config; a QA round must never do
# that, and a prefix is also the only form that stays correct when the dev and
# QA identities are used in the same script.
_glab() {
  local token="$1"; shift
  if [ -n "$token" ]; then GITLAB_TOKEN="$token" glab "$@"
  else glab "$@"; fi
}

# forge_auth_user [token] -> username
#
# `glab auth status` writes its human-readable report to stderr, hence 2>&1.
# Empty output + non-zero return when the identity cannot be resolved: a caller
# that compares this against an expected username must be able to tell "not that
# user" from "could not ask".
forge_auth_user() {
  local token="${1:-}" out
  out=$(_glab "$token" auth status 2>&1 \
    | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1)
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# GitLab's API addresses a project by its URL-encoded full path. Every forge_*
# function below takes the PLAIN slug and encodes here as needed — one encoding
# site, so a caller cannot pass the wrong form. This is still exported because
# preflight emits it for the skill's own `glab api` calls.
forge_project_enc() { printf '%s' "$1" | sed 's,/,%2F,g'; }

# forge_view_mr <dir> <n> -> normalized JSON
#
# glab already emits the normalized shape, so this only re-emits the keys the
# contract names. Selecting them explicitly (rather than passing the payload
# through) is what keeps the two backends honest: a key that GitLab supplies for
# free and GitHub does not would otherwise be consumed downstream and only fail
# on the GitHub path, which is the harder bug to find.
forge_view_mr() {
  local dir="$1" n="$2" raw
  raw=$(cd "$dir" && glab mr view "$n" --output json 2>/dev/null) || return 1
  printf '%s' "$raw" | jq '{
    title:          (.title // ""),
    author:         { username: (.author.username // "") },
    source_branch:  (.source_branch // ""),
    target_branch:  (.target_branch // ""),
    state:          (.state // ""),
    draft:          (.draft // false),
    changes_count:  (.changes_count // ""),
    head_pipeline:  { status: (.head_pipeline.status // "unknown") },
    description:    (.description // "")
  }' 2>/dev/null || return 1
}

# forge_view_issue <dir> <n> -> {number, title, state, description, url}
# Fails (non-zero, no stdout) unless the result names the issue: an empty object is
# a lookup that did not happen, not an issue with no title.
forge_view_issue() {
  local dir="$1" n="$2" raw
  raw=$(cd "$dir" && glab issue view "$n" --output json 2>/dev/null) || return 1
  printf '%s' "$raw" | jq -e 'select((.iid // null) != null and (.title // "") != "")
    | { number: (.iid | tostring), title, state: (.state // ""),
        description: (.description // ""), url: (.web_url // "") }' 2>/dev/null || return 1
}

# forge_approvers <slug> <n> [token] -> usernames, one per line
#
# /approvals FIRST, /approval_state as a fallback. /approval_state has been
# observed to LAG — returning an empty approved_by for seconds after a human
# approves — and this value gates the schema-change rule that requires a human
# approval. A lagging read there reports "no human has approved" on an MR a
# human just approved, so the more reliable endpoint has to be the primary one.
#
# Both payload shapes are read from each: GitLab carries approvals per-rule or
# at the top level depending on the project's approval configuration, and a
# reader that knows only one shape reports "not approved" on an approved MR.
#
# Failure is only failure when BOTH endpoints fail — otherwise a project with
# approval rules disabled (404 on /approval_state) would look like an outage.
forge_approvers() {
  local enc; enc=$(forge_project_enc "$1")
  local n="$2" token="${3:-}" raw="" rc=1 ep out=""
  # Accumulate into a variable rather than piping the loop: `for … done | sort`
  # runs the loop body in a SUBSHELL, so rc would never escape it and the
  # function would report failure on every call, including successful ones.
  for ep in approvals approval_state; do
    if raw=$(_glab "$token" api "projects/${enc}/merge_requests/${n}/${ep}" 2>/dev/null); then
      rc=0
      out="${out}$(printf '%s' "$raw" | jq -r '
        [ (.rules[]?.approved_by[]?.username // empty),
          (.approved_by[]?.user.username // empty),
          (.approved_by[]?.username // empty) ] | .[]' 2>/dev/null)
"
    fi
  done
  [ "$rc" -eq 0 ] || return 1
  printf '%s' "$out" | awk 'NF' | sort -u
}

# forge_head_ci <slug> <n> [token] -> "<state> <sha>"
#
# state is one of: success | failed | running | none | unknown
#
# WHY THIS EXISTS. Step 3E approved an MR while the pipeline for the very commit
# being approved was still running; the approval rested on a local suite run.
# That is not hypothetical — an earlier cycle in the same repo had CI go red on a
# QA fix commit because the local run covered 5 of N suites.
#
# The probe is LIVE and belongs at approval time, NOT in preflight.
# `preflight.json .pipeline_status` describes the head as it was BEFORE this
# round's fix commit existed, so consuming it here would gate on a pipeline for
# different code and report a pass for a commit no CI ever saw. The sha is
# returned so the caller can assert it matches the commit it is approving.
#
# `head_pipeline.status` is already the BLOCKING outcome: GitLab reports success
# when only `allow_failure: true` jobs fail. That matters here — this project's
# four security jobs are all allow_failure, and gating on raw job results would
# block approval on advisory scans, contradicting the deliberate decision that
# `skipped:pipeline-running` is an acceptable SAST state.
#
# `canceled` maps to `did-not-run`, not `failed`: it carries no verdict, and
# telling the operator to "fix it" sends them after a defect that does not exist.
# Same distinction the SAST helpers draw with `skipped:runner-unavailable`.
# A project with no CI at all yields `none`, which the caller must REPORT rather
# than silently treat as a pass. Neither is approvable.
forge_head_ci() {
  local enc; enc=$(forge_project_enc "$1")
  local n="$2" token="${3:-}" raw st sha
  raw=$(_glab "$token" api "projects/${enc}/merge_requests/${n}" 2>/dev/null) || return 1
  st=$(printf '%s' "$raw"  | jq -r '.head_pipeline.status // "none"' 2>/dev/null) || return 1
  sha=$(printf '%s' "$raw" | jq -r '.head_pipeline.sha // .sha // ""' 2>/dev/null) || return 1
  case "$st" in
    success)                                              st=success ;;
    failed)                                               st=failed  ;;
    created|waiting_for_resource|preparing|pending|running|scheduled|manual) st=running ;;
    canceled|cancelled)                                   st=did-not-run ;;
    none|null|"")                                         st=none    ;;
    *)                                                    st=unknown ;;
  esac
  printf '%s %s\n' "$st" "$sha"
}

# forge_notes <slug> <n> [token] -> JSON array of {body: "..."}
forge_notes() {
  local enc; enc=$(forge_project_enc "$1")
  local n="$2" token="${3:-}" raw
  raw=$(_glab "$token" api "projects/${enc}/merge_requests/${n}/notes?per_page=100" 2>/dev/null) || return 1
  printf '%s' "$raw" | jq '[ .[]? | { body: (.body // "") } ]' 2>/dev/null || return 1
}

# The write paths use glab's own subcommands rather than raw `api` calls: the
# note body is arbitrary markdown and `--message` takes it verbatim, where an
# `api --field` form would need the body shell-escaped into a query parameter.
#
# stdout is NOT swallowed: the CLI prints the new note's URL there, and the
# deferred-findings approval path must link that note in its approval comment.
#
# Empty token REFUSED by approve/unapprove but tolerated by forge_post_note —
# see _forge_require_token in forge.sh for why the asymmetry is deliberate.
forge_post_note() { _glab "${4:-}" mr note "$2" -R "$1" --message "$(_forge_note_body "$3" "${4:-}")"; }
forge_approve()   { _forge_require_token forge_approve   "${3:-}" || return 3
                    _glab "$3" mr approve "$2" -R "$1" >/dev/null; }
forge_unapprove() { _forge_require_token forge_unapprove "${3:-}" || return 3
                    _glab "$3" mr revoke  "$2" -R "$1" >/dev/null; }   # GitLab calls it "revoke"
