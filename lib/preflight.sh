#!/usr/bin/env bash
# preflight.sh — deterministic pre-QA resolution for /qa-cycle.
#
# Collapses the entire mechanical preamble that the /qa-cycle skill previously
# walked the model through one LLM turn at a time (Step 0 arg/target/base-branch
# resolution, Step 0.25 QA-token verify, Step 0.4 scratch dir, Step 0.7 approval
# seed, Step 2 branch sync, Step 2.5 SAST driver,
# Step 3A.0.1 schema scan) into ONE script that emits a single JSON blob the
# orchestrator reads in one shot.
#
# Usage:  preflight.sh <MR_NUMBER> <TARGET>
# Output: writes $QA_SCRATCH/preflight.json (and echoes it to stdout).
#         side effects: writes $QA_SCRATCH/schema-change.md and
#         $QA_SCRATCH/sast.md (the canonical filenames the skill expects).
#
# Exit codes:
#   0  success — preflight.json emitted, state is clean to proceed. May still
#      carry warnings[] the orchestrator must surface.
#   2  usage / config error THE OPERATOR CAN FIX (bad args, unknown target,
#      missing tooling, unresolvable remote URL).
#   3  SOFT gate — the sync MERGE ITSELF deleted files net-negative ("cut from a
#      stale base"). Measured over PRE_MERGE_HEAD..HEAD, i.e. what the sync did —
#      NOT over base..HEAD, which is the MR's own authored change and would fire
#      on any legitimately deletion-heavy MR. The gate is evaluated BEFORE the
#      push, and trips it: the merge is left LOCAL and unpushed so the operator
#      can still decide. preflight.json IS emitted with
#      warnings=["unexpected_deletions"], sync.reason explaining it, and
#      sync.deleted_files listing the casualties. The orchestrator turns this
#      into an AskUserQuestion confirm rather than a hard abort.
#      KNOWN LIMIT: the predicate cannot tell "the base legitimately deleted
#      these files" from "this branch is stale and the merge reverts my work" —
#      which is exactly why it asks a human instead of aborting.
#   4  HARD stop — the sync could not be performed safely. Covers: fetch / merge /
#      push non-zero, a merge conflict or dirty index, a FAILED CHECKOUT of the
#      source branch, a dirty working tree blocking that checkout, and a
#      PROTECTED source branch. preflight.json is emitted with sync.failed=true
#      (sync.reason carries which) for diagnostics, but NO QA round may run. This
#      is the "throw if the sync fails" contract.
#      KNOWN LIMITATION: an MR sourced FROM a protected branch (the repo's
#      merge-up pattern) is refused, so it gets no automated QA — review it by
#      hand. Refusing is the SAFE failure. Letting the round proceed read-only was
#      tried and produced two holes: Step 3C pushed fix commits straight to the
#      protected branch, and the panel diffed an unrelated (often empty) HEAD and
#      certified an MR it never read. Supporting it properly needs an exported
#      three-dot diff range, consumers that read it instead of hardcoding ..HEAD,
#      and a report-only Step 3C — its own MR, its own QA.
#   5  INTERNAL failure — an invariant in THIS script broke (jq build failed, the
#      emitted JSON failed its own shape assertion). Not the operator's fault and
#      not fixable by re-running: it is a bug here. Distinct from 2 so it cannot
#      hide behind "usage error".
#
# The only things the orchestrator still does as LLM/interactive turns after
# this are: contract resolution (jira_get + synthesis / AskUserQuestion), the
# round-1 skip-contract prompt, any SAST wait-gate prompt, and the review panel.
set -uo pipefail

# exit 2 = the OPERATOR can fix it (bad args, unknown target, missing tool).
# exit 5 = preflight itself failed (an internal invariant broke, or a remote API
# call misbehaved). Conflating the two told the operator to "fix and re-run" when
# nothing they control was wrong, and hid genuine bugs in this script behind a
# usage error.
die_usage()    { echo "preflight: $*" >&2; exit 2; }
die_internal() { echo "preflight: internal: $*" >&2; exit 5; }

MR_NUMBER="${1:-}"
TARGET="${2:-}"
[ -n "$MR_NUMBER" ] || die_usage "missing MR number (usage: preflight.sh <MR> <TARGET>)"
[ -n "$TARGET" ]    || die_usage "missing target (usage: preflight.sh <MR> <TARGET>)"

for t in git jq glab awk; do
  command -v "$t" >/dev/null 2>&1 || die_usage "required tool '$t' not on PATH"
done

# This script ships inside the plugin, NOT inside the repo under review, so its
# own location says nothing about where the work is. Derive the repo root from git.
#
# `--show-toplevel` alone is WRONG here: run from inside a submodule it returns the
# SUBMODULE root, and this tool's whole monorepo mode depends on resolving the
# superproject (target paths like `apps/api` are relative to it). Ask for the
# superproject first and fall back to the toplevel for an ordinary repo. The
# previous implementation dodged this by deriving the root from its own install
# path; that is exactly what made the skill un-installable outside a repo.
PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die_usage "not inside a git repository (cwd: $(pwd))"

# ---------------------------------------------------------------------------
# Config resolution: shipped defaults <- user <- project. Later wins.
# ---------------------------------------------------------------------------
# jq's `*` is a RECURSIVE object merge, so a project can override
# `qa_agent.approval.min_clean_round` without restating the rest of the block.
# Missing layers collapse to `{}` so any combination of the three works.
#
# The merged result is written to one temp file and every downstream jq call
# reads it, which keeps the (many) existing `.targets[$t]…` queries unchanged.
CONFIG_DEFAULTS="$PLUGIN_ROOT/config/defaults.json"
CONFIG_USER="${XDG_CONFIG_HOME:-$HOME/.config}/claude-qa-manager/config.json"
CONFIG_PROJECT="$REPO_ROOT/.claude/skills/qa-cycle/config.json"

[ -f "$CONFIG_DEFAULTS" ] || die_usage "shipped defaults missing at $CONFIG_DEFAULTS (broken install)"

_layer() { [ -f "$1" ] && jq '.' "$1" 2>/dev/null || echo '{}'; }
for _f in "$CONFIG_USER" "$CONFIG_PROJECT"; do
  [ -f "$_f" ] && ! jq empty "$_f" 2>/dev/null && \
    die_usage "config file is not valid JSON: $_f"
done

BB="$(mktemp -t qa-config)" || die_internal "could not create temp config"
trap 'rm -f "$BB"' EXIT
jq -s '.[0] * .[1] * .[2]' \
  <(_layer "$CONFIG_DEFAULTS") <(_layer "$CONFIG_USER") <(_layer "$CONFIG_PROJECT") \
  > "$BB" 2>/dev/null || die_internal "config merge failed"
jq empty "$BB" 2>/dev/null || die_internal "merged config is not valid JSON"

CONFIG_SOURCES="defaults"
[ -f "$CONFIG_USER" ]    && CONFIG_SOURCES="$CONFIG_SOURCES,user"
[ -f "$CONFIG_PROJECT" ] && CONFIG_SOURCES="$CONFIG_SOURCES,project"

# ---------------------------------------------------------------------------
# Step 0 — target registry lookup
# ---------------------------------------------------------------------------
if [ "$(jq -r --arg t "$TARGET" '.targets | has($t)' "$BB")" != "true" ]; then
  die_usage "unknown target '$TARGET' (not in base-branches.json)"
fi
TARGET_PATH=$(jq -r --arg t "$TARGET" '.targets[$t].path'            "$BB")
REMOTE=$(jq -r      --arg t "$TARGET" '.targets[$t].remote // "origin"' "$BB")
SCOPE=$(jq -r       --arg t "$TARGET" '.targets[$t].scope // $t'      "$BB")
BASE_FALLBACK=$(jq -r --arg t "$TARGET" '.targets[$t].base_branch'    "$BB")
SECURITY_STAGE=$(jq -r --arg t "$TARGET" '.targets[$t].security_stage // false' "$BB")
# Per-target lens tags, newline-separated (drives the lenses[] selection below).
#
# VALIDATE, do not silently degrade. `.lens_tags[]?` swallows a type error: a
# scalar (`"lens_tags": "schema"` instead of `["schema"]`) yields empty output —
# indistinguishable from a legitimately absent key — and an unknown tag simply
# never matches has_tag(). Either way the target quietly drops to the core three
# while still emitting a VALID lenses array, so neither the shape assertion nor
# the enum whitelist can catch it. Concretely: one typo in base-branches.json
# silently drops rest-api from 6 lenses to 3 — losing schema-propagation, the
# lens that exists for the code-only-dependency case (CASE-STUDIES #schema-drift). That is a
# fail-OPEN on config, which is the wrong direction for a review harness.
LENS_TAGS_TYPE=$(jq -r --arg t "$TARGET" '.targets[$t].lens_tags | type' "$BB" 2>/dev/null || echo "null")
case "$LENS_TAGS_TYPE" in
  array|null) ;;   # null == key absent == no conditional lenses; legitimate
  *) die_usage "targets.$TARGET.lens_tags must be an array (found: $LENS_TAGS_TYPE). A scalar silently disables every conditional lens for this target." ;;
esac
# An unrecognized tag is an operator typo, not a feature flag — name it rather
# than ignoring it. A WARNING, not fatal, so a newer config carrying a tag this
# preflight predates still runs — but never silently.
#
# KNOWN_LENS_TAGS_RE is the single source of truth for the tag vocabulary;
# preflight.test.sh extracts it from here rather than restating it.
#
# `\A…\z` — NOT `^…$`. jq's Oniguruma engine matches `$` before a trailing
# newline, so `^(schema|api|ui|perf)$` accepts "api\n" as valid: it would pass
# validation unwarned and then split into a usable token downstream.
KNOWN_LENS_TAGS_RE='\A(schema|api|ui|perf)\z'

# SELECTION consumes ONLY validated tags. This is the whole fix, and the earlier
# attempt got it half right: it moved VALIDATION into jq but left SELECTION
# reading the newline-split text, so `["api\nui"]` was declared unknown *and*
# still enabled both api-envelope and ui-styling — preflight holding two
# contradictory positions on one value, with a comment claiming otherwise.
# Filtering here means a malformed element is genuinely INERT (it never reaches
# has_tag) as well as warned. Selection and validation now read the same set, so
# they cannot disagree.
LENS_TAGS=$(jq -r --arg t "$TARGET" --arg re "$KNOWN_LENS_TAGS_RE" \
  '.targets[$t].lens_tags[]? | select(type == "string" and test($re))' "$BB" 2>/dev/null || echo "")
UNKNOWN_LENS_TAGS=$(jq -r --arg t "$TARGET" --arg re "$KNOWN_LENS_TAGS_RE" \
  '[.targets[$t].lens_tags[]? | select(type == "string" and (test($re) | not)) | @json] | join(" ")' "$BB" 2>/dev/null || echo "")
# @json above so a tag carrying a newline/space renders as one quoted token
# ("api\nui") instead of being smeared across two warnings-array elements, the
# second a contextless orphan.
# A non-string element (number/object inside the array) is also a config error.
NONSTRING_LENS_TAGS=$(jq -r --arg t "$TARGET" \
  '[.targets[$t].lens_tags[]? | select(type != "string")] | length' "$BB" 2>/dev/null || echo 0)
if [ "${NONSTRING_LENS_TAGS:-0}" -gt 0 ]; then
  die_usage "targets.$TARGET.lens_tags contains $NONSTRING_LENS_TAGS non-string element(s); tags must be strings."
fi
EXPECTED_QA_USER=$(jq -r '.qa_agent.expected_username // ""' "$BB")
QA_TOKEN_ENV=$(jq -r     '.qa_agent.token_env // "QA_AGENT_TOKEN"'    "$BB")
QA_TOKEN_FILE=$(jq -r    '.qa_agent.token_file // "~/.config/claude-qa-manager/qa-agent-token"' "$BB")
TINY_MAX=$(jq -r '.qa_agent.approval.tiny_mr_max_lines_changed // 50' "$BB")

# Branches this script must never push to. The old prose Step 2 relied on the
# model reading the Notes section; a shell script cannot, so the list is read
# and enforced here.
PROTECTED_BRANCHES=$(jq -r '.protected_branches[]? // empty' "$BB")

# review_mode routing threshold. Deliberately its OWN knob: it previously reused
# qa_agent.approval.tiny_mr_max_lines_changed, which silently coupled an
# APPROVAL-policy decision to a REVIEW-ROUTING decision — raising the tiny-MR
# approval relax ceiling would also stop spawning the lens panel. Falls back to
# the approval knob when unset, so existing configs behave exactly as before.
SEQ_MAX=$(jq -r '.review_mode.sequential_max_lines_changed // empty' "$BB")
[ -n "$SEQ_MAX" ] || SEQ_MAX="$TINY_MAX"

# Absolute target dir (target_path "." == monorepo root)
if [ "$TARGET_PATH" = "." ]; then
  TARGET_ABS="$REPO_ROOT"
else
  TARGET_ABS="$REPO_ROOT/$TARGET_PATH"
fi
[ -d "$TARGET_ABS" ] || die_usage "target path '$TARGET_ABS' does not exist"

# ---------------------------------------------------------------------------
# Step 0 — base-branch resolution (.branchconfig.yaml authoritative, else fallback)
# ---------------------------------------------------------------------------
RESOLVED_BASE=""
RESOLVED_SOURCE=""
CONFIG="$REPO_ROOT/.branchconfig.yaml"
if [ -f "$CONFIG" ]; then
  if [ "$TARGET_PATH" = "." ]; then
    RESOLVED_BASE=$(awk '/^base_branch:/ { sub(/^base_branch:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[" ]/, ""); print; exit }' "$CONFIG")
  else
    RESOLVED_BASE=$(awk -v t="$TARGET_PATH" '
      /^submodule_branches:/ { in_sub = 1; next }
      in_sub && /^[^[:space:]]/ { in_sub = 0; current = "" }
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
  [ -n "$RESOLVED_BASE" ] && RESOLVED_SOURCE=".branchconfig.yaml"
fi
if [ -z "$RESOLVED_BASE" ]; then
  RESOLVED_BASE="$BASE_FALLBACK"
  RESOLVED_SOURCE="base-branches.json fallback"
fi

# ---------------------------------------------------------------------------
# Step 0 — dev identity + MR inspection (dev token)
# ---------------------------------------------------------------------------
DEV_USER=$(glab auth status 2>&1 | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1)

MR_JSON=$(cd "$TARGET_ABS" && glab mr view "$MR_NUMBER" --output json 2>/dev/null) || \
  die_usage "glab mr view $MR_NUMBER failed in $TARGET_ABS"
MR_TITLE=$(printf '%s' "$MR_JSON"      | jq -r '.title // ""')
MR_AUTHOR=$(printf '%s' "$MR_JSON"     | jq -r '.author.username // ""')
SOURCE_BRANCH=$(printf '%s' "$MR_JSON" | jq -r '.source_branch // ""')
TARGET_BRANCH=$(printf '%s' "$MR_JSON" | jq -r '.target_branch // ""')
MR_STATE=$(printf '%s' "$MR_JSON"      | jq -r '.state // ""')
MR_DRAFT=$(printf '%s' "$MR_JSON"      | jq -r '.draft // false')
CHANGES_COUNT=$(printf '%s' "$MR_JSON" | jq -r '.changes_count // ""')
PIPELINE_STATUS=$(printf '%s' "$MR_JSON" | jq -r '.head_pipeline.status // "unknown"')
MR_DESC=$(printf '%s' "$MR_JSON"       | jq -r '.description // ""')

IS_OWN_BRANCH=false
[ -n "$DEV_USER" ] && [ "$DEV_USER" = "$MR_AUTHOR" ] && IS_OWN_BRANCH=true

# ---------------------------------------------------------------------------
# Step 0.4 — GITLAB_PROJECT + scratch dir (resolved BEFORE the hash, matching
# the skill's fix: the hash input must include the project disambiguator)
# ---------------------------------------------------------------------------
# Resolve <group>[/<subgroup>...]/<project> from the remote URL. The previous
# one-shot sed (`s,^.*[/:]([^/]+/[^/]+)\.git$,\1,`) had two defects: it required
# a literal `.git` suffix (a non-matching URL passed through UNCHANGED, so the
# full URL silently became the "project" and every later glab api call 404'd),
# and its fixed two-segment capture truncated nested subgroups (a/b/c -> b/c).
# Strip the parts instead of trying to capture the whole shape at once.
GITLAB_REMOTE_URL=$(cd "$TARGET_ABS" && git remote get-url "$REMOTE" 2>/dev/null)
GITLAB_PROJECT="${GITLAB_REMOTE_URL%.git}"            # optional .git suffix
GITLAB_PROJECT="${GITLAB_PROJECT%/}"                  # optional trailing slash
GITLAB_PROJECT=$(printf '%s' "$GITLAB_PROJECT" | sed -E '
  s,^[a-zA-Z][a-zA-Z0-9+.-]*://[^/]+/,,;   # scheme://host/       -> ""
  s,^[^/]*:,,;                             # user@host: | sshalias: -> ""  (scp-style / SSH alias)
')
GITLAB_PROJECT="${GITLAB_PROJECT#/}"                  # leading slash from ssh://host/…
if [ -z "$GITLAB_PROJECT" ] || ! printf '%s' "$GITLAB_PROJECT" | grep -q '/'; then
  die_usage "could not resolve a <group>/<project> path from remote '$REMOTE' url '$GITLAB_REMOTE_URL'"
fi
GITLAB_PROJECT_ENC=$(printf '%s' "$GITLAB_PROJECT" | sed 's,/,%2F,g')

QA_SCRATCH_INPUT=$(printf '%s|%s|%s' "$TARGET_ABS" "$GITLAB_PROJECT" "$MR_NUMBER")
if command -v shasum >/dev/null 2>&1; then
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | shasum -a 256 | awk '{print $1}' | cut -c1-12)
else
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | sha256sum     | awk '{print $1}' | cut -c1-12)
fi
# Scratch root is a seam, not a hardcoded path: the test suite points
# QA_CYCLE_SCRATCH_ROOT at a throwaway dir so it never writes into the /tmp
# namespace that live QA runs share (and so it cannot delete a live run's scratch
# while cleaning up after itself). Unset -> /tmp, i.e. production is unchanged.
QA_SCRATCH_ROOT="${QA_CYCLE_SCRATCH_ROOT:-/tmp}"
QA_SCRATCH="${QA_SCRATCH_ROOT}/qa-cycle-${QA_SCRATCH_HASH}-${MR_NUMBER}"
# Check the mkdir: under `set -uo pipefail` (no `set -e`) an unchecked failure
# here would let the script sail on and emit JSON to stdout while EVERY
# $QA_SCRATCH/* write and the final tee silently failed — the orchestrator would
# then trip over a missing preflight.json/contract input instead of one clear
# error. An unwritable scratch root is our precondition, so exit 5 (internal).
mkdir -p "$QA_SCRATCH" || die_internal "could not create scratch dir '$QA_SCRATCH' (is QA_CYCLE_SCRATCH_ROOT writable?)"
[ -w "$QA_SCRATCH" ] || die_internal "scratch dir '$QA_SCRATCH' is not writable"

# ---------------------------------------------------------------------------
# Step 0.25 — QA agent token resolve + verify (env-var-prefix form is mandatory)
# ---------------------------------------------------------------------------
QA_TOKEN=""
if [ -n "$QA_TOKEN_ENV" ]; then QA_TOKEN="${!QA_TOKEN_ENV:-}"; fi
if [ -z "$QA_TOKEN" ]; then
  token_path="${QA_TOKEN_FILE/#\~/$HOME}"
  [ -s "$token_path" ] && QA_TOKEN="$(tr -d '[:space:]' < "$token_path")"
fi
QA_TOKEN_OK=false
QA_AUTH_USER=""
if [ -n "$QA_TOKEN" ]; then
  QA_AUTH_USER=$(GITLAB_TOKEN="$QA_TOKEN" glab auth status 2>&1 \
    | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1)
  if [ "$QA_AUTH_USER" = "$EXPECTED_QA_USER" ]; then QA_TOKEN_OK=true; fi
fi
qa_glab() { GITLAB_TOKEN="$QA_TOKEN" glab "$@"; }

# ---------------------------------------------------------------------------
# Step 0.7 — seed MR_APPROVED from GitLab (QA identity; only if token verified)
# ---------------------------------------------------------------------------
MR_APPROVED=false
if [ "$QA_TOKEN_OK" = "true" ]; then
  APPROVED_BY=$(qa_glab api "projects/${GITLAB_PROJECT_ENC}/merge_requests/${MR_NUMBER}/approval_state" 2>/dev/null \
    | jq -r '[ (.rules[]?.approved_by[]?.username // empty), (.approved_by[]?.user.username // empty) ] | .[]' 2>/dev/null | sort -u)
  # -F: the username is a literal, not a regex. Without it a name containing a
  # regex metachar (e.g. a `.`, common in bot usernames) matches usernames it
  # should not — a username differing only at that metachar would count as an approval by the QA agent.
  printf '%s\n' "$APPROVED_BY" | grep -qxF -- "$EXPECTED_QA_USER" && MR_APPROVED=true
fi

# ---------------------------------------------------------------------------
# Step 2 — sync the feature branch with its base. HARD-FAIL on mechanical
# failure (exit 4); SOFT-FLAG unexpected deletions (exit 3).
# ---------------------------------------------------------------------------
SYNC_FAILED=false
SYNC_REASON=""
SYNC_ALREADY_UPTODATE=false
SYNC_PUSHED=false
UNEXPECTED_DELETIONS=false
declare -a WARNINGS=()

# Unknown lens_tags were detected at parse time (long before this array exists).
# Record them HERE — the array is declared above and WARNINGS_JSON is serialized
# further down, so an append after that point silently never reaches the emitted
# JSON. (It did exactly that on the first attempt; the new test caught it.)
# A typo'd tag is otherwise silently inert: the target just never gains the lens.
if [ -n "${UNKNOWN_LENS_TAGS:-}" ]; then
  WARNINGS+=("unknown_lens_tags:${UNKNOWN_LENS_TAGS}")
fi

# The MR's source branch is what we merge INTO and push. Refuse outright if that
# is a protected branch (a merge-up MR sourced FROM a release branch is a
# sanctioned pattern in this repo, so this is reachable, not theoretical). The
# MR's own target branch is off-limits too, regardless of the configured list.
# Exact whole-line, fixed-string match against the newline-separated list.
# Deliberately NOT `for p in $PROTECTED_BRANCHES` — that relies on IFS
# word-splitting, which silently collapses to a single iteration under zsh (this
# repo has been bitten by a zsh-vs-bash split before) and would misread a branch
# name containing whitespace. -F also stops a name like `release/v1.0` from being
# treated as a regex. This function refuses a push, so a false negative is a
# protected-branch write: make it depend on nothing but the string itself.
is_protected() {
  local b="$1"
  [ "$b" = "$TARGET_BRANCH" ] && return 0
  printf '%s\n' "$PROTECTED_BRANCHES" | grep -qxF -- "$b"
}
# A protected source branch is a HARD STOP (exit 4). preflight will neither write
# to it nor review it.
#
# This is a DELIBERATE, DOCUMENTED LIMITATION, not an oversight. An earlier
# attempt let the round proceed read-only so the repo's sanctioned merge-up MRs
# (sourced FROM a release branch) could be QA'd. It flipped this to exit 0 without
# auditing what exit 4 had been suppressing, and two holes opened at once:
#   1. Step 3C's fix commit became reachable — and on this path `<feature-branch>`
#      IS the protected branch, so `git push` wrote straight to it: the exact write
#      this guard exists to prevent.
#   2. Because the checkout is skipped, HEAD stays on an unrelated branch, so the
#      panel diffed `<remote>/<target>..HEAD` — frequently EMPTY — and reported a
#      clean round on an MR it never read. Chained through is_tiny ->
#      tiny_mr_relax_to_range_1 -> approval_eligible, that could auto-approve an
#      unreviewed MR.
# Refusing outright is the safe failure: the operator loses automated QA on
# merge-up MRs (they must review by hand), but nothing is silently mis-certified
# and nothing is written to a protected branch. Making that path genuinely safe
# needs preflight to export a three-dot diff range, every consumer to read it
# instead of hardcoding ..HEAD, and Step 3C to be gated to report-only — a
# self-contained change that deserves its own MR and its own QA.
if is_protected "$SOURCE_BRANCH"; then
  SYNC_FAILED=true
  SYNC_REASON="refusing to sync or review: MR source branch '$SOURCE_BRANCH' is protected (or is the MR's own target branch). preflight never writes to a protected branch, and reviewing one without syncing it would diff an unrelated HEAD. Review this MR by hand. (Known limitation: automated QA does not support MRs sourced from a protected branch.)"
fi

if [ "$SYNC_FAILED" != "true" ]; then
  sync_fetch=$(cd "$TARGET_ABS" && git fetch "$REMOTE" 2>&1) || { SYNC_FAILED=true; SYNC_REASON="git fetch failed: $sync_fetch"; }
fi

if [ "$SYNC_FAILED" != "true" ]; then
  # Ensure we're on the feature branch before merging. Refuse to switch away
  # from a dirty tree: `git checkout` would either fail or silently carry the
  # user's uncommitted work onto the feature branch and into the sync merge.
  cur_branch=$(cd "$TARGET_ABS" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
  if [ "$cur_branch" != "$SOURCE_BRANCH" ]; then
    if (cd "$TARGET_ABS" && git status --porcelain --untracked-files=no 2>/dev/null | grep -q .); then
      SYNC_FAILED=true
      SYNC_REASON="working tree at $TARGET_ABS has uncommitted changes and HEAD is on '$cur_branch', not the MR source branch '$SOURCE_BRANCH'. Commit/stash first, or check out '$SOURCE_BRANCH' by hand."
    else
      co=$(cd "$TARGET_ABS" && git checkout "$SOURCE_BRANCH" 2>&1) || { SYNC_FAILED=true; SYNC_REASON="git checkout $SOURCE_BRANCH failed: $co"; }
    fi
  fi
fi

PRE_MERGE_HEAD=""
if [ "$SYNC_FAILED" != "true" ]; then
  # Record the pre-merge tip so the deletion heuristic below can measure what the
  # SYNC ITSELF did, rather than what the whole MR does.
  PRE_MERGE_HEAD=$(cd "$TARGET_ABS" && git rev-parse HEAD 2>/dev/null)
  merge_out=$(cd "$TARGET_ABS" && git merge "$REMOTE/$TARGET_BRANCH" --no-edit 2>&1)
  merge_rc=$?
  if [ $merge_rc -ne 0 ]; then
    # Abort a conflicted merge so the tree is left clean, then hard-fail.
    (cd "$TARGET_ABS" && git merge --abort >/dev/null 2>&1 || true)
    SYNC_FAILED=true
    SYNC_REASON="git merge $REMOTE/$TARGET_BRANCH failed (conflict?): $merge_out"
  elif printf '%s' "$merge_out" | grep -qi 'Already up to date'; then
    SYNC_ALREADY_UPTODATE=true
  fi
fi

# Guard against a left-dirty index / unmerged paths even on rc 0.
if [ "$SYNC_FAILED" != "true" ]; then
  if (cd "$TARGET_ABS" && git ls-files -u 2>/dev/null | grep -q .); then
    SYNC_FAILED=true
    SYNC_REASON="unmerged paths present after merge"
  fi
fi

# ---------------------------------------------------------------------------
# Unexpected-deletions gate — MUST be evaluated BEFORE the push it gates.
# Previously this ran after the push, so exit 3 ("ask the operator whether this
# destructive-looking sync is intended") was asked about a merge that had ALREADY
# been published to the remote — the gate could not gate anything. Now: measure
# the merge, and if it looks destructive, leave the merge LOCAL and exit 3 so the
# operator decides before anything is pushed.
#
# Scope: PRE_MERGE_HEAD..HEAD — what the SYNC did, not what the MR does (a
# base..HEAD range fires on any legitimately deletion-heavy MR).
# Known limitation (documented, not silently swallowed): the predicate cannot
# distinguish "the base legitimately deleted files" from "this branch was cut
# from a stale base and the merge is reverting my work". Both look like a
# net-negative merge that removes files. It therefore stays a SOFT gate that asks
# a human — never an automatic abort — and it surfaces the deleted-file list so
# the operator can tell the two apart in one glance.
DELETED_FILES=""
if [ "$SYNC_FAILED" != "true" ]; then
  if [ "$SYNC_ALREADY_UPTODATE" = "true" ] || [ -z "$PRE_MERGE_HEAD" ]; then
    DELETED_FILES=""   # the sync changed nothing, so it deleted nothing
  else
    MERGE_RANGE="$PRE_MERGE_HEAD..HEAD"
    DELETED_FILES=$(cd "$TARGET_ABS" && git diff --name-status "$MERGE_RANGE" 2>/dev/null | awk '$1 ~ /^D/ { print $2 }')
    read -r M_INS M_DEL < <(cd "$TARGET_ABS" && git diff --numstat "$MERGE_RANGE" 2>/dev/null \
      | awk '{ if ($1 ~ /^[0-9]+$/) a+=$1; if ($2 ~ /^[0-9]+$/) d+=$2 } END { print a+0, d+0 }')
    if [ -n "$DELETED_FILES" ] && [ "${M_DEL:-0}" -gt "${M_INS:-0}" ]; then
      UNEXPECTED_DELETIONS=true
      WARNINGS+=("unexpected_deletions")
      N_DEL_FILES=$(printf '%s\n' "$DELETED_FILES" | grep -c . || true)
      # Populate SYNC_REASON on this path too — it was previously left empty, so
      # exit 3 surfaced no diagnostic at all.
      SYNC_REASON="sync merge of $REMOTE/$TARGET_BRANCH into '$SOURCE_BRANCH' removed $N_DEL_FILES file(s) and is net -$(( ${M_DEL:-0} - ${M_INS:-0} )) lines. This can mean the branch was cut from a stale base and the merge is reverting your work — or simply that the base legitimately deleted those files. The merge is LOCAL and has NOT been pushed. Inspect sync.deleted_files, then either push by hand or rebuild the branch from the current base."
    fi
  fi
fi

# Push the (possibly new) merge commit to the feature branch. The is_protected
# recheck here is deliberate belt-and-braces: this is the only line in the whole
# script that writes to a remote, so the guard lives at the push site too and
# cannot be bypassed by an edit that reorders the block above.
#
# Push conditions: sync OK, not a protected source, something to push, and the
# deletions gate did NOT trip (see above — a gate evaluated after its own push
# is not a gate).
PUSH_ELIGIBLE=false
if [ "$SYNC_FAILED" != "true" ] && [ "$UNEXPECTED_DELETIONS" != "true" ]; then
  # Push when the merge created a commit OR when the local branch is simply
  # ahead of its remote. The old `already_up_to_date -> skip push` shortcut meant
  # a branch carrying local commits that were never pushed would be QA'd from a
  # HEAD the MR does not contain — certifying code the reviewer on GitLab cannot
  # see.
  if [ "$SYNC_ALREADY_UPTODATE" != "true" ]; then
    PUSH_ELIGIBLE=true
  elif [ -n "$(cd "$TARGET_ABS" && git rev-list "$REMOTE/$SOURCE_BRANCH..HEAD" 2>/dev/null)" ]; then
    PUSH_ELIGIBLE=true
  fi
fi
if [ "$PUSH_ELIGIBLE" = "true" ]; then
  if is_protected "$SOURCE_BRANCH"; then
    SYNC_FAILED=true
    SYNC_REASON="refusing to push to protected branch '$SOURCE_BRANCH'"
  fi
fi
if [ "$PUSH_ELIGIBLE" = "true" ] && [ "$SYNC_FAILED" != "true" ]; then
  push_out=$(cd "$TARGET_ABS" && git push "$REMOTE" "$SOURCE_BRANCH" 2>&1)
  if [ $? -ne 0 ]; then
    SYNC_FAILED=true
    SYNC_REASON="git push $REMOTE $SOURCE_BRANCH failed: $push_out"
  else
    SYNC_PUSHED=true
  fi
fi

# ---------------------------------------------------------------------------
# Diff stat / scope / schema. Compute against the MR's actual target branch.
# HEAD is safe as the source endpoint here ONLY because every path that reaches
# this point has checked out the source branch and merged the target into it — so
# $REMOTE/$TARGET_BRANCH is an ancestor of HEAD and two-dot == three-dot. If a
# future change ever lets an un-synced branch reach this line (e.g. re-enabling
# the protected-source path), that assumption breaks: two-dot would silently pull
# in target-side changes REVERSED, inflating the scope and tripping the schema
# scanner on DDL the MR never wrote. Such a change must switch to the three-dot
# form and export the range for consumers.
# ---------------------------------------------------------------------------
DIFF_RANGE="$REMOTE/$TARGET_BRANCH..HEAD"
INS=0; DEL=0; TOTAL=0; IS_TINY=false
SCHEMA_FILES=""; SCHEMA_DETECTED=false; SCHEMA_STATE="skipped:not-configured"
DIFF_SUMMARY=""; CHANGED_FILES=""

if [ "$SYNC_FAILED" != "true" ]; then
  # Resolve BOTH endpoints before measuring. `git diff --numstat bad..HEAD
  # 2>/dev/null` prints nothing and the awk `END { print a+0, d+0 }` turns that
  # into a confident "0 0" — so an unresolvable range silently becomes
  # TOTAL=0 -> IS_TINY=true -> (with tiny_mr_relax_to_round_1) approval-eligible
  # at round 1 on a review of zero lines. An empty diff and a broken range must
  # never be indistinguishable: fail CLOSED.
  #
  # HONEST NOTE ON COVERAGE: this guard is currently UNREACHABLE, and therefore
  # NOT locked by preflight.test.sh — a mutation that deletes it ships green.
  # That is not laziness; it is unreachable by construction. Every path that gets
  # here has already merged $REMOTE/$TARGET_BRANCH into HEAD, and the merge fails
  # loudly (exit 4) if that ref does not resolve — verified: a nonexistent target
  # branch dies at "git merge origin/<ref> failed", never reaching this line. The
  # fail-open was only ever reachable via the read-only protected-source path,
  # which no longer exists. This stays as a TRIPWIRE: re-enabling any un-synced
  # path (see the exit-4 note in the header) reintroduces the fail-open, and this
  # is what would catch it. If you re-enable such a path, make this guard
  # reachable and add a test that locks it.
  if ! (cd "$TARGET_ABS" && git rev-parse --verify --quiet "$REMOTE/$TARGET_BRANCH^{commit}" >/dev/null); then
    die_internal "diff range endpoint '$REMOTE/$TARGET_BRANCH' does not resolve after a successful fetch — refusing to report a diff scope of 0 that would look like a tiny, approval-eligible MR"
  fi
  if ! (cd "$TARGET_ABS" && git rev-parse --verify --quiet "HEAD^{commit}" >/dev/null); then
    die_internal "HEAD does not resolve — refusing to report a diff scope of 0"
  fi
  CHANGED_FILES=$(cd "$TARGET_ABS" && git diff --name-only "$DIFF_RANGE" 2>/dev/null)
  read -r INS DEL < <(cd "$TARGET_ABS" && git diff --numstat "$DIFF_RANGE" 2>/dev/null \
    | awk '{ if ($1 ~ /^[0-9]+$/) a+=$1; if ($2 ~ /^[0-9]+$/) d+=$2 } END { print a+0, d+0 }')
  TOTAL=$(( INS + DEL ))
  [ "$TOTAL" -le "$TINY_MAX" ] && IS_TINY=true
  # Single-line summary only (raw multi-line --stat would inject control chars
  # into the JSON string); the per-field numbers above are the source of truth.
  N_FILES=$(printf '%s\n' "$CHANGED_FILES" | grep -c . || true)
  DIFF_SUMMARY="${N_FILES} files, +${INS}/-${DEL}"

  # (The unexpected-deletions gate now runs earlier — it must precede the push
  # it gates. See the block above the push.)

  # Schema-change scan — a PATH check against the configured schema file(s).
  #
  # The schema is whatever `schema.files` names: the file(s) a provisioner reads to
  # create a new tenant/instance. If one of them changed, the MR changed the schema;
  # if not, it did not. That is the whole rule.
  #
  # DO NOT reintroduce DDL content scanning. An earlier version also globbed `sql/`
  # and `*.sql` and grepped the diff CONTENT for DDL keywords. It matched DDL in any
  # non-.md file — test fixtures, code comments, even test LABELS — so changes
  # touching zero SQL were reported as schema changes and armed the human-approval
  # gate over a printf string. Defending it took a self-trip guard, a regex
  # extractor and behavioural probes, which produced five review findings of their
  # own and protected nothing. A path check cannot match a comment: the false
  # positive is impossible by construction rather than guarded against.
  # See docs/CASE-STUDIES.md #schema-drift.
  #
  # `(^|/)<path>$` covers both shapes: a monorepo target sees
  # `apps/api/db/template.sql` while the component target sees `db/template.sql`
  # (git diff paths are relative to the target repo root).
  #
  # COVERAGE NOTE: the incident this gate exists for was a CODE-ONLY dependency —
  # code reading a column that never reached the schema file. This detector does not
  # and should not catch that; it is the `schema-propagation` LENS's job, enabled by
  # a target's `schema` lens_tag, independent of this flag.
  #
  # --no-renames is load-bearing. With rename detection ON, a similarity-detected
  # rename prints ONLY the destination, so `git mv template.sql schema.sql` plus an
  # appended ALTER emits just `schema.sql` — the schema file changes, the match
  # misses, and the gate does not arm. With --no-renames git reports the delete and
  # the add separately and the source path matches.
  SCHEMA_CONFIGURED=$(jq -r '[.schema.files[]? | select(type == "string")] | length' "$BB" 2>/dev/null || echo 0)
  if [ "${SCHEMA_CONFIGURED:-0}" -eq 0 ]; then
    # NOT a pass. An unconfigured gate that reports "clean" certifies a check it
    # never ran; downstream must be able to tell the two apart.
    SCHEMA_STATE="skipped:not-configured"
  else
    SCHEMA_STATE="checked"
    # Escape regex metacharacters in each configured path via a NAMED CAPTURE.
    # `gsub("…"; "\\" + .)` looks plausible and is wrong — in a gsub replacement `.`
    # is the capture OBJECT, not the matched text, so it raises a type error. That
    # error would be swallowed by a `|| echo ""` fallback, leaving an empty pattern
    # and a gate that reports "checked" while matching nothing. Hence the explicit
    # emptiness check below rather than a silent fallback.
    _schema_re=$(jq -r '[.schema.files[]? | select(type == "string")
                         | gsub("(?<c>[.^$*+?()\\[\\]{}|\\\\])"; "\\" + .c)]
                        | map("(^|/)" + . + "$") | join("|")' "$BB" 2>/dev/null || true)
    [ -n "$_schema_re" ] || die_internal "schema.files is non-empty ($SCHEMA_CONFIGURED entries) but the path pattern came out empty; refusing to report an unchecked gate as checked"
    SCHEMA_FILES=$(cd "$TARGET_ABS" && git diff --name-only --no-renames "$DIFF_RANGE" 2>/dev/null \
      | grep -E "$_schema_re" || true)
    [ -n "$SCHEMA_FILES" ] && SCHEMA_DETECTED=true
  fi
fi

# schema-change.md evidence (canonical filename)
{
  echo "SCHEMA_CHANGE_DETECTED: $SCHEMA_DETECTED"
  echo "SCHEMA_GATE_STATE: $SCHEMA_STATE"
  echo ""
  _schema_runbook=$(jq -r '.schema.runbook // ""' "$BB" 2>/dev/null || echo "")
  if [ "$SCHEMA_STATE" = "skipped:not-configured" ]; then
    echo "No schema files are configured, so the schema gate DID NOT RUN."
    echo ""
    echo "This is not a clean result — it is an absent one. If this project has a"
    echo "schema file that a provisioner reads to create a new instance, set"
    echo "schema.files in .claude/skills/qa-cycle/config.json so that changes to it"
    echo "require human approval. See docs/CONFIGURING.md."
  elif [ "$SCHEMA_DETECTED" = "true" ]; then
    echo "A configured schema file changed:"; printf '%s\n' "${SCHEMA_FILES:-<none>}"
    echo ""
    echo "This MR changes the schema, so it requires explicit human approval and a"
    echo "template/provisioning refresh before rollout."
    [ -n "$_schema_runbook" ] && echo "See $_schema_runbook."
  else
    echo "No configured schema file changed in $DIFF_RANGE, so this MR does not"
    echo "change the schema."
    echo ""
    echo "Note: this flag tracks the schema FILE only. Code that reads a column or"
    echo "table absent from the schema file is NOT detectable by a path check —"
    echo "that is the schema-propagation lens's job, enabled by a target's schema"
    echo "lens_tag, and it runs regardless of this flag."
    echo ""
    echo "Changed files:"; printf '%s\n' "${CHANGED_FILES:-<none>}"
  fi
} > "$QA_SCRATCH/schema-change.md"

# ---------------------------------------------------------------------------
# docs-only detection (every changed file is docs / CI / meta)
# ---------------------------------------------------------------------------
DOCS_ONLY=false
if [ "$SYNC_FAILED" != "true" ] && [ -n "$CHANGED_FILES" ]; then
  NON_DOC=$(printf '%s\n' "$CHANGED_FILES" | grep -vE '(\.md$|(^|/)\.gitlab-ci\.yml$|(^|/)\.gitignore$|(^|/)devbox\.json$|(^|/)README|(^|/)CLAUDE\.md$)' || true)
  [ -z "$NON_DOC" ] && DOCS_ONLY=true
fi

# ---------------------------------------------------------------------------
# Step 2.5 — SAST driver. Writes $QA_SCRATCH/sast.md. Computes sast_gate_state
# using the CORRECTED marker regex that matches the helper's ACTUAL output
# (the old skill grep 'is still \*\*...\*\*' matched none of the helper's three
# skip-stub phrasings). The two WAITABLE stubs each carry a '**<status>**'
# token; the no-stage stub and the clean report do not.
# ---------------------------------------------------------------------------
SAST_REPORT="$QA_SCRATCH/sast.md"
SAST_GATE_STATE="unknown"
SAST_RUNNING=false
RUNNING_MARKER_RE='\*\*(running|pending|created|preparing|scheduled|waiting_for_resource)\*\*'

if [ "$SECURITY_STAGE" != "true" ]; then
  cat > "$SAST_REPORT" <<EOF
## SAST review not applicable

Target \`$TARGET\` has \`security_stage: false\` in \`base-branches.json\`. No CI
security stage is wired for this target, so no SAST/SCA delta is computed.
EOF
  SAST_GATE_STATE="skipped:no-stage"
elif [ "$SYNC_FAILED" = "true" ]; then
  echo "## SAST review skipped (sync failed; not computed)" > "$SAST_REPORT"
  SAST_GATE_STATE="skipped:helper-failed"
else
  SAST_HELPER_ERR=""
  if SAST_HELPER_ERR=$(bash "$PLUGIN_ROOT/lib/fetch-sast-findings.sh" \
        --project "$GITLAB_PROJECT" --mr "$MR_NUMBER" \
        --target-path "$TARGET_PATH" --output "$SAST_REPORT" 2>&1 >/dev/null); then
    # Classify POSITIVELY off the helper's own headings. Never default to
    # "clean": `clean` asserts a real SAST delta was computed against a finished
    # pipeline, and Step 3E writes that assertion into a permanent GitLab
    # approval comment. The helper exits 0 on FOUR distinct skip paths, so an
    # `else -> clean` fallthrough certifies scans that never ran. Anything we do
    # not positively recognise is `skipped:unknown`, which is never treated as a
    # security review.
    if grep -q '^## SAST review skipped' "$SAST_REPORT"; then
      if grep -q 'No security stage detected' "$SAST_REPORT"; then
        SAST_GATE_STATE="skipped:no-stage"
      elif grep -q 'No pipeline associated with MR' "$SAST_REPORT"; then
        # Reachable on any MR whose pipeline has not been created yet — a normal
        # state moments after preflight's own sync push above.
        SAST_GATE_STATE="skipped:no-pipeline"
        SAST_RUNNING=true
      elif grep -q 'Security scans are still in progress' "$SAST_REPORT" \
           || grep -Eq "$RUNNING_MARKER_RE" "$SAST_REPORT"; then
        # Match the helper's own sentence first, THEN the status marker. The
        # marker alone is unreliable: the helper interpolates the raw overall
        # pipeline status, so unfinished security jobs under a canceled/failed/
        # manual pipeline emit a token outside RUNNING_MARKER_RE's set.
        SAST_RUNNING=true
        SAST_GATE_STATE="skipped:pipeline-running"
      else
        SAST_GATE_STATE="skipped:unknown"
        WARNINGS+=("sast_unrecognized_stub")
      fi
    elif grep -q '^## NEW SAST findings' "$SAST_REPORT"; then
      SAST_GATE_STATE="clean"
    else
      SAST_GATE_STATE="skipped:unknown"
      WARNINGS+=("sast_unrecognized_stub")
    fi
  else
    SAST_GATE_STATE="skipped:helper-failed"
    # SKILL.md declares helper failure a MUST-ask-the-user event. Swallowing it
    # here is what silently downgraded that policy to a no-op, so surface it as
    # a warning the orchestrator has to act on, and keep the reason.
    SAST_HELPER_REASON=$(printf '%s' "$SAST_HELPER_ERR" | head -1)
    WARNINGS+=("sast_helper_failed")
  fi
fi
SAST_HELPER_REASON="${SAST_HELPER_REASON:-}"

# ---------------------------------------------------------------------------
# Contract candidate extraction (mechanical part only; jira_get + synthesis
# stay in the orchestrator). Scan title + description for [A-Z]+-<digits>.
# ---------------------------------------------------------------------------
# Drop common non-JIRA tokens that also match [A-Z]+-<digits> (HTTP-400,
# UTF-8, SHA-256, CVE-2024, RFC-1918, …) so they don't masquerade as tickets.
TICKET_BLOCKLIST='^(HTTP|HTTPS|UTF|SHA|MD|RFC|ISO|CVE|CWE|OSV|IPV|IPv|BASE|SSL|TLS|IEEE|ASCII)-'
TITLE_TICKET=$(printf '%s' "$MR_TITLE" | grep -oE '[A-Z]+-[0-9]+' | grep -viE "$TICKET_BLOCKLIST" | head -1)
CANDIDATES_JSON=$(printf '%s\n%s' "$MR_TITLE" "$MR_DESC" | grep -oE '[A-Z]+-[0-9]+' \
  | grep -viE "$TICKET_BLOCKLIST" | sort -u | jq -R . | jq -s .)
DESC_LEN=${#MR_DESC}

# ---------------------------------------------------------------------------
# Round number -> $ROUND, and the proportionality mandate -> proportionality.md
# ---------------------------------------------------------------------------
# ROUND is derived from the MR's own posted notes (the max "## QA Round N"
# heading, + 1) rather than tracked in the shell, because every /qa-cycle
# invocation is a fresh process: the orchestrator was re-deriving this by hand
# from `glab api .../notes` on each run, which is exactly the mechanical work
# preflight exists to remove. Falls back to 1 when no note is found, which is
# also the correct answer for a first round.
#
# The QA identity is preferred (the notes are posted by it) but NOT required —
# reading notes needs no special privilege, so an unresolved QA token must not
# silently reset the round counter to 1 and re-enable round-1-only behaviour on
# a round-4 review.
# A FAILED probe and "no notes yet" both leave _NOTES_JSON empty, and both then fall
# through to ROUND=1 — but they are not the same event. Silently treating an API
# failure as a first round re-fires the round-1-only prompts on a late round and
# renders the light proportionality tier on a round that had earned the strict one:
# precisely the failure this round-derivation exists to prevent. So capture the exit
# status and warn; ROUND still falls back to 1 (there is nothing better to fall back
# to), but the caller can now see that the number is untrustworthy.
ROUND=1
if [ -n "${GITLAB_PROJECT_ENC:-}" ]; then
  _NOTES_RC=0
  if [ "$QA_TOKEN_OK" = "true" ]; then
    _NOTES_JSON=$(qa_glab api "projects/${GITLAB_PROJECT_ENC}/merge_requests/${MR_NUMBER}/notes?per_page=100" 2>/dev/null) || _NOTES_RC=$?
  else
    _NOTES_JSON=$(glab api "projects/${GITLAB_PROJECT_ENC}/merge_requests/${MR_NUMBER}/notes?per_page=100" 2>/dev/null) || _NOTES_RC=$?
  fi
  if [ "$_NOTES_RC" -ne 0 ]; then
    WARNINGS+=("round_probe_failed:exit=${_NOTES_RC}")
    echo "warn: could not read MR notes (glab exit ${_NOTES_RC}); round falls back to 1 and may be wrong." >&2
  else
    _MAX_ROUND=$(printf '%s' "$_NOTES_JSON" | jq -r '.[]?.body // empty' 2>/dev/null \
      | grep -oE '^## QA Round [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -n "$_MAX_ROUND" ] && ROUND=$((_MAX_ROUND + 1))
  fi
fi

# The lens spawn prompts inject this file verbatim as a titled `## Proportionality`
# section, exactly like tool-mandate.md below — same delivery mechanism, for the
# same measured reason (a titled section is read; a detached preamble is ignored).
#
# WHY THIS EXISTS. The reviewer contract optimizes recall: it is told to assume
# slop and to find every substantive bug. Nothing balanced that, and on a long
# cycle the objective degenerates. Measured on !12 (gitops-ansible, a 40-line
# credential fix): round 1 found 6 findings, all in the role; round 2 added a
# variable that round 3 then removed, net zero across two rounds; round 3's fix
# added a 230-line test play, and round 4 was 11/14 findings ABOUT THAT TEST
# PLAY. By round 4 the panel was reviewing its own output, the diff had grown
# 9x, and the shipped behaviour had been correct since round 2. No individual
# finding was wrong — the aggregate was worthless.
#
# The escalating tier at round >= 3 is the lever: early rounds genuinely find
# real defects (rounds 1-2 above caught a missing BINLOG MONITOR grant), so the
# mandate stays light there and tightens only where the value curve flattens.
PROPORTIONALITY_FILE="$QA_SCRATCH/proportionality.md"
{
  # Stamp the round this file was rendered FOR. The tier is a function of $ROUND at
  # emit time, so a caller that bumps the round without re-running preflight silently
  # injects the wrong tier — the light mandate into a round-3 panel, which no-ops the
  # escalation on the exact transition it exists for. The stamp makes that divergence
  # observable (assert it against .round) instead of a rule nothing enforces.
  echo "_Proportionality mandate — rendered for round $ROUND._"
  echo
  echo "**Weigh every finding against the cost of acting on it.** Some things are"
  echo "not worth doing, and identifying them is as much your job as finding bugs."
  echo
  echo "- Ground findings in behaviour this MR **ships**. A defect an operator or"
  echo "  user will actually hit outranks one that requires someone to first edit"
  echo "  the code in a way nobody has."
  echo "- A finding whose fix costs more than the problem it describes should say so"
  echo "  in the finding itself. Do not leave that inference to the orchestrator."
  echo "- \"This has no test coverage\" is a valuable finding. \"…therefore this MR"
  echo "  must add a test harness\" is not — that is a follow-up ticket. Fixes that"
  echo "  add more new code than the MR contained arrive unreviewed and become the"
  echo "  next round's findings."
  echo "- Test/CI/fixture code caps at \`major\`, and at \`minor\` for a mutation gap"
  echo "  (\"this assertion would still pass if X also changed\"). Infinitely many"
  echo "  such mutations exist for any finite suite, so that class never exhausts."
  echo "  A test asserting something FALSE keeps its true severity; a test merely"
  echo "  not asserting ENOUGH is minor."
  echo "- Saying \"this change is correct\" is a complete and valuable review result."
  echo "  Do not pad a short finding list to look thorough."
  if [ "$ROUND" -ge 3 ]; then
    echo
    echo "**This is round $ROUND — apply the above strictly.**"
    echo
    echo "Rounds 1-$((ROUND - 1)) already ran and their fixes are in this diff. Much of what"
    echo "you are reading is therefore QA-generated code, not the author's original"
    echo "change, and it is the most recently written and least settled part of the"
    echo "diff — which is exactly what makes it magnetic to a reviewer."
    echo
    echo "Before reporting a \`critical\` or \`major\`, check: was the code it targets"
    echo "introduced by an earlier QA round rather than by the MR's own purpose? If"
    echo "most of your blocking findings are about the previous round's fixes rather"
    echo "than about the change the MR exists to make, the cycle has stopped adding"
    echo "value. Say so explicitly in your summary — that judgment is a first-class"
    echo "review result here, not a digression, and the orchestrator acts on it."
  fi
} > "$PROPORTIONALITY_FILE"

# ---------------------------------------------------------------------------
# CMM / Context Mode availability probe -> $QA_SCRATCH/tool-mandate.md
# ---------------------------------------------------------------------------
# The lens spawn prompts (manager + sequential Step 3A) inject tool-mandate.md
# verbatim. When a code-navigation tool is registered, the file carries an
# UNCONDITIONAL "use it" mandate — measured to flip lens adoption from 0 to
# substantial on a real code diff. When NEITHER is present the file is EMPTY, so
# the prompt says nothing about them and the reviewer just uses Read/grep; the
# review is correct either way (correctness never depends on these tools).
# Detection mirrors the project hooks' "grep the known registration sites"
# approach: a best-effort shell probe that is wrong only in the edge case where a
# plugin is on disk but not actually loaded into the running session.
_CC_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code}"
_probe_registered() {  # $1 = name substring; scans Claude Code registration files + plugin cache
  local name="$1" f
  for f in "$REPO_ROOT/.mcp.json" "$_CC_DIR/.mcp.json" "$_CC_DIR/.claude.json" \
           "$_CC_DIR/settings.json" "$HOME/.claude.json" "$HOME/.claude/settings.json"; do
    [ -f "$f" ] && grep -q "$name" "$f" 2>/dev/null && return 0
  done
  [ -d "$_CC_DIR/plugins/cache" ] && \
    find "$_CC_DIR/plugins/cache" -maxdepth 7 -name plugin.json -path '*/.claude-plugin/*' \
      -exec grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" {} \; -print 2>/dev/null | grep -q . \
    && return 0
  return 1
}
CMM_AVAILABLE=false; _probe_registered "codebase-memory-mcp" && CMM_AVAILABLE=true
CTX_AVAILABLE=false; _probe_registered "context-mode"        && CTX_AVAILABLE=true

MANDATE_FILE="$QA_SCRATCH/tool-mandate.md"
: > "$MANDATE_FILE"   # default: empty => spawn prompts inject nothing (silent Read/grep fallback)
if [ "$CMM_AVAILABLE" = "true" ] || [ "$CTX_AVAILABLE" = "true" ]; then
  {
    echo "**Code navigation — MANDATORY. The tools below ARE available in your"
    echo "session; use them for all code work. Do NOT default to Read + grep.**"
    echo
    if [ "$CMM_AVAILABLE" = "true" ]; then
      echo "- \`search_graph\` (name_pattern=…) — find a function/method/class/module by"
      echo "  name; this is how you locate a definition. NEVER grep to check a symbol exists."
      echo "- \`get_code_snippet\` (qualified_name=…) — fetch a symbol's exact source instead"
      echo "  of opening and scrolling the whole file."
      echo "- \`trace_path\` (function_name=…) — who-calls-X / what-X-calls; use it for the"
      echo "  downstream-consumer and caller checks. Do NOT grep for callers."
      echo "- \`search_code\` (pattern=…) — text search over source (string literals, error"
      echo "  messages, TODOs) instead of a Bash \`grep\`."
      echo "- \`get_architecture\` — orient in an unfamiliar package first."
      echo "  Orient in order: get_architecture → search_graph → get_code_snippet. Every"
      echo "  symbol-existence / definition-site claim MUST be confirmed via get_code_snippet"
      echo "  or search_graph — a grep match is not proof a symbol exists."
    fi
    if [ "$CTX_AVAILABLE" = "true" ]; then
      echo "- \`ctx_execute\` / \`ctx_batch_execute\` — run \`git diff\`/\`git log\`, read large"
      echo "  files, and capture command/test output through these so the raw bytes stay out"
      echo "  of your context; only your derived findings return. Use \`ctx_search\` first to"
      echo "  reuse anything already captured this session."
    fi
    echo
    echo "Fall back to Read/grep only if a specific tool call genuinely fails."
  } > "$MANDATE_FILE"
fi

# ---------------------------------------------------------------------------
# Emit preflight.json
# ---------------------------------------------------------------------------
if [ "${#WARNINGS[@]}" -gt 0 ]; then
  WARNINGS_JSON=$(printf '%s\n' "${WARNINGS[@]}" | jq -R . | jq -s .)
else
  WARNINGS_JSON='[]'
fi
# Guard the other computed-JSON inputs too (empty => valid empty array).
[ -n "$CANDIDATES_JSON" ] || CANDIDATES_JSON='[]'

# Surface the deleted-file list the exit-3 gate is about. It was previously
# computed and discarded, leaving the operator to re-derive by hand the one thing
# that distinguishes "the base legitimately deleted these" from "my work is being
# reverted".
if [ -n "$DELETED_FILES" ]; then
  DELETED_FILES_JSON=$(printf '%s\n' "$DELETED_FILES" | grep -c . >/dev/null && printf '%s\n' "$DELETED_FILES" | jq -R . | jq -s .)
else
  DELETED_FILES_JSON='[]'
fi
[ -n "$DELETED_FILES_JSON" ] || DELETED_FILES_JSON='[]'

# ---------------------------------------------------------------------------
# Deterministic review routing. The main loop reads review_mode instead of
# re-deriving the manager-vs-sequential choice by model judgment each round:
#   "sequential" — tiny diff: a single reviewer (Step 3A) beats the overhead of
#                  spawning the manager + 3-lens panel.
#   "manager"    — non-trivial diff: delegate the round to the qa-manager
#                  subagent (Step 3A.1), which fans out the enforced lens panel.
# NOTE: this cannot detect at the shell level whether the *runtime* allows Agent
# nesting (manager -> lens grandchildren). If a manager/lens spawn is refused at
# run time, the main loop falls back to the sequential Step 3A path — review_mode
# is the routing DEFAULT, not an absolute guarantee.
REVIEW_MODE="manager"
[ "$TOTAL" -le "$SEQ_MAX" ] && REVIEW_MODE="sequential"

# ---------------------------------------------------------------------------
# Deterministic LENS selection. The manager reads this array and spawns exactly
# these qa-reviewer lenses — lens choice is data, not model judgment, the same
# principle as review_mode. Three CORE lenses always run; conditional lenses are
# added from the target's lens_tags plus the live schema signal. Rationale for
# each rule is in base-branches.json's _lens_comment.
#   - schema-propagation: whenever DDL is detected in THIS diff (so any target
#     that actually touches schema gets it) OR the target is schema-capable
#     (tag "schema" — where the documented outage was a CODE-ONLY schema
#     dependency the DDL scanner cannot see, so the lens earns its slot even with
#     no .sql change).
#   - performance is suppressed on a docs-only MR (nothing to profile).
# Cap at 6 (the measured Agent-grandchild concurrency ceiling — beyond it the
# panel waves and costs wall-clock for no parallelism gain). When more than three
# conditional lenses qualify, drop by priority: schema > api > ui > perf.
has_tag() { printf '%s\n' "$LENS_TAGS" | grep -qxF -- "$1"; }
LENSES=(contract-security regression-edges test-quality)   # core, always
CONDITIONAL=()
{ [ "$SCHEMA_DETECTED" = "true" ] || has_tag schema; } && CONDITIONAL+=(schema-propagation)
has_tag api && CONDITIONAL+=(api-envelope)
has_tag ui  && CONDITIONAL+=(ui-styling)
{ has_tag perf && [ "$DOCS_ONLY" != "true" ]; } && CONDITIONAL+=(performance)
# CONDITIONAL is already built in priority order (schema, api, ui, perf), so a
# simple head-of-list truncation to (6 - core) enforces both the cap and the
# priority drop in one step.
LENS_CAP=6
room=$(( LENS_CAP - ${#LENSES[@]} ))
i=0
for l in "${CONDITIONAL[@]:-}"; do
  [ -z "$l" ] && continue
  [ "$i" -ge "$room" ] && break
  LENSES+=("$l"); i=$((i+1))
done
# JSON array of the selected lens names (order = spawn order = core-first).
LENSES_JSON=$(printf '%s\n' "${LENSES[@]}" | jq -R . | jq -s .)

PREFLIGHT_JSON=$(jq -n \
  --argjson mr "$MR_NUMBER" \
  --arg target "$TARGET" --arg target_path "$TARGET_PATH" --arg target_abs "$TARGET_ABS" \
  --arg remote "$REMOTE" --arg scope "$SCOPE" \
  --arg base_branch "$RESOLVED_BASE" --arg base_branch_source "$RESOLVED_SOURCE" \
  --argjson security_stage "$SECURITY_STAGE" \
  --arg gitlab_project "$GITLAB_PROJECT" --arg gitlab_project_enc "$GITLAB_PROJECT_ENC" \
  --arg qa_scratch "$QA_SCRATCH" \
  --arg mr_title "$MR_TITLE" --arg mr_author "$MR_AUTHOR" \
  --arg source_branch "$SOURCE_BRANCH" --arg target_branch "$TARGET_BRANCH" \
  --arg state "$MR_STATE" --argjson draft "$MR_DRAFT" --arg changes_count "$CHANGES_COUNT" \
  --arg pipeline_status "$PIPELINE_STATUS" \
  --arg dev_user "$DEV_USER" --argjson is_own_branch "$IS_OWN_BRANCH" \
  --argjson qa_token_ok "$QA_TOKEN_OK" --arg qa_auth_user "$QA_AUTH_USER" \
  --argjson mr_approved "$MR_APPROVED" \
  --argjson sync_failed "$SYNC_FAILED" --arg sync_reason "$SYNC_REASON" \
  --argjson sync_uptodate "$SYNC_ALREADY_UPTODATE" --argjson sync_pushed "$SYNC_PUSHED" \
  --argjson unexpected_deletions "$UNEXPECTED_DELETIONS" \
  --argjson deleted_files "$DELETED_FILES_JSON" \
  --arg diffstat "$DIFF_SUMMARY" \
  --argjson insertions "$INS" --argjson deletions "$DEL" --argjson total_changed "$TOTAL" \
  --argjson is_tiny "$IS_TINY" \
  --arg review_mode "$REVIEW_MODE" \
  --argjson lenses "$LENSES_JSON" \
  --argjson schema_detected "$SCHEMA_DETECTED" \
  --arg schema_state "$SCHEMA_STATE" \
  --arg schema_evidence "$QA_SCRATCH/schema-change.md" \
  --arg sast_gate_state "$SAST_GATE_STATE" --argjson sast_running "$SAST_RUNNING" \
  --arg sast_report "$SAST_REPORT" --arg sast_helper_reason "$SAST_HELPER_REASON" \
  --argjson docs_only "$DOCS_ONLY" \
  --argjson cmm_available "$CMM_AVAILABLE" --argjson ctx_available "$CTX_AVAILABLE" \
  --arg tool_mandate_path "$MANDATE_FILE" \
  --argjson round "$ROUND" --arg proportionality_path "$PROPORTIONALITY_FILE" \
  --arg title_ticket "${TITLE_TICKET:-}" --argjson candidate_tickets "$CANDIDATES_JSON" \
  --argjson desc_len "$DESC_LEN" \
  --argjson warnings "$WARNINGS_JSON" \
  '{
    mr: $mr, target: $target, target_path: $target_path, target_abs: $target_abs,
    remote: $remote, scope: $scope,
    base_branch: $base_branch, base_branch_source: $base_branch_source,
    security_stage: $security_stage,
    gitlab_project: $gitlab_project, gitlab_project_enc: $gitlab_project_enc,
    qa_scratch: $qa_scratch,
    mr_title: $mr_title, mr_author: $mr_author,
    source_branch: $source_branch, target_branch: $target_branch,
    state: $state, draft: $draft, changes_count: $changes_count,
    pipeline_status: $pipeline_status,
    dev_user: $dev_user, is_own_branch: $is_own_branch,
    qa_token_ok: $qa_token_ok, qa_auth_user: $qa_auth_user,
    mr_approved: $mr_approved,
    sync: { failed: $sync_failed, reason: $sync_reason, already_up_to_date: $sync_uptodate,
            pushed: $sync_pushed, unexpected_deletions: $unexpected_deletions,
            deleted_files: $deleted_files,
            diffstat: $diffstat },
    diff_scope: { insertions: $insertions, deletions: $deletions, total_changed: $total_changed, is_tiny: $is_tiny },
    review_mode: $review_mode,
    lenses: $lenses,
    schema: { detected: $schema_detected, state: $schema_state, evidence_path: $schema_evidence },
    sast: { gate_state: $sast_gate_state, running: $sast_running, report_path: $sast_report,
            helper_reason: $sast_helper_reason },
    contract: { title_ticket: $title_ticket, candidate_tickets: $candidate_tickets, description_length: $desc_len },
    docs_only: $docs_only,
    round: $round,
    proportionality_path: $proportionality_path,
    tooling: { cmm_available: $cmm_available, ctx_available: $ctx_available, mandate_path: $tool_mandate_path },
    warnings: $warnings
  }') || die_internal "jq failed to build preflight.json (a --argjson input was not valid JSON)"

# Fail loudly rather than emitting an empty/partial preflight.json and exiting 0:
# every downstream step hydrates from this file, so a silent empty object would
# surface as a confusing cascade of "missing field" errors instead of one clear
# failure here. These are OUR invariants, not the operator's mistakes -> exit 5.
[ -n "$PREFLIGHT_JSON" ] || die_internal "preflight.json came out empty"
printf '%s' "$PREFLIGHT_JSON" | jq -e '
  (.scope           | type == "string") and
  (.diff_scope      | type == "object") and
  (.diff_scope.total_changed | type == "number") and
  (.review_mode     | test("^(manager|sequential)$")) and
  (.lenses          | type == "array") and
  # HONEST COVERAGE NOTE — the next two clauses are TRIPWIRES, not locked by
  # preflight.test.sh: deleting either ships the suite green. That is not
  # laziness, it is unreachable-by-construction — LENSES is seeded with the core
  # three and `room` is fixed at LENS_CAP-3, so length is always 3-6 and the core
  # is always present. They exist so a future refactor that makes the seeding
  # dynamic (or lets a caller supply the panel) trips here instead of emitting a
  # panel that silently drops a core lens. Same convention as the DIFF_RANGE
  # tripwire above: if you make either reachable, add a test that locks it.
  (.lenses | length | . >= 3 and . <= 6) and
  (.lenses | contains(["contract-security","regression-edges","test-quality"])) and
  # This clause IS reachable and IS locked (the enum-drift test).
  (.lenses | all(test("^(contract-security|regression-edges|test-quality|schema-propagation|api-envelope|ui-styling|performance)$"))) and
  (.sast.gate_state | test("^(clean|skipped:(no-stage|no-pipeline|pipeline-running|helper-failed|unknown))$")) and
  # A round of 0 or a non-number means the notes probe or the arithmetic broke.
  # Round drives the proportionality tier (>=3 tightens it) and the round-1-only
  # prompts in Step 3, so a silent 0 would both re-ask round-1 questions on a
  # late round and drop the tier that exists to stop a runaway cycle.
  # NOTE: no apostrophes in this jq program -- it is single-quoted in shell, so
  # one would terminate the string and hand the rest to bash as source.
  ((.round | type) == "number") and (.round >= 1) and
  ((.proportionality_path | type) == "string") and ((.proportionality_path | length) > 0)
' >/dev/null 2>&1 || die_internal "preflight.json failed its own shape assertions (scope must stay the registry string; diff_scope carries the numbers)"

printf '%s\n' "$PREFLIGHT_JSON" | tee "$QA_SCRATCH/preflight.json"

# Exit code contract
if [ "$SYNC_FAILED" = "true" ]; then exit 4; fi
if [ "$UNEXPECTED_DELETIONS" = "true" ]; then exit 3; fi
exit 0
