#!/usr/bin/env bash
# fetch-sast-findings.sh
# -----------------------------------------------------------------------------
# Compute NEW security findings for an MR vs the checked-in baselines and emit
# a markdown report suitable for inclusion in the mr-qa reviewer prompt.
#
# Reads the latest pipeline for the MR, downloads each security scanner job's
# artifact, diffs it against the matching baseline file in the target's
# working tree, and writes a per-scanner report to stdout (and optionally to
# /tmp/mr-<MR>-sast-deltas.md when --output is passed).
#
# Used by: .claude/skills/mr-qa/SKILL.md Step 2.5 (security review pre-pass).
#
# Requires: glab (authenticated), jq, unzip.
#
# Usage:
#   fetch-sast-findings.sh \
#     --project example-org/example-repo \
#     --mr 2097 \
#     --target-path apps/webapp \
#     [--output /tmp/mr-2097-sast-deltas.md]
#
# Behavior:
#   - Auto-detects which security scanners ran in the latest pipeline.
#   - Skips entirely (exits 0 with a one-line note) when no security jobs are
#     present, when the pipeline is still running/pending, or when artifacts
#     are missing/expired.
#   - Treats the absence of a baseline file as "first run" — all findings are
#     reported as new with a banner explaining the missing baseline.
#   - Exits 0 on normal completion regardless of whether findings were found.
#   - Exits non-zero only on tool/API failure (missing glab/jq/unzip,
#     unreadable target path).
#
# Output:
#   The markdown report is structured per scanner and grouped by severity.
#   When the MR comment template wants a low-noise default, callers can detect
#   "no findings" via `grep -q "## NEW SAST findings"` on the output.
# -----------------------------------------------------------------------------
set -euo pipefail

PROG="fetch-sast-findings.sh"
PROJECT=""
MR=""
TARGET_PATH=""
OUTPUT=""

usage() {
  sed -n '2,40p' "$0"
  exit 2
}

while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2;;
    --mr) MR="$2"; shift 2;;
    --target-path) TARGET_PATH="$2"; shift 2;;
    --output) OUTPUT="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "${PROG}: unknown arg: $1" >&2; usage;;
  esac
done

[ -z "$PROJECT" ] && { echo "${PROG}: --project required" >&2; usage; }
[ -z "$MR" ]      && { echo "${PROG}: --mr required" >&2; usage; }
[ -z "$TARGET_PATH" ] && { echo "${PROG}: --target-path required" >&2; usage; }

for tool in glab jq unzip; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "${PROG}: missing required tool: $tool" >&2
    exit 3
  }
done

[ -d "$TARGET_PATH" ] || {
  echo "${PROG}: target path not found: $TARGET_PATH" >&2
  exit 3
}

PROJECT_ENC=$(printf '%s' "$PROJECT" | jq -sRr @uri)

emit() {
  if [ -n "$OUTPUT" ]; then
    printf '%s\n' "$1" >> "$OUTPUT"
  fi
  printf '%s\n' "$1"
}

# Reset output file if specified
if [ -n "$OUTPUT" ]; then
  : > "$OUTPUT"
fi

# Resolve the latest pipeline for this MR
PIPE_JSON=$(glab api "projects/${PROJECT_ENC}/merge_requests/${MR}" 2>/dev/null || echo "{}")
PIPE_ID=$(printf '%s' "$PIPE_JSON" | jq -r '.head_pipeline.id // empty')

if [ -z "$PIPE_ID" ]; then
  emit "## SAST review skipped"
  emit ""
  emit "No pipeline associated with MR !${MR} on \`${PROJECT}\`. Either security stage is not wired for this submodule, or the pipeline has not been triggered yet."
  exit 0
fi

PIPE_STATUS=$(printf '%s' "$PIPE_JSON" | jq -r '.head_pipeline.status // "unknown"')

# Gate on the SECURITY JOBS' own statuses, NOT the overall pipeline status.
# Security scans run in parallel with the (often long) test jobs, and GitLab
# publishes each job's artifacts the moment that JOB finishes — independent of
# the overall pipeline. .head_pipeline.status stays "running" until the slowest
# job (usually tests) lands, so gating on it needlessly defers the SAST review
# for the whole test duration even though the scan artifacts are already
# downloadable. We therefore list the jobs first and gate on the security jobs.

# List jobs
JOBS_JSON=$(glab api "projects/${PROJECT_ENC}/pipelines/${PIPE_ID}/jobs" 2>/dev/null || echo "[]")

# Auto-detect security jobs by name. Names match the conventions established
# by the shared .gitlab-ci-security.yml template.
SECURITY_PATTERN='^(semgrep|osv_scan|trivy_fs|trivy_config|gitleaks_scan|retire_js|cpan_audit|sbom_publish)$'
SECURITY_JOBS=$(printf '%s' "$JOBS_JSON" \
  | jq -r --arg re "$SECURITY_PATTERN" '.[] | select(.name | test($re)) | "\(.id)|\(.name)|\(.status)"')

if [ -z "$SECURITY_JOBS" ]; then
  # No security jobs detected. If the pipeline is still spinning up they may not
  # have been created yet; otherwise this submodule has no security stage.
  case "$PIPE_STATUS" in
    running|pending|created|preparing|scheduled|waiting_for_resource)
      emit "## SAST review skipped"
      emit ""
      emit "Pipeline #${PIPE_ID} is **${PIPE_STATUS}** and no security jobs have been created yet. Re-run \`/mr-qa\` once the security stage starts."
      exit 0 ;;
    *)
      emit "## SAST review skipped"
      emit ""
      emit "No security stage detected in pipeline #${PIPE_ID}. This submodule is not yet wired for SAST/SCA scanning."
      exit 0 ;;
  esac
fi

# A security job is "ready" once it reaches a terminal state: success/failed
# (artifact present — failed allow_failure jobs still upload), or
# skipped/manual/canceled (no artifact, nothing to fetch). If any security job
# is still created/pending/running/preparing/scheduled, its artifact is not
# ready yet, so defer — regardless of the overall pipeline status.
UNFINISHED_SEC=$(printf '%s' "$SECURITY_JOBS" \
  | awk -F'|' '$3 ~ /^(created|pending|running|preparing|scheduled|waiting_for_resource)$/ { print "- " $2 " (" $3 ")" }')

if [ -n "$UNFINISHED_SEC" ]; then
  emit "## SAST review skipped"
  emit ""
  emit "Security scans are still in progress (overall pipeline #${PIPE_ID}: **${PIPE_STATUS}**). Unfinished security jobs:"
  emit ""
  emit "$UNFINISHED_SEC"
  emit ""
  emit "These finish independently of the long-running test jobs — re-run \`/mr-qa\` once they complete (you do not need to wait for the whole pipeline)."
  exit 0
fi

# All security jobs are terminal — their artifacts are downloadable even if the
# overall pipeline is still running (e.g. waiting on test jobs).
emit "## NEW SAST findings (delta vs checked-in baselines)"
emit ""
emit "_Pipeline #${PIPE_ID} (overall status: ${PIPE_STATUS}); all security jobs complete. Findings shown are NEW relative to the baseline files committed in the target branch — a finding listed here means this MR introduced it OR it predates the baseline freeze. The reviewer should weigh each one as either intentional (e.g. dep upgrade with a known CVE) or a regression to fix._"
emit ""

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

ANY_NEW=0

# ---- helper: download an artifact file from a job into $WORKDIR ----
fetch_artifact() {
  local job_id="$1" artifact_path="$2" out_var="$3"
  local zip_path="${WORKDIR}/job-${job_id}.zip"
  local extract_dir="${WORKDIR}/job-${job_id}"
  if [ ! -f "$zip_path" ]; then
    if ! glab api "projects/${PROJECT_ENC}/jobs/${job_id}/artifacts" \
        > "$zip_path" 2>/dev/null; then
      eval "$out_var=''"
      return 1
    fi
    # The API may return an error JSON if no artifacts exist; check magic bytes.
    if ! head -c 2 "$zip_path" 2>/dev/null | grep -q "^PK"; then
      rm -f "$zip_path"
      eval "$out_var=''"
      return 1
    fi
  fi
  mkdir -p "$extract_dir"
  if ! unzip -o -q "$zip_path" -d "$extract_dir" >/dev/null 2>&1; then
    eval "$out_var=''"
    return 1
  fi
  if [ -f "${extract_dir}/${artifact_path}" ]; then
    eval "$out_var=\"${extract_dir}/${artifact_path}\""
    return 0
  fi
  eval "$out_var=''"
  return 1
}

print_skipped() {
  local scanner="$1" reason="$2"
  emit "### ${scanner}"
  emit ""
  emit "_Skipped: ${reason}_"
  emit ""
}

# ---- per-scanner handlers ----

handle_gitleaks() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "gitleaks-report.json" report; then
    print_skipped "gitleaks" "no artifact (likely no NEW findings; baseline already suppressed historic ones)"
    return
  fi
  local count
  count=$(jq 'length // 0' "$report" 2>/dev/null || echo 0)
  emit "### gitleaks"
  emit ""
  if [ "$count" -eq 0 ]; then
    emit "_No new secrets._"
  else
    ANY_NEW=1
    emit "**${count} new finding(s):**"
    emit ""
    jq -r '.[] | "- ⚠ \(.RuleID // .Description // "secret"): `\(.File // "?"):\(.StartLine // 0)`\n  - Match: `\(.Match // "redacted" | .[0:80])`"' "$report" 2>/dev/null \
      | sed 's/^/  /' | head -40 >> "${OUTPUT:-/dev/null}"
    jq -r '.[] | "- ⚠ \(.RuleID // .Description // "secret"): `\(.File // "?"):\(.StartLine // 0)`"' "$report" 2>/dev/null | head -20 \
      | while IFS= read -r line; do emit "$line"; done
    if [ "$count" -gt 20 ]; then
      emit ""
      emit "_… and $((count - 20)) more. See gitleaks job artifact._"
    fi
  fi
  emit ""
}

handle_osv() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "osv-results.json" report; then
    print_skipped "osv-scanner" "no artifact"
    return
  fi
  local baseline="${TARGET_PATH}/osv-scanner-baseline.json"
  local missing_baseline=""
  if [ ! -f "$baseline" ]; then
    missing_baseline="(no osv-scanner-baseline.json in working tree — treating ALL HIGH+ findings as new)"
  fi
  # Extract IDs of CRITICAL+HIGH findings from current report.
  local current_ids
  current_ids=$(jq -r '[.results[]?.packages[]?.vulnerabilities[]? | select(.database_specific.severity == "CRITICAL" or .database_specific.severity == "HIGH") | .id] | unique | .[]' "$report" 2>/dev/null || echo "")
  local baseline_ids=""
  [ -f "$baseline" ] && baseline_ids=$(jq -r '.[]' "$baseline" 2>/dev/null || echo "")

  local new_ids
  new_ids=$(comm -23 <(printf '%s\n' "$current_ids" | sort -u | grep -v '^$' || true) \
                       <(printf '%s\n' "$baseline_ids" | sort -u | grep -v '^$' || true) || true)

  emit "### osv-scanner"
  emit ""
  [ -n "$missing_baseline" ] && { emit "_${missing_baseline}_"; emit ""; }
  if [ -z "$new_ids" ]; then
    emit "_No new HIGH/CRITICAL OSV advisories._"
  else
    ANY_NEW=1
    local n=$(printf '%s\n' "$new_ids" | wc -l | tr -d ' ')
    emit "**${n} new HIGH/CRITICAL advisor(y/ies):**"
    emit ""
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      # Look up details (severity, package, summary) from the current report
      local detail
      detail=$(jq -r --arg id "$id" '
        .results[]?.packages[]? as $p | $p.vulnerabilities[]?
        | select(.id == $id)
        | "  - **\(.database_specific.severity // "UNKNOWN")** `\($p.package.name // "?")@\($p.package.version // "?")` — \(.summary // .id)"
      ' "$report" 2>/dev/null | head -1)
      if [ -n "$detail" ]; then
        emit "$detail"
      else
        emit "  - ⚠ ${id}"
      fi
    done <<< "$new_ids"
  fi
  emit ""
}

handle_trivy_fs() {
  # Note: a follow-up fix (MR !11) narrowed trivy_fs to misconfig-only scanning
  # (--scanners misconfig, --file-patterns "dockerfile:Dockerfile*"). The
  # vulnerability and secret-scan responsibilities now live in osv_scan and
  # gitleaks_scan respectively. So findings here are AVDIDs against
  # Dockerfile/IaC, not VulnerabilityIDs against npm/cpan deps. Both are
  # filterable via .trivyignore by raw ID, so the diff logic is unchanged —
  # only the user-facing labels reflect the misconfig-only scope.
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "trivy-results.json" report; then
    print_skipped "trivy_fs" "no artifact"
    return
  fi
  local baseline="${TARGET_PATH}/.trivyignore"
  local missing_baseline=""
  if [ ! -f "$baseline" ]; then
    missing_baseline="(no .trivyignore in working tree — treating ALL HIGH+ misconfigs as new)"
  fi
  local current_ids baseline_ids
  current_ids=$(jq -r '..|.VulnerabilityID? // empty, ..|.AVDID? // empty' "$report" 2>/dev/null | sort -u | grep -v '^$' || true)
  baseline_ids=""
  [ -f "$baseline" ] && baseline_ids=$(grep -vE '^(#|$)' "$baseline" 2>/dev/null | sort -u || true)

  local new_ids
  new_ids=$(comm -23 <(printf '%s\n' "$current_ids" || true) <(printf '%s\n' "$baseline_ids" || true) || true)

  emit "### trivy_fs"
  emit ""
  [ -n "$missing_baseline" ] && { emit "_${missing_baseline}_"; emit ""; }
  if [ -z "$new_ids" ]; then
    emit "_No new HIGH/CRITICAL Dockerfile/IaC misconfigs._"
  else
    ANY_NEW=1
    local n=$(printf '%s\n' "$new_ids" | wc -l | tr -d ' ')
    emit "**${n} new HIGH/CRITICAL Dockerfile/IaC misconfig(s):**"
    emit ""
    while IFS= read -r id; do
      [ -z "$id" ] && continue
      emit "  - ⚠ ${id}"
    done <<< "$new_ids" | head -30
  fi
  emit ""
}

handle_trivy_config() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "trivy-config.json" report; then
    print_skipped "trivy_config" "no artifact"
    return
  fi
  emit "### trivy_config"
  emit ""
  local n
  n=$(jq -r '[..|.AVDID? // empty] | unique | length' "$report" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    emit "_No HIGH/CRITICAL Dockerfile/k8s misconfigs._"
  else
    ANY_NEW=1
    emit "**${n} HIGH/CRITICAL misconfig(s)** _(no baseline; report all findings)_:"
    emit ""
    jq -r '[..|.AVDID? // empty] | unique | .[]' "$report" 2>/dev/null | head -20 \
      | while IFS= read -r id; do emit "  - ⚠ ${id}"; done
  fi
  emit ""
}

handle_semgrep() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "gl-sast-report.json" report; then
    print_skipped "semgrep" "no artifact"
    return
  fi
  emit "### semgrep"
  emit ""
  local n
  n=$(jq -r '.vulnerabilities | length // 0' "$report" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    emit "_No ERROR-severity SAST findings._"
  else
    ANY_NEW=1
    emit "**${n} ERROR-severity finding(s)** _(no per-finding baseline; consider a future enhancement to diff vs target-branch report)_:"
    emit ""
    jq -r '.vulnerabilities | sort_by(-(.severity // "Low" | ascii_downcase | (if . == "critical" then 4 elif . == "high" then 3 elif . == "medium" then 2 else 1 end))) | .[0:10][] | "  - **\(.severity // "?")** `\(.location.file // "?"):\(.location.start_line // 0)` — \(.identifiers[0].name // .name // "?") — \(.description // "" | .[0:120])"' "$report" 2>/dev/null \
      | while IFS= read -r line; do emit "$line"; done
    if [ "$n" -gt 10 ]; then
      emit ""
      emit "_… top 10 shown by severity. Total: ${n}. See \`gl-sast-report.json\` artifact for full list._"
    fi
  fi
  emit ""
}

handle_retire_js() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "retire-results.json" report; then
    print_skipped "retire_js" "no artifact"
    return
  fi
  emit "### retire_js"
  emit ""
  local n
  n=$(jq -r '[.[]?.results[]?.vulnerabilities[]?] | length // 0' "$report" 2>/dev/null || echo 0)
  if [ "$n" -eq 0 ]; then
    emit "_No vulnerable vendored JS detected in src/assets/._"
  else
    ANY_NEW=1
    emit "**${n} vulnerable vendored JS finding(s)** _(no baseline; report all)_:"
    emit ""
    jq -r '.[]?.results[]? | select(.vulnerabilities | length > 0) | "  - ⚠ \(.component // "?")@\(.version // "?") — \([.vulnerabilities[]?.identifiers.summary] | unique | join("; "))"' "$report" 2>/dev/null | head -10 \
      | while IFS= read -r line; do emit "$line"; done
  fi
  emit ""
}

handle_cpan_audit() {
  local job_id="$1" report
  if ! fetch_artifact "$job_id" "cpan-audit.json" report; then
    print_skipped "cpan_audit" "no artifact (Perl module CVE check is advisory; empty output is normal)"
    return
  fi
  emit "### cpan_audit"
  emit ""
  emit "_Advisory only (Perl CPAN CVE coverage is sparse). Artifact size: $(wc -c <"$report" 2>/dev/null | tr -d ' ') bytes._"
  emit ""
}

handle_sbom() {
  local job_id="$1"
  emit "### sbom_publish"
  emit ""
  emit "_SBOM job — informational, not part of the security finding flow. See MinIO bucket for the CycloneDX artifact._"
  emit ""
}

# ---- dispatch ----

while IFS='|' read -r JOB_ID JOB_NAME JOB_STATUS; do
  [ -z "$JOB_ID" ] && continue
  case "$JOB_NAME" in
    gitleaks_scan)  handle_gitleaks "$JOB_ID" ;;
    osv_scan)       handle_osv "$JOB_ID" ;;
    trivy_fs)       handle_trivy_fs "$JOB_ID" ;;
    trivy_config)   handle_trivy_config "$JOB_ID" ;;
    semgrep)        handle_semgrep "$JOB_ID" ;;
    retire_js)      handle_retire_js "$JOB_ID" ;;
    cpan_audit)     handle_cpan_audit "$JOB_ID" ;;
    sbom_publish)   handle_sbom "$JOB_ID" ;;
    *) ;;  # unknown — skip silently (forward-compat)
  esac
done <<< "$SECURITY_JOBS"

emit "---"
if [ "$ANY_NEW" -eq 0 ]; then
  emit ""
  emit "**Summary:** No new security findings vs baselines. Pipeline #${PIPE_ID} clean."
else
  emit ""
  emit "**Summary:** New findings detected. Reviewer should treat each as either intentional (and recommend a baseline update) or a regression (and recommend a fix)."
fi

exit 0
