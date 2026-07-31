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
[ -n "$MR_NUMBER" ] || die_usage "missing MR number (usage: preflight.sh <MR> [TARGET])"
# TARGET is resolved after the config merge (Step 0): it is optional ONLY when the
# project defines exactly one target. See the note there — the obvious shortcut of
# defaulting it to `default` is wrong, and silently reviews the wrong subproject.

for t in git jq awk; do
  command -v "$t" >/dev/null 2>&1 || die_usage "required tool '$t' not on PATH"
done
# The forge CLI (glab/gh) is checked further down, once the remote has told us
# which forge this is — demanding both here would make a GitHub repo fail on a
# missing glab.

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
# Deliberately NOT XDG-aware. `qa_agent.token_file` defaults to the literal
# `~/.config/claude-qa-manager/qa-agent-token`, expanded against $HOME below; if
# this line honoured XDG_CONFIG_HOME the two would diverge and `init.sh token`
# would store a token where preflight never looks. Claude Code itself uses
# CLAUDE_CONFIG_DIR, not XDG (see the tool-mandate probe further down).
CONFIG_USER="$HOME/.config/claude-qa-manager/config.json"
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
# TARGET_COUNT drives every "does this project HAVE subprojects" decision
# downstream. `_comment` is a documentation key in the shipped defaults, not a
# target; counting it would make every single-project repo look like a monorepo
# and re-expose the whole subproject vocabulary this gate exists to suppress.
TARGET_COUNT=$(jq '[.targets | keys[] | select(. != "_comment")] | length' "$BB")
MULTI_TARGET=false; [ "$TARGET_COUNT" -gt 1 ] && MULTI_TARGET=true
_known=$(jq -r '[.targets | keys[] | select(. != "_comment")] | join(", ")' "$BB")

# Omitted TARGET is allowed only when there is exactly ONE target, and then it
# resolves to that target whatever its name.
#
# Defaulting to the literal name `default` instead LOOKS equivalent and is not.
# The three config layers DEEP-merge, so `targets.default` from the shipped
# defaults survives into every project — including a monorepo that defines seven
# real targets. A bare `preflight.sh 2184` would therefore have resolved silently
# to `default` (path "."), reviewed the repository root instead of the intended
# subproject, and reported a clean round on a diff it never looked at. Requiring
# the argument whenever the choice is real is the only safe form.
if [ -z "$TARGET" ]; then
  if [ "$TARGET_COUNT" -eq 1 ]; then
    TARGET=$(jq -r '[.targets | keys[] | select(. != "_comment")] | .[0]' "$BB")
  else
    die_usage "this project defines $TARGET_COUNT targets, so the target is required (usage: preflight.sh <MR> <TARGET>). Available: $_known"
  fi
fi
if [ "$(jq -r --arg t "$TARGET" '.targets | has($t)' "$BB")" != "true" ]; then
  die_usage "unknown target '$TARGET'. Available: $_known"
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
# NEVER read a boolean knob with jq's `//`. It is the ALTERNATIVE operator, not a
# null-coalesce: it fires on `false` as well as `null`, so `.x // true` can never
# return false and a user who explicitly disables a knob is silently overridden.
# (Same operator, opposite direction, as the `scope: ""` bug: `//` does NOT fire on
# an empty string.) Test for null instead.
cfg_bool() {   # $1 = jq path, $2 = default when the key is absent
  jq -r --argjson d "$2" "if ($1) == null then \$d else ($1) end" "$BB"
}
# Defaults must match config/defaults.json: they apply only when a key is absent,
# so a drifted default silently changes approval policy.
MIN_CLEAN_ROUND=$(jq -r '.qa_agent.approval.min_clean_round // 2' "$BB")
TINY_RELAX=$(cfg_bool '.qa_agent.approval.tiny_mr_relax_to_round_1' true)

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

# Absolute target dir (target_path "." == the repository root itself)
if [ "$TARGET_PATH" = "." ]; then
  TARGET_ABS="$REPO_ROOT"
else
  TARGET_ABS="$REPO_ROOT/$TARGET_PATH"
fi
[ -d "$TARGET_ABS" ] || die_usage "target path '$TARGET_ABS' does not exist"

# Is the TARGET actually a git submodule? Asked of git, not inferred from the
# path or the target's name: `target_path != "."` only means "a subdirectory",
# which in a plain monorepo is not a submodule and needs no parent-workspace
# commit. This is what gates the submodule reminder in the final report — the
# reminder is noise, and slightly alarming, in a repo that has no parent to
# update.
TARGET_IS_SUBMODULE=false
[ -n "$( (cd "$TARGET_ABS" && git rev-parse --show-superproject-working-tree 2>/dev/null) || true)" ] \
  && TARGET_IS_SUBMODULE=true

# How this target verifies a fix. DISCOVERED from the project's own rules, not
# configured here: the project already declares how it is tested, and a copy in
# this plugin's config would drift from it and then certify a command the project
# abandoned. `verify.command` exists as an override for when detection is wrong,
# and is empty by default.
VERIFY_OVERRIDE=$(jq -r '.verify.command // ""' "$BB")
if [ -n "$VERIFY_OVERRIDE" ]; then
  VERIFY_JSON=$(jq -n --arg c "$VERIFY_OVERRIDE" \
    '{state:"configured", command:$c, source:"config verify.command", build_command:"", build_source:""}')
else
  VERIFY_JSON=$(bash "$PLUGIN_ROOT/lib/detect-verify.sh" "$TARGET_ABS" 2>/dev/null || true)
  # A detector that crashed must not read as "this project has no tests" — that
  # is the same class of lie as a skipped gate reporting clean.
  jq -e . >/dev/null 2>&1 <<<"${VERIFY_JSON:-}" || \
    VERIFY_JSON='{"state":"none-found","command":"","source":"detector failed to run","build_command":"","build_source":""}'
fi

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
# Step 0.3 — resolve the forge and the project slug from the remote
#
# Ordered BEFORE the dev identity and the MR fetch because both go through the
# forge seam, and before the scratch dir because the hash input includes the
# project (the disambiguator — two targets can share an MR number).
# ---------------------------------------------------------------------------
FORGE_REMOTE_URL=$(cd "$TARGET_ABS" && git remote get-url "$REMOTE" 2>/dev/null)
# shellcheck source=forge.sh
. "$PLUGIN_ROOT/lib/forge.sh" || die_internal "could not load lib/forge.sh"
# Explicit config beats URL sniffing — a self-hosted GitLab or a GitHub
# Enterprise host contains neither "gitlab" nor "github". An env value already
# in QA_FORGE wins over the config key, so a one-off run can override a repo.
QA_FORGE="${QA_FORGE:-$(jq -r '.forge // ""' "$BB")}"
export QA_FORGE
forge_init "$FORGE_REMOTE_URL" "$PLUGIN_ROOT/lib" \
  || die_usage "could not determine the forge for remote '$REMOTE' (url '$FORGE_REMOTE_URL'); set \"forge\": \"gitlab\"|\"github\" in your project config"

FORGE_CLI=$(forge_cli)
command -v "$FORGE_CLI" >/dev/null 2>&1 \
  || die_usage "required tool '$FORGE_CLI' not on PATH (needed for $FORGE)"

FORGE_PROJECT=$(forge_project_slug "$FORGE_REMOTE_URL") \
  || die_usage "could not resolve a <group>/<project> path from remote '$REMOTE' url '$FORGE_REMOTE_URL'"
FORGE_PROJECT_ENC=$(forge_project_enc "$FORGE_PROJECT")

# ---------------------------------------------------------------------------
# Step 0 — dev identity + MR inspection (dev token)
# ---------------------------------------------------------------------------
# An unresolvable dev identity is NOT fatal: it only feeds is_own_branch, and
# the safe answer there is false (report-only), which the empty string gives.
DEV_USER=$(forge_auth_user || true)

MR_JSON=$(forge_view_mr "$TARGET_ABS" "$MR_NUMBER") || \
  die_usage "could not read $FORGE request $MR_NUMBER in $TARGET_ABS (via $FORGE_CLI)"
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
# Step 0.4 — scratch dir. FORGE_PROJECT is resolved in Step 0.3 above (it has to
# be: the hash input includes the project disambiguator, and the forge seam
# needs it earlier still). The URL parsing itself now lives in
# forge_project_slug — one implementation, shared by both backends.
# ---------------------------------------------------------------------------
QA_SCRATCH_INPUT=$(printf '%s|%s|%s' "$TARGET_ABS" "$FORGE_PROJECT" "$MR_NUMBER")
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
  QA_AUTH_USER=$(forge_auth_user "$QA_TOKEN" || true)
  if [ -n "$QA_AUTH_USER" ] && [ "$QA_AUTH_USER" = "$EXPECTED_QA_USER" ]; then QA_TOKEN_OK=true; fi
fi

# ---------------------------------------------------------------------------
# Step 0.7 — seed MR_APPROVED from the forge (QA identity; only if token verified)
# ---------------------------------------------------------------------------
MR_APPROVED=false
if [ "$QA_TOKEN_OK" = "true" ]; then
  APPROVED_BY=$(forge_approvers "$FORGE_PROJECT" "$MR_NUMBER" "$QA_TOKEN" || true)
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
  # One helper per forge, not one helper with a forge branch: GitLab reads
  # security-report artifacts off a pipeline job, GitHub reads code-scanning
  # alerts off an API — genuinely different mechanisms, sharing only the output
  # contract (the headings this block classifies below).
  SAST_HELPER="$PLUGIN_ROOT/lib/fetch-sast-${FORGE}.sh"
  if SAST_HELPER_ERR=$(bash "$SAST_HELPER" \
        --project "$FORGE_PROJECT" --mr "$MR_NUMBER" \
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
# from the forge’s notes API on each run, which is exactly the mechanical work
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
if [ -n "${FORGE_PROJECT:-}" ]; then
  _NOTES_RC=0
  if [ "$QA_TOKEN_OK" = "true" ]; then
    _NOTES_JSON=$(forge_notes "$FORGE_PROJECT" "$MR_NUMBER" "$QA_TOKEN") || _NOTES_RC=$?
  else
    _NOTES_JSON=$(forge_notes "$FORGE_PROJECT" "$MR_NUMBER") || _NOTES_RC=$?
  fi
  if [ "$_NOTES_RC" -ne 0 ]; then
    WARNINGS+=("round_probe_failed:exit=${_NOTES_RC}")
    echo "warn: could not read MR notes (${FORGE_CLI} exit ${_NOTES_RC}); round falls back to 1 and may be wrong." >&2
  else
    _MAX_ROUND=$(printf '%s' "$_NOTES_JSON" | jq -r '.[]?.body // empty' 2>/dev/null \
      | grep -oE '^## QA Round [0-9]+' | grep -oE '[0-9]+' | sort -n | tail -1)
    [ -n "$_MAX_ROUND" ] && ROUND=$((_MAX_ROUND + 1))

    # This cycle's own fix commits, read back from the trailers earlier rounds
    # wrote into their notes. They are what lets a later round tell "a defect in
    # the MR" from "a defect THIS CYCLE introduced while fixing something else".
    #
    # Read from the notes rather than matched by commit subject on purpose: a
    # rebase, a squash, or a hand-edited message breaks subject matching, and the
    # round note is already the cycle's durable ledger (the deferred-findings
    # exit runs on the same principle — what is not written down did not happen).
    QA_FIX_COMMITS=$(printf '%s' "$_NOTES_JSON" | jq -r '.[]?.body // empty' 2>/dev/null \
      | grep -oE '^QA-Fix-Commit:[[:space:]]*[0-9a-f]{7,40}' \
      | grep -oE '[0-9a-f]{7,40}' | sort -u | jq -R . | jq -sc .)
  fi
fi
[ -n "${QA_FIX_COMMITS:-}" ] || QA_FIX_COMMITS='[]'

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
# Approval eligibility, computed here rather than by the skill at runtime.
#
# It is a function of $ROUND and three config knobs, all of which preflight
# already holds — so having the main loop recompute it bought nothing and cost a
# silent failure mode. The manager conditions both its `approval` and `sast_wait`
# decisions on eligibility but is given none of the inputs, so when main forgot to
# pass it, the manager could never raise either decision and the hands-free path
# silently never approved anything.
#
# Eligibility is NECESSARY, NOT SUFFICIENT. Step 3E still re-checks every gate
# (clean round, QA_TOKEN_OK, schema-change acknowledgement) before approving.
APPROVAL_ELIGIBLE=false
if [ "$ROUND" -ge "$MIN_CLEAN_ROUND" ]; then
  APPROVAL_ELIGIBLE=true
elif [ "$TINY_RELAX" = "true" ] && [ "$IS_TINY" = "true" ]; then
  APPROVAL_ELIGIBLE=true
fi

# Fix-commit subject, rendered here rather than assembled in the skill. A scope
# is a MULTI-PROJECT concept: it says which subproject a commit belongs to, and a
# single-project repo has no answer. The shipped default target carries
# `scope: ""`, and `.scope // $t` does NOT fall back on it — jq's `//` fires on
# null and false, and an empty string is truthy — so the skill rendered a literal
# `fix(): address QA round 1`, which is malformed conventional-commit and is
# rejected outright by a commitlint hook. Emitting the finished string keeps the
# empty-scope branch in one tested place instead of in prose.
if [ -n "$SCOPE" ]; then
  COMMIT_SUBJECT="fix($SCOPE): address QA round $ROUND"
else
  COMMIT_SUBJECT="fix: address QA round $ROUND"
fi

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
# Detection takes the UNION of every plausible location rather than resolving one.
# That is a deliberate difference from a canonical resolver (CLAUDE_CONFIG_DIR ->
# ~/.config/claude-code -> ~/.claude, FIRST MATCH WINS), which is correct when you
# are about to WRITE a config. Here the question is "is it registered anywhere this
# session can see", and a false negative is not neutral: it makes fix-mandate.md
# announce the text-search-only regime while a fully indexed graph sits unused, so
# Step 3B reconciles by regex when it could have queried the call graph. When the
# candidate roots disagree, over-detecting is the safe direction.
#
# `~/.claude` is the LEGACY DEFAULT and still very common. An earlier version
# resolved a single root as "${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code}" with
# no existence check, so on a legacy install the plugin-cache scan targeted a
# directory that does not exist and a plugin-form install was invisible.
_claude_roots() {
  local d
  for d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"; do
    [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
  done
}
# Project roots. $REPO_ROOT is the SUPERPROJECT (correct for target paths, and
# load-bearing for them) but wrong for this: Claude Code resolves `.mcp.json` from
# where the session was launched, which inside a submodule is the submodule itself,
# not its parent. Same variable, right for one purpose and wrong for the other, so
# take both plus the session's own project dir when it is exported.
_project_roots() {
  local d
  for d in "${CLAUDE_PROJECT_DIR:-}" "$(git rev-parse --show-toplevel 2>/dev/null || true)" "$REPO_ROOT"; do
    [ -n "$d" ] && [ -d "$d" ] && printf '%s\n' "$d"
  done
}
# Registration is read with jq, not grepped. A substring grep matches a DISABLED
# entry too -- `"codebase-memory-mcp@mkt": false` in enabledPlugins made the probe
# report the tool as available, and the mandate then asserts a graph that is not
# there. Recursive (`..`) because ~/.claude.json nests per-project mcpServers maps.
_registered_in_file() {  # $1 = json file, $2 = plugin/server name
  jq -e --arg n "$2" '
    [ .. | objects
      | ( ((.mcpServers?    // empty) | objects | has($n)) // false )
        or
        ( ((.enabledPlugins? // empty) | objects | to_entries
            | any(.value == true and ((.key | split("@")[0]) == $n))) // false )
    ] | any
  ' "$1" >/dev/null 2>&1
}
_probe_registered() {  # $1 = plugin/server name
  local name="$1" root f
  for root in $(_project_roots | sort -u); do
    for f in "$root/.mcp.json" "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
      [ -f "$f" ] && _registered_in_file "$f" "$name" && return 0
    done
  done
  for root in $(_claude_roots | sort -u); do
    # settings.local.json first: it overrides settings.json.
    for f in "$root/.mcp.json" "$root/settings.local.json" "$root/settings.json" "$root/.claude.json"; do
      [ -f "$f" ] && _registered_in_file "$f" "$name" && return 0
    done
  done
  [ -f "$HOME/.claude.json" ] && _registered_in_file "$HOME/.claude.json" "$name" && return 0
  # Plugin cache. Variable-depth on purpose: the real layout is
  # <cache>/<marketplace>/<plugin>[/<version>]/.claude-plugin/plugin.json, so a
  # fixed-depth glob silently misses every versioned install.
  local cache_roots="" p
  for root in $(_claude_roots | sort -u); do
    [ -d "$root/plugins/cache" ] && cache_roots="$cache_roots $root/plugins/cache"
  done
  # If THIS plugin was itself loaded from a cache, that locates the cache without
  # guessing a config root at all. Walk up looking for .../plugins/cache.
  # The `$prev` guard is not decorative: dirname of a RELATIVE path stalls at "."
  # (dirname "." == "."), so a loop that only tests for "/" never terminates.
  p="${CLAUDE_PLUGIN_ROOT:-}"; local prev=""
  while [ -n "$p" ] && [ "$p" != "/" ] && [ "$p" != "$prev" ]; do
    case "$p" in */plugins/cache) [ -d "$p" ] && cache_roots="$cache_roots $p"; break ;; esac
    prev="$p"; p="$(dirname "$p")"
  done
  for root in $(printf '%s\n' $cache_roots | sort -u); do
    find "$root" -maxdepth 7 -name plugin.json -path '*/.claude-plugin/*' \
      -exec grep -q "\"name\"[[:space:]]*:[[:space:]]*\"$name\"" {} \; -print 2>/dev/null \
      | grep -q . && return 0
  done
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
# Fix mandate -> $QA_SCRATCH/fix-mandate.md  (consumed ONLY by Step 3B)
# ---------------------------------------------------------------------------
# A SEPARATE file from tool-mandate.md on purpose. tool-mandate.md is injected
# verbatim into every lens spawn prompt, and reviewers are explicitly forbidden
# from prescribing fixes (agents/qa-reviewer.md) — fix guidance there is noise in
# the prompt whose adoption effect was actually measured. This file is review's
# mirror image: it is read by the ORCHESTRATOR before it edits code in Step 3B.
#
# It is NEVER empty, unlike tool-mandate.md. The fix step must always know which
# regime it is in, because the two give different guarantees and the weaker one
# must say so out loud (invariant: an absent check never reports as a pass).
# With a call graph, "no other call sites" is an answer. Without one it is the
# absence of a regex match, which is not the same claim.
FIX_MANDATE_FILE="$QA_SCRATCH/fix-mandate.md"
{
  echo "**Before editing code to address a finding.**"
  echo
  echo "**Any claim about behaviour in code OUTSIDE this diff must be confirmed by opening"
  echo "that code.** A ticket, an MR description, a changelog, or an earlier round's commit"
  echo "message is a claim, not evidence. This is not a stylistic preference: on a measured"
  echo "5-round cycle, ONE unverified assumption about a backend handler — inferred from"
  echo "another MR's description rather than read from the source — produced defects in three"
  echo "of the five rounds, twice critical, because each later round's fix built on it."
  echo "If you state such an assumption in a fix commit message, you have just made it"
  echo "load-bearing for every round that follows. Verify it first, or do not write it."
  echo
  if [ "$CMM_AVAILABLE" = "true" ]; then
    echo "A code-navigation graph IS available. Site discovery is a graph query, not a grep."
    echo
    echo "1. **Check the index is fresh FIRST.** Run \`detect_changes\` (or \`index_status\`);"
    echo "   re-index the repository ROOT if it is stale. This step is not optional. An index"
    echo "   built before this MR's commits answers \`trace_path\` with the callers of the OLD"
    echo "   code and reports no other sites — a reconciliation that looks exhaustive and"
    echo "   examined nothing. That is strictly worse than grep, which at least fails noisily."
    echo "2. **Read the real source before editing it.** \`search_graph\` to resolve the symbol,"
    echo "   \`get_code_snippet\` for its exact current body. Never edit from the finding's"
    echo "   description plus a line number — the finding is evidence, not a model of the code."
    echo "3. **Find every site with \`trace_path\`, not \`grep\`.** Every caller is a candidate"
    echo "   site for the same defect. A regex misses a renamed alias, a re-export, a call split"
    echo "   across lines, and a differently-cased spelling — and it misses them SILENTLY."
    echo "4. **Then sweep for what a graph cannot hold**, with \`search_code\`: config, migrations,"
    echo "   templates, fixtures, docs, and any call name built from a string at runtime."
    echo "   Dynamic dispatch and reflection are invisible to a static graph — say so if the"
    echo "   changed code uses them, rather than implying the sweep was complete."
    echo "5. Note that \`CALLS\` edges are LSP-resolved only for the supported language families."
    echo "   Outside them the edges are heuristic: fall back to \`search_code\` and say which"
    echo "   regime applied."
  else
    echo "No code-navigation graph is registered in this session. Site discovery is TEXT SEARCH"
    echo "ONLY, and is therefore best-effort — not exhaustive."
    echo
    echo "1. **Read the whole file before editing it.** Never edit from the finding's description"
    echo "   plus a line number."
    echo "2. **Look for sibling sites deliberately.** The most common defect this cycle finds is a"
    echo "   fix that hardens one place while another still asserts the opposite. Search for the"
    echo "   symbol, its snake_case/camelCase variants, and any alias or re-export."
    echo "3. **Do not claim the sweep was exhaustive.** Report reconciliation as best-effort in the"
    echo "   round note, so a missed sibling site reads as a known limit and not as a clean pass."
  fi
} > "$FIX_MANDATE_FILE"

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

# ---------------------------------------------------------------------------
# Manager brief -> $QA_SCRATCH/manager-brief.txt
# ---------------------------------------------------------------------------
# The spawn payload for the qa-manager Agent, rendered here instead of being
# transcribed by the model out of preflight.json at spawn time.
#
# Every value below already existed in this script; the skill's job was to copy
# ~20 of them into a text blob on every round of every MR. That is per-invocation
# cost for a purely mechanical transformation; it is an error surface nothing
# tested (a dropped field is invisible until the manager misbehaves); and it made
# the spine carry a paragraph per field explaining why that field is passed.
# Rendering it once, here, removes all three — Step 3A.1 now passes `brief_path`.
#
# Emitted LAST because it depends on nearly everything above: $ROUND, $LENSES_JSON,
# the mandate files, and the sync'd branch names are all resolved by this point.
# Values only, no prose: the manager's contract lives in agents/qa-manager.md,
# which the manager reads for itself.
MANAGER_BRIEF="$QA_SCRATCH/manager-brief.txt"
{
  printf 'target_abs=%s\n'             "$TARGET_ABS"
  printf 'mr=%s\n'                     "$MR_NUMBER"
  printf 'round=%s\n'                  "$ROUND"
  printf 'feature_branch=%s\n'         "$SOURCE_BRANCH"
  printf 'target_branch=%s\n'          "$TARGET_BRANCH"
  printf 'diff_range=%s\n'             "$REMOTE/$TARGET_BRANCH..HEAD"
  printf 'lenses=%s\n'                 "$(printf '%s' "$LENSES_JSON" | jq -c .)"
  printf 'forge=%s\n'                  "$FORGE"
  printf 'project=%s\n'                "$FORGE_PROJECT"
  printf 'project_enc=%s\n'            "$FORGE_PROJECT_ENC"
  printf 'qa_scratch=%s\n'             "$QA_SCRATCH"
  printf 'contract_path=%s\n'          "$QA_SCRATCH/contract.md"
  printf 'sast_path=%s\n'              "$SAST_REPORT"
  printf 'schema_change_path=%s\n'     "$QA_SCRATCH/schema-change.md"
  printf 'tool_mandate_path=%s\n'      "$MANDATE_FILE"
  printf 'proportionality_path=%s\n'   "$PROPORTIONALITY_FILE"
  printf 'schema_change_detected=%s\n' "$SCHEMA_DETECTED"
  printf 'qa_token_ok=%s\n'            "$QA_TOKEN_OK"
  printf 'expected_qa_user=%s\n'       "$EXPECTED_QA_USER"
  # Both the env var NAME and the file path, so the manager resolves the token
  # env-first then file — the order this script uses. Given only the file, an
  # env-only token resolves empty and the round note posts under the DEVELOPER's
  # identity instead of the QA agent's.
  printf 'qa_token_env=%s\n'           "$QA_TOKEN_ENV"
  printf 'qa_token_file=%s\n'          "$QA_TOKEN_FILE"
  # Lets the manager honour the Step 3B.6 ordering rule: never post a round that
  # found new confirmed critical/major findings onto an MR the QA agent already
  # approved. It returns unapprove_before_post; main revokes, then posts.
  printf 'mr_approved=%s\n'            "$MR_APPROVED"
  printf 'approval_eligible=%s\n'      "$APPROVAL_ELIGIBLE"
  printf 'unapprove_on_dirty_reround=%s\n' "$(cfg_bool '.qa_agent.approval.unapprove_on_dirty_reround' true)"
  printf 'sast_running=%s\n'           "$SAST_RUNNING"
  # This cycle's own fix commits, recovered from earlier rounds' note trailers.
  # Feed them to lib/attribute-findings.sh to mark findings that sit on code a
  # previous round of THIS cycle wrote.
  printf 'qa_fix_commits=%s\n'         "$QA_FIX_COMMITS"
} > "$MANAGER_BRIEF"

PREFLIGHT_JSON=$(jq -n \
  --argjson mr "$MR_NUMBER" \
  --arg target "$TARGET" --arg target_path "$TARGET_PATH" --arg target_abs "$TARGET_ABS" \
  --arg remote "$REMOTE" --arg scope "$SCOPE" \
  --arg base_branch "$RESOLVED_BASE" --arg base_branch_source "$RESOLVED_SOURCE" \
  --argjson security_stage "$SECURITY_STAGE" \
  --arg forge "$FORGE" --arg forge_cli "$FORGE_CLI" \
  --arg project "$FORGE_PROJECT" --arg project_enc "$FORGE_PROJECT_ENC" \
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
  --arg fix_mandate_path "$FIX_MANDATE_FILE" \
  --arg commit_subject "$COMMIT_SUBJECT" \
  --argjson approval_eligible "$APPROVAL_ELIGIBLE" \
  --arg manager_brief_path "$MANAGER_BRIEF" \
  --argjson qa_fix_commits "$QA_FIX_COMMITS" \
  --argjson multi_target "$MULTI_TARGET" --argjson target_count "$TARGET_COUNT" \
  --argjson target_is_submodule "$TARGET_IS_SUBMODULE" \
  --argjson verify "$VERIFY_JSON" \
  --argjson round "$ROUND" --arg proportionality_path "$PROPORTIONALITY_FILE" \
  --arg title_ticket "${TITLE_TICKET:-}" --argjson candidate_tickets "$CANDIDATES_JSON" \
  --argjson desc_len "$DESC_LEN" \
  --argjson warnings "$WARNINGS_JSON" \
  '{
    mr: $mr, target: $target, target_path: $target_path, target_abs: $target_abs,
    remote: $remote, scope: $scope,
    base_branch: $base_branch, base_branch_source: $base_branch_source,
    security_stage: $security_stage,
    forge: $forge, forge_cli: $forge_cli,
    project: $project, project_enc: $project_enc,
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
    tooling: { cmm_available: $cmm_available, ctx_available: $ctx_available, mandate_path: $tool_mandate_path, fix_mandate_path: $fix_mandate_path },
    commit_subject: $commit_subject,
    approval_eligible: $approval_eligible,
    manager_brief_path: $manager_brief_path,
    qa_fix_commits: $qa_fix_commits,
    # NOT `project`: that key is already the forge project slug. A duplicate key
    # is silently resolved by jq in favour of the LAST one, which is exactly how
    # the registry `scope` string was destroyed by `diff_scope` once before.
    layout: { multi_target: $multi_target, target_count: $target_count, target_is_submodule: $target_is_submodule },
    verify: $verify,
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
