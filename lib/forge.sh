#!/usr/bin/env bash
# forge.sh — the seam between this plugin and the code-review forge it talks to.
#
# Source this, call `forge_init <remote-url>`, then use the `forge_*` functions
# below. Exactly one backend (lib/forge-gitlab.sh or lib/forge-github.sh) is
# sourced by forge_init, chosen from the remote URL.
#
# "MR" throughout means "the change under review" — a GitLab merge request or a
# GitHub pull request. The vocabulary is GitLab's because that is where this
# implementation has the mileage; nothing about the seam is GitLab-specific.
#
# THE NORMALIZED SHAPE IS GITLAB'S. `forge_view_mr` must emit an object with
# these keys regardless of backend:
#
#   .title  .author.username  .source_branch  .target_branch
#   .state ("opened"|"merged"|"closed")  .draft (bool)
#   .changes_count (string)  .head_pipeline.status  .description
#
# That makes forge-gitlab.sh a near-passthrough and puts the whole mapping cost
# in forge-github.sh, which is the right place for it: GitLab is the shape the
# rest of this codebase was written against and re-normalizing both sides would
# be churn with no second consumer to justify it.
#
# EVERY FUNCTION REPORTS FAILURE. A backend call that cannot reach the forge
# returns non-zero and prints nothing to stdout. Callers must not treat empty
# output as "nothing found" — that conflation is the failure mode this whole
# codebase is built to avoid (an absent check must never report as a pass).
#
# CONTRACT — each backend defines:
#
#   forge_cli                                -> required CLI binary name
#   forge_auth_user            [token]       -> username of that identity
#   forge_project_enc          <slug>        -> the slug in API-path form
#   forge_view_mr              <dir> <n>     -> normalized JSON (see above)
#   forge_approvers            <enc> <n> [token] -> usernames, one per line
#   forge_notes                <enc> <n> [token] -> JSON array of {body: "..."}
#   forge_post_note            <enc> <n> <body-file> [token]
#   forge_approve              <enc> <n> [token]
#   forge_unapprove            <enc> <n> [token]
#
# forge_project_slug and forge_detect are shared and live here.

# --------------------------------------------------------------------------
# forge_detect <remote-url> -> gitlab | github | unknown
#
# Host matching is a HEURISTIC and it fails on exactly the deployments that most
# need this to work: a self-hosted GitLab at git.example.com and a GitHub
# Enterprise instance both contain neither string. So an explicit answer always
# wins over sniffing —
#
#   $QA_FORGE (env)  >  the `forge` config key  >  the remote URL
#
# — set by the caller into QA_FORGE before calling. The env var is also the seam
# the test suite uses, since a fixture's remote is a local path with no host at
# all; that it doubles as the production escape hatch is the point, not a
# coincidence. A test-only seam nobody runs in anger is a seam that rots.
#
# Same host matching as lib/init.sh's detect_forge, deliberately: two detectors
# that can disagree is a bug waiting for a self-hosted instance to trigger it.
# --------------------------------------------------------------------------
forge_detect() {
  case "${QA_FORGE:-}" in
    gitlab|github) echo "$QA_FORGE"; return ;;
    "") ;;
    *) echo unknown; return ;;   # set but not a forge we have: say so, do not fall back
  esac
  case "$1" in
    *gitlab*) echo gitlab ;;
    *github*) echo github ;;
    *)        echo unknown ;;
  esac
}

# --------------------------------------------------------------------------
# forge_project_slug <remote-url> -> <group>[/<subgroup>...]/<project>
#
# Shared: the URL shapes (https, ssh, scp-style, SSH alias) are git's, not the
# forge's. Strip the parts rather than trying to capture the whole shape at
# once — a one-shot `s,^.*[/:]([^/]+/[^/]+)\.git$,\1,` had two defects: it
# required a literal `.git` suffix (a non-matching URL passed through UNCHANGED,
# so the full URL silently became the "project" and every later API call 404'd),
# and its fixed two-segment capture truncated nested subgroups (a/b/c -> b/c).
#
# Returns non-zero if the result is not a `<owner>/<repo>` path.
# --------------------------------------------------------------------------
forge_project_slug() {
  local url="$1" slug
  slug="${url%.git}"            # optional .git suffix
  slug="${slug%/}"              # optional trailing slash
  slug=$(printf '%s' "$slug" | sed -E '
    s,^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/,,;   # scheme://host/       -> ""
    s,^[^/]*:,,;                             # user@host: | sshalias: -> ""
  ')
  slug="${slug#/}"              # leading slash from ssh://host/…
  [ -n "$slug" ] && printf '%s' "$slug" | grep -q '/' || return 1
  printf '%s' "$slug"
}

# --------------------------------------------------------------------------
# forge_init <remote-url> [lib-dir]
#
# Detects the forge and sources its backend. Returns non-zero (printing nothing)
# on an unrecognised host, so the caller decides how to fail — preflight turns
# it into a usage error naming the URL, which is more useful than a generic one
# raised from in here.
#
# Sets FORGE (gitlab|github) for callers that need to branch on it.
# --------------------------------------------------------------------------
forge_init() {
  local url="$1"
  local dir="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  FORGE="$(forge_detect "$url")"
  case "$FORGE" in
    gitlab|github) ;;
    *) return 1 ;;
  esac
  # shellcheck source=/dev/null
  . "$dir/forge-${FORGE}.sh" || return 1
}
