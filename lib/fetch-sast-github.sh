#!/usr/bin/env bash
# fetch-sast-github.sh
# -----------------------------------------------------------------------------
# Compute security findings for a GitHub pull request and emit a markdown report
# for the qa-reviewer prompt. GitHub counterpart of lib/fetch-sast-gitlab.sh.
#
# The two helpers share an INTERFACE and an OUTPUT CONTRACT, not an
# implementation — GitLab diffs security-report artifacts off a pipeline job,
# GitHub reads code-scanning alerts off an API. Folding those into one script
# with a forge branch would be longer than keeping two.
#
# INTERFACE (identical to the GitLab helper; preflight.sh calls both the same way):
#   --project <owner/repo>  --mr <N>  --target-path <path>  --output <file>
#   [--severity-floor high]
#
# OUTPUT CONTRACT — preflight.sh Step 2.5 classifies this report by heading and
# phrase, and NEVER defaults to "clean". Emit exactly one of:
#
#   "## SAST review skipped" + "No security stage detected"      -> skipped:no-stage
#   "## SAST review skipped" + "No pipeline associated with MR"  -> skipped:no-pipeline
#   "## SAST review skipped" + "Security scans are still in progress"
#                                                                -> skipped:pipeline-running
#   "## NEW SAST findings ..."                                   -> clean (a scan RAN)
#
# Anything else classifies as skipped:unknown with a warning — safe, but it
# means the round is not credited with a security review. Do not reword these
# phrases on one side only.
#
# ORDER MATTERS, and this is where the source implementation was wrong: it
# emitted the "checks still running" warning as a subsection AFTER the
# "## NEW SAST findings" heading, so a still-running scan classified as `clean`
# and Step 3E could write "security reviewed" into a permanent approval comment
# on a scan that had not finished. Every "did not run" state is therefore
# decided BEFORE the findings heading is emitted, and exits.
#
# Requires: gh (authenticated), jq.
# Exits 0 on every graceful skip; non-zero only on tool failure or an
# unresolvable repo/PR (which preflight reports as skipped:helper-failed — a
# must-ask-the-user event, not a silent pass).
# -----------------------------------------------------------------------------
set -euo pipefail

PROG="fetch-sast-github.sh"
REPO=""
PR=""
TARGET_PATH=""
HEAD_REF=""
SEVERITY_FLOOR="high"
OUTPUT=""

usage() { sed -n '2,40p' "$0"; exit 2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --project|--repo) REPO="$2"; shift 2;;
    --mr|--pr)        PR="$2"; shift 2;;
    --target-path)    TARGET_PATH="$2"; shift 2;;
    --head-ref)       HEAD_REF="$2"; shift 2;;
    --severity-floor) SEVERITY_FLOOR="$2"; shift 2;;
    --output)         OUTPUT="$2"; shift 2;;
    -h|--help)        usage;;
    *) echo "${PROG}: unknown arg: $1" >&2; usage;;
  esac
done

for tool in gh jq; do
  command -v "$tool" >/dev/null 2>&1 || { echo "${PROG}: missing required tool: $tool" >&2; exit 3; }
done

[ -n "$REPO" ] || REPO=$(gh repo view --json nameWithOwner --jq '.nameWithOwner' 2>/dev/null || true)
[ -n "$REPO" ] || { echo "${PROG}: could not resolve --project (pass --project owner/name)" >&2; exit 3; }
[ -n "$PR" ]   || { echo "${PROG}: --mr required" >&2; usage; }

[ -n "$OUTPUT" ] && : > "$OUTPUT"
emit() {
  [ -n "$OUTPUT" ] && printf '%s\n' "$1" >> "$OUTPUT"
  printf '%s\n' "$1"
}

# One scratch dir, removed wholesale. A `mktmp` helper that appended to an array
# would not work here: `x="$(mktmp)"` runs the helper in a SUBSHELL, so the
# parent's array stays empty and nothing is ever cleaned up.
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# An unresolvable head ref is a FAILURE, not a skip: code-scanning alerts are
# queried per-ref, so without it nothing can be computed and nothing should
# claim to have been. Exit non-zero so preflight reports helper-failed.
[ -n "$HEAD_REF" ] || HEAD_REF=$(gh pr view "$PR" --repo "$REPO" --json headRefName --jq '.headRefName' 2>/dev/null || true)
[ -n "$HEAD_REF" ] || { echo "${PROG}: could not resolve the head branch for PR #${PR} on ${REPO}" >&2; exit 4; }

# -----------------------------------------------------------------------------
# Gate 1 — the PR's checks. Decided BEFORE any findings are emitted.
# -----------------------------------------------------------------------------
# `gh pr checks` exits non-zero both when checks are FAILING and when there are
# none at all, so its status says nothing useful here; read the JSON instead and
# let an empty array mean "none".
CHK="$WORK/checks.json"
gh pr checks "$PR" --repo "$REPO" --json name,state 2>/dev/null > "$CHK" || echo '[]' > "$CHK"
jq -e 'type == "array"' "$CHK" >/dev/null 2>&1 || echo '[]' > "$CHK"

TOTAL_CHECKS=$(jq 'length' "$CHK")
SEC_RE='codeql|security|sast|scan|snyk|semgrep|trivy|dependabot'
SEC_TOTAL=$(jq --arg re "$SEC_RE" '[ .[] | select(.name | ascii_downcase | test($re)) ] | length' "$CHK")
SEC_RUNNING=$(jq --arg re "$SEC_RE" '
  [ .[]
    | select(.name | ascii_downcase | test($re))
    | select((.state // "") | ascii_downcase
             | . == "pending" or . == "in_progress" or . == "queued" or . == "waiting" or . == "requested")
  ] | length' "$CHK")

if [ "$TOTAL_CHECKS" -eq 0 ]; then
  emit "## SAST review skipped"
  emit ""
  emit "No pipeline associated with MR #${PR} on \`${REPO}\` — no check runs exist for the head ref \`${HEAD_REF}\` yet. This is normal moments after a push; re-run \`/qa-cycle\` once the workflows start."
  exit 0
fi

if [ "$SEC_RUNNING" -gt 0 ]; then
  emit "## SAST review skipped"
  emit ""
  emit "Security scans are still in progress — ${SEC_RUNNING} of ${SEC_TOTAL} security-related check(s) on \`${HEAD_REF}\` have not finished. No security delta is certified this round. Re-run \`/qa-cycle\` once they complete (you do not need to wait for the whole workflow set)."
  exit 0
fi

# -----------------------------------------------------------------------------
# Gate 2 — code scanning availability.
# -----------------------------------------------------------------------------
# 403 = code scanning not enabled / not on the plan, 404 = no analysis yet.
# Both mean "no SAST wired", which is the no-stage state — the same thing
# `security_stage: false` means on the GitLab side.
CS="$WORK/code-scanning.json"
CS_OK=false
if gh api -H "Accept: application/vnd.github+json" \
     "/repos/${REPO}/code-scanning/alerts?ref=refs/heads/${HEAD_REF}&state=open&per_page=100" \
     > "$CS" 2>/dev/null && jq -e 'type == "array"' "$CS" >/dev/null 2>&1; then
  CS_OK=true
fi

if [ "$CS_OK" != "true" ] && [ "$SEC_TOTAL" -eq 0 ]; then
  emit "## SAST review skipped"
  emit ""
  emit "No security stage detected for \`${REPO}\`: code scanning is not enabled (or exposes no alerts for ref \`${HEAD_REF}\`) and no security-related check runs exist on this PR. Enable GitHub code scanning to populate this section."
  exit 0
fi

if [ "$CS_OK" != "true" ]; then
  # Security checks RAN but their findings cannot be read. Neither a clean scan
  # nor a missing one — say so plainly and let preflight classify it unknown
  # rather than inventing a state that certifies a review we cannot see.
  emit "## SAST review inconclusive"
  emit ""
  emit "${SEC_TOTAL} security-related check(s) completed on \`${HEAD_REF}\`, but the code-scanning alerts endpoint returned no alert array (not enabled, or the token lacks the \`security_events\` scope). Findings could not be read, so no security delta is certified this round."
  exit 0
fi

# -----------------------------------------------------------------------------
# Findings. Reaching here means a scan RAN and its results were readable.
# -----------------------------------------------------------------------------
sev_rank() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    critical) echo 4;; high) echo 3;; medium) echo 2;; low) echo 1;; *) echo 0;;
  esac
}
FLOOR_RANK=$(sev_rank "$SEVERITY_FLOOR")

TOTAL_ALERTS=$(jq 'length' "$CS")
FILTERED=$(jq -r --argjson floor "$FLOOR_RANK" '
  def rank(s): (s|ascii_downcase) as $s
    | if $s=="critical" then 4 elif $s=="high" then 3 elif $s=="medium" then 2 elif $s=="low" then 1 else 0 end;
  [ .[]
    | { sev:  (.rule.security_severity_level // .rule.severity // "unknown"),
        name: (.rule.id // .rule.name // "rule"),
        desc: (.rule.description // .most_recent_instance.message.text // ""),
        file: (.most_recent_instance.location.path // "?"),
        line: (.most_recent_instance.location.start_line // 0) }
    | select(rank(.sev) >= $floor) ]
  | sort_by(rank(.sev)) | reverse
  | .[]
  | "- **\(.sev|ascii_upcase)** `\(.file):\(.line)` — \(.name): \(.desc | .[0:140])"
' "$CS" 2>/dev/null || true)

emit "## NEW SAST findings (GitHub code scanning, open alerts on \`${HEAD_REF}\`)"
emit ""
emit "_Open code-scanning alerts on the PR head ref, filtered at severity floor \`${SEVERITY_FLOOR}\` (total open alerts at any severity: ${TOTAL_ALERTS}). GitHub exposes no per-job baseline the way GitLab artifacts do, so this is an absolute snapshot of the head ref, NOT a strict delta against the base branch — weigh each finding as either intentional (and worth dismissing with a reason) or a regression this PR should fix._"
emit ""
if [ -z "$FILTERED" ]; then
  emit "_No open code-scanning alerts at or above severity \`${SEVERITY_FLOOR}\` on \`${HEAD_REF}\`._"
else
  printf '%s\n' "$FILTERED" | while IFS= read -r line; do emit "$line"; done
fi
emit ""

# Dependabot: repo-wide, not per-ref — GitHub does not scope these to a branch,
# so it is advisory and never gates the round.
DB="$WORK/dependabot.json"
emit "### Dependabot (SCA) — advisory, repo-wide"
emit ""
if gh api -H "Accept: application/vnd.github+json" \
     "/repos/${REPO}/dependabot/alerts?state=open&per_page=100" > "$DB" 2>/dev/null \
   && jq -e 'type == "array"' "$DB" >/dev/null 2>&1; then
  DB_FILTERED=$(jq -r --argjson floor "$FLOOR_RANK" '
    def rank(s): (s|ascii_downcase) as $s
      | if $s=="critical" then 4 elif $s=="high" then 3 elif $s=="medium" then 2 elif $s=="low" then 1 else 0 end;
    [ .[]
      | { sev:     (.security_advisory.severity // "unknown"),
          pkg:     (.dependency.package.name // "?"),
          ghsa:    (.security_advisory.ghsa_id // "?"),
          summary: (.security_advisory.summary // "") }
      | select(rank(.sev) >= $floor) ]
    | sort_by(rank(.sev)) | reverse
    | .[]
    | "- **\(.sev|ascii_upcase)** `\(.pkg)` — \(.ghsa): \(.summary | .[0:140])"
  ' "$DB" 2>/dev/null || true)
  if [ -z "$DB_FILTERED" ]; then
    emit "_No open Dependabot alerts at or above severity \`${SEVERITY_FLOOR}\`._"
  else
    emit "_Repo-wide, not scoped to this PR; advisory unless the PR touches the affected dependency manifest._"
    emit ""
    printf '%s\n' "$DB_FILTERED" | while IFS= read -r line; do emit "$line"; done
  fi
else
  emit "_Dependabot alerts unavailable (not enabled, or the token lacks the \`security_events\` scope). Skipped — non-blocking._"
fi
emit ""

emit "---"
emit ""
emit "**Note:** GitHub code scanning reports an absolute snapshot of open alerts on the head ref, not a NEW-vs-baseline delta. Treat each finding as either intentional or a regression."

exit 0
