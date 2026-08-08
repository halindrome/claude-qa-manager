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
forge_post_note() { _glab "${4:-}" mr note "$2" -R "$1" --message "$(cat "$3")"; }
forge_approve()   { _forge_require_token forge_approve   "${3:-}" || return 3
                    _glab "$3" mr approve "$2" -R "$1" >/dev/null; }
forge_unapprove() { _forge_require_token forge_unapprove "${3:-}" || return 3
                    _glab "$3" mr revoke  "$2" -R "$1" >/dev/null; }   # GitLab calls it "revoke"
