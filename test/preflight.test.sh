#!/usr/bin/env bash
# preflight.test.sh — hermetic tests for preflight.sh.
#
# Run:  bash test/preflight.test.sh
# Exit: 0 all passed, 1 one or more failed.
#
# MUST be run with `bash` explicitly. The default interactive shell here is zsh,
# which does NOT word-split unquoted `$VAR` expansions — testing this script's
# logic under zsh produces false results (that already caused one false negative
# while QA'ing this file's own MR).
#
# ---------------------------------------------------------------------------
# DESIGN RULE — READ BEFORE ADDING A TEST
#
#   NEVER re-implement production logic inside this file and assert against the
#   copy. Drive the REAL preflight.sh and assert on what it emits.
#
# An earlier version of this suite defined its own `parse_url()` and its own
# `is_protected()` and tested those. It was 41/41 green while 7 of 8 deliberate
# breaks in the real script shipped undetected — reverting the real URL parser to
# its exact documented bug still passed. A test that asserts against a copy tests
# the copy. It is worse than no test, because it manufactures confidence.
#
# Every assertion below must be reachable from preflight.sh's real output:
#   - the URL parser        -> assert .gitlab_project
#   - is_protected          -> assert exit 4 on a protected source branch
#   - the SAST classifier   -> assert .sast.gate_state
#   - review_mode routing   -> assert .review_mode
# preflight.json IS still emitted on exit 3 and exit 4, so its fields remain
# assertable on the failure paths too.
#
# If you cannot observe a behaviour from the outside, that is a signal to give
# preflight a real seam — not a licence to test a copy.
# ---------------------------------------------------------------------------
#
# Hermetic: no network, no live GitLab, no real pipeline, no read of the real QA
# token. Each case builds a throwaway repo with a real `origin` (a local bare
# repo) plus stub `glab`/helpers on PATH. GIT_SSH_COMMAND=false and .invalid
# hosts guarantee that the URL-parser cases fail fast without touching DNS.

set -uo pipefail

SKILL_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd "$SKILL_SRC/.." && pwd)"
PREFLIGHT_SRC="$REPO_SRC/lib/preflight.sh"
DEFAULTS_SRC="$REPO_SRC/config/defaults.json"
SKILL_MD="$REPO_SRC/skills/qa-round/SKILL.md"

export GIT_SSH_COMMAND=false     # any ssh fetch dies instantly, never hits DNS
export GIT_TERMINAL_PROMPT=0     # never block on credentials

# Redirect preflight's scratch root into a throwaway dir. Without this the suite
# writes ~30 dirs per run into /tmp/mr-qa-* — the SAME namespace live QA runs
# use — so it both littered and could not safely clean up (it cannot tell its own
# dirs from a live round's). A trap that removed only the runs that emitted JSON
# leaked every crash-path fixture. The seam removes the problem instead of
# papering over it: one dir, removed wholesale, and no possible collision.
SUITE_TMP=$(mktemp -d)
export MR_QA_SCRATCH_ROOT="$SUITE_TMP"
trap 'rm -rf "$SUITE_TMP"' EXIT

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

note_scratch() { :; }   # retained as a no-op: isolation is handled by the seam above

# ---------------------------------------------------------------------------
# Fixture: the plugin and the repo under review are SEPARATE trees, which is the
# whole point of the extraction, so the fixture models that. preflight lives in
# $root/plugin; the work lives in $root/repo; the repo root is resolved from git
# (hence run_preflight cd's into the repo), never from the script's own path.
#   $1 source branch  $2 target branch  $3 jq filter over the PROJECT config
# ---------------------------------------------------------------------------
mkfixture() {
  local src_branch="${1:-feature/x}" tgt_branch="${2:-main}" bb_filter="${3:-.}"
  local root; root=$(mktemp -d)
  local repo="$root/repo" bare="$root/remote.git" bin="$root/bin"
  local plugin="$root/plugin"
  local proj_cfg="$repo/.claude/skills/qa-round/config.json"
  mkdir -p "$repo/.claude/skills/qa-round" "$bin" "$plugin/lib" "$plugin/config"

  git init -q --bare "$bare"
  git init -q -b "$tgt_branch" "$repo"
  git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
  git -C "$repo" remote add origin "$bare"

  cp "$PREFLIGHT_SRC" "$plugin/lib/preflight.sh"
  cp "$DEFAULTS_SRC"  "$plugin/config/defaults.json"

  # Project layer only. Credentials/policy would normally arrive from the user
  # layer; the fixture puts everything here so a case can rewrite one file.
  cat > "$proj_cfg" <<JSON
{
  "protected_branches": ["main","master","release_patches"],
  "review_mode": { "sequential_max_lines_changed": 50 },
  "qa_agent": {
    "token_env": "TEST_QA_TOKEN", "token_file": "/nonexistent",
    "expected_username": "qa-bot",
    "approval": { "min_clean_round": 2, "tiny_mr_relax_to_round_1": true, "tiny_mr_max_lines_changed": 50 }
  },
  "schema": { "files": ["db/template.sql"] },
  "targets": { "mono": { "path": ".", "base_branch": "$tgt_branch", "remote": "origin", "scope": "mono", "security_stage": false } }
}
JSON
  [ "$bb_filter" = "." ] || {
    jq "$bb_filter" "$proj_cfg" > "$proj_cfg.tmp" && mv "$proj_cfg.tmp" "$proj_cfg"
  }

  # Stub SAST helper. Bodies below are compared against the real helper's emit()
  # strings by the [stub fidelity] block — if the real helper's wording changes,
  # that block fails and these stubs must be updated.
  cat > "$plugin/lib/fetch-sast-findings.sh" <<'SH'
#!/usr/bin/env bash
out=""; while [ $# -gt 0 ]; do [ "$1" = "--output" ] && out="$2"; shift; done
[ -n "${SAST_STUB_EXIT:-}" ] && [ "$SAST_STUB_EXIT" != "0" ] && { echo "stub helper failure" >&2; exit "$SAST_STUB_EXIT"; }
printf '%s\n' "${SAST_STUB_BODY:-## NEW SAST findings}" > "$out"
exit 0
SH
  chmod +x "$plugin/lib/"*.sh

  echo base > "$repo/base.txt"
  git -C "$repo" add -A >/dev/null; git -C "$repo" commit -qm base
  git -C "$repo" push -q origin "$tgt_branch"
  git -C "$repo" checkout -q -b "$src_branch"

  # The stub honours env vars so a case can steer identity, the MR title/desc
  # (contract extraction), and the approval list (approval seeding) without
  # rebuilding the fixture:
  #   GLAB_STUB_USER      -> the logged-in dev user (ownership)
  #   GLAB_STUB_TITLE     -> MR title  (title_ticket / candidate_tickets)
  #   GLAB_STUB_DESC      -> MR description (description_length / candidates)
  #   GLAB_STUB_APPROVER  -> a username to place in approval_state (MR_APPROVED seed)
  #   GLAB_STUB_NOTES     -> raw JSON array for the notes endpoint (round derivation)
  #   GLAB_STUB_NOTES_EXIT-> non-zero to make the notes probe FAIL (round_probe_failed)
  cat > "$bin/glab" <<SH
#!/usr/bin/env bash
case "\$*" in
  *"auth status"*)  echo "Logged in to gitlab.com as \${GLAB_STUB_USER:-devuser}" >&2 ;;
  *"mr view"*)      jq -nc --arg s "$src_branch" --arg t "$tgt_branch" \
                      --arg title "\${GLAB_STUB_TITLE:-t}" --arg desc "\${GLAB_STUB_DESC:-d}" \
                      '{title:\$title,author:{username:"devuser"},source_branch:\$s,target_branch:\$t,state:"opened",draft:false,changes_count:"1",description:\$desc,head_pipeline:{status:"success"}}' ;;
  *approval_state*) if [ -n "\${GLAB_STUB_APPROVER:-}" ]; then
                      jq -nc --arg u "\$GLAB_STUB_APPROVER" '{rules:[],approved_by:[{user:{username:\$u}}]}'
                    else echo '{"rules":[],"approved_by":[]}'; fi ;;
  *notes*)          if [ -n "\${GLAB_STUB_NOTES_EXIT:-}" ] && [ "\${GLAB_STUB_NOTES_EXIT}" != "0" ]; then
                      echo "stub notes failure" >&2; exit "\${GLAB_STUB_NOTES_EXIT}"
                    fi
                    printf '%s' "\${GLAB_STUB_NOTES:-[]}" ;;
  *)                echo '{}' ;;
esac
exit 0
SH
  chmod +x "$bin/glab"
  printf '%s\n' "$root"
}

# preflight resolves the repo root from git now, so it must be RUN FROM INSIDE the
# repo; the plugin lives outside that tree entirely. The subshell keeps the cd from
# leaking into the suite.
run_preflight() { local root="$1"; shift; ( cd "$root/repo" && PATH="$root/bin:$PATH" bash "$root/plugin/lib/preflight.sh" "$@" 2>/dev/null ); }

commit_lines() { local i=0; : > "$1/$3"; while [ "$i" -lt "$2" ]; do echo "line $i" >> "$1/$3"; i=$((i+1)); done
  git -C "$1" add -A >/dev/null; git -C "$1" commit -qm "add $2 lines"; }

echo "preflight.sh tests"

# ---------------------------------------------------------------------------
echo "[exit 2 — operator-fixable usage/config errors]"
r=$(mkfixture); run_preflight "$r" >/dev/null; eq "no args -> 2" "$?" "2"
run_preflight "$r" 73 >/dev/null;        eq "missing target -> 2" "$?" "2"
run_preflight "$r" 73 nosuch >/dev/null; eq "unknown target -> 2" "$?" "2"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[exit 4 — hard sync stop]"
# (a) protected source branch. This drives the REAL is_protected(): a copy of the
# function inside this file would prove nothing about the shipped script.
for b in main master release_patches; do
  r=$(mkfixture "$b" "some-target")
  out=$(run_preflight "$r" 73 mono); rc=$?
  note_scratch "$out"
  eq "protected source '$b' -> exit 4" "$rc" "4"
  eq "  sync.failed=true"              "$(jq -r '.sync.failed' <<<"$out")" "true"
  eq "  reason names the refusal"      "$(jq -r '.sync.reason|test("protected")' <<<"$out")" "true"
  rm -rf "$r"
done
# (b) an unprotected branch is NOT refused — proves the guard discriminates
# rather than blanket-failing.
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); rc=$?
note_scratch "$out"; eq "unprotected source -> exit 0" "$rc" "0"
eq "  sync.failed=false" "$(jq -r '.sync.failed' <<<"$out")" "false"
rm -rf "$r"
# (c) source branch == the MR's own target branch is refused even if not listed.
r=$(mkfixture "not-listed" "not-listed"); out=$(run_preflight "$r" 73 mono); rc=$?
note_scratch "$out"; eq "source == target branch -> exit 4" "$rc" "4"
rm -rf "$r"
# (d) unreachable remote -> fetch fails.
r=$(mkfixture "feature/x" "main")
git -C "$r/repo" remote set-url origin /nonexistent/nope.git
out=$(run_preflight "$r" 73 mono); rc=$?
note_scratch "$out"; eq "broken remote -> exit 4" "$rc" "4"
eq "  reason mentions fetch" "$(jq -r '.sync.reason|test("fetch")' <<<"$out")" "true"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[exit 3 — deletions gate fires BEFORE the push, and suppresses it]"
# Regression lock: the gate used to be evaluated AFTER the push it gates, so the
# operator was asked about a merge already published. Assert the remote ref is
# byte-identical after an exit-3 run.
r=$(mkfixture "feature/x" "main")
commit_lines "$r/repo" 100 big.txt                    # big file on the feature branch
git -C "$r/repo" push -q origin feature/x
git -C "$r/repo" checkout -q main
git -C "$r/repo" merge -q feature/x                   # main gets big.txt too
git -C "$r/repo" rm -q big.txt; git -C "$r/repo" commit -qm "main deletes big.txt"
git -C "$r/repo" push -q origin main                  # base deleted it: the sync will too
git -C "$r/repo" checkout -q feature/x
echo tiny > "$r/repo/tiny.txt"; git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm tiny
git -C "$r/repo" push -q origin feature/x
before=$(git -C "$r/repo" rev-parse origin/feature/x)
out=$(run_preflight "$r" 73 mono); rc=$?
note_scratch "$out"
after=$(git -C "$r/repo" ls-remote origin refs/heads/feature/x | awk '{print $1}')
eq "net-negative sync merge -> exit 3" "$rc" "3"
eq "  unexpected_deletions=true"       "$(jq -r '.sync.unexpected_deletions' <<<"$out")" "true"
eq "  warns"                           "$(jq -r '.warnings|index("unexpected_deletions")!=null' <<<"$out")" "true"
eq "  sync.pushed=false"               "$(jq -r '.sync.pushed' <<<"$out")" "false"
eq "  REMOTE UNCHANGED (gate precedes push)" "$after" "$before"
eq "  deleted_files lists the casualty" "$(jq -r '.sync.deleted_files|index("big.txt")!=null' <<<"$out")" "true"
eq "  sync.reason is populated"         "$(jq -r '.sync.reason|length>0' <<<"$out")" "true"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[scope vs diff_scope — the duplicate-key regression]"
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "scope is the registry STRING"       "$(jq -r '.scope|type' <<<"$out")" "string"
eq "scope value"                        "$(jq -r '.scope' <<<"$out")" "mono"
eq "diff_scope is an object"            "$(jq -r '.diff_scope|type' <<<"$out")" "object"
eq "diff_scope.total_changed is number" "$(jq -r '.diff_scope.total_changed|type' <<<"$out")" "number"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[review_mode routing]"
r=$(mkfixture "feature/x" "main"); commit_lines "$r/repo" 10 big.txt
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "10 lines -> sequential" "$(jq -r '.review_mode' <<<"$out")" "sequential"; rm -rf "$r"
r=$(mkfixture "feature/x" "main"); commit_lines "$r/repo" 200 big.txt
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "200 lines -> manager" "$(jq -r '.review_mode' <<<"$out")" "manager"; rm -rf "$r"
# Fallback: with .review_mode absent, SEQ_MAX must fall back to the APPROVAL knob.
# Set that knob to 500 so the fallback is OBSERVABLE: 200 lines <= 500 -> sequential.
# The previous version asserted "manager" here, which is also the default answer —
# it passed with the fallback deleted, i.e. it tested nothing.
r=$(mkfixture "feature/x" "main" 'del(.review_mode) | .qa_agent.approval.tiny_mr_max_lines_changed = 500')
commit_lines "$r/repo" 200 big.txt
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "no .review_mode + approval knob 500 -> falls back -> sequential" "$(jq -r '.review_mode' <<<"$out")" "sequential"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[remote-URL parser — via the REAL script's emitted .gitlab_project]"
# Drives preflight's own parser. Hosts are .invalid and GIT_SSH_COMMAND=false, so
# the fetch dies instantly with no DNS; preflight still emits preflight.json on
# the exit-4 path, so .gitlab_project remains assertable.
url_case() {
  local r; r=$(mkfixture "feature/x" "main")
  git -C "$r/repo" remote set-url origin "$2"
  local out; out=$(run_preflight "$r" 73 mono); note_scratch "$out"
  eq "$1" "$(jq -r '.gitlab_project // "<none>"' <<<"$out")" "$3"
  rm -rf "$r"
}
url_case "scp-style + .git"   'git@host.invalid:grp/proj.git'       'grp/proj'
url_case "ssh alias, no .git" 'gitalias:grp/proj'                  'grp/proj'
url_case "https + .git"       'https://host.invalid/grp/proj.git'   'grp/proj'
url_case "https, no .git"     'https://host.invalid/grp/proj'       'grp/proj'
url_case "nested subgroups"   'git@host.invalid:a/b/c/proj.git'     'a/b/c/proj'
url_case "ssh:// with path"   'ssh://git@host.invalid/a/b/proj.git' 'a/b/proj'
# A URL with no group/project path must die loudly (exit 2), not silently pass
# the whole URL through as the "project" — the old parser's actual failure mode.
r=$(mkfixture "feature/x" "main"); git -C "$r/repo" remote set-url origin 'notaurl'
run_preflight "$r" 73 mono >/dev/null; eq "unparseable remote -> exit 2" "$?" "2"; rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[SAST classifier — every helper exit-0 path]"
sast_case() { # $1 label, $2 stub body, $3 expected gate_state, $4 expected running
  local r; r=$(mkfixture "feature/x" "main" '.targets.mono.security_stage = true')
  local out; out=$(SAST_STUB_BODY="$2" run_preflight "$r" 73 mono); note_scratch "$out"
  eq "$1 -> $3" "$(jq -r '.sast.gate_state' <<<"$out")" "$3"
  [ -n "${4:-}" ] && eq "  running=$4" "$(jq -r '.sast.running' <<<"$out")" "$4"
  rm -rf "$r"
}
sast_case "finished delta"    '## NEW SAST findings' 'clean' 'false'
sast_case "no security stage" '## SAST review skipped

No security stage detected in pipeline #1.' 'skipped:no-stage' 'false'
sast_case "no pipeline yet"   '## SAST review skipped

No pipeline associated with MR !73 on `x/y`.' 'skipped:no-pipeline' 'true'
sast_case "jobs in progress"  '## SAST review skipped

Security scans are still in progress (overall pipeline #1: **canceled**).' 'skipped:pipeline-running' 'true'
# The RUNNING_MARKER_RE path: the helper's OTHER waitable stub carries only a
# **status** marker and none of the classifier's sentences. Neutering
# RUNNING_MARKER_RE must fail this case.
sast_case "marker-only running stub" '## SAST review skipped

Pipeline #1 is **running** and no security jobs have been created yet.' 'skipped:pipeline-running' 'true'
sast_case "unrecognized stub" 'something the helper never says' 'skipped:unknown' 'false'

echo "[SAST helper failure is surfaced, never swallowed]"
r=$(mkfixture "feature/x" "main" '.targets.mono.security_stage = true')
out=$(SAST_STUB_EXIT=3 run_preflight "$r" 73 mono); note_scratch "$out"
eq "helper non-zero -> skipped:helper-failed" "$(jq -r '.sast.gate_state' <<<"$out")" "skipped:helper-failed"
eq "  warns sast_helper_failed"               "$(jq -r '.warnings|index("sast_helper_failed")!=null' <<<"$out")" "true"
eq "  helper_reason captured"                 "$(jq -r '.sast.helper_reason|length>0' <<<"$out")" "true"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[stub fidelity — the stubs above must match the REAL helper's wording]"
# The SAST cases are only meaningful if the stub bodies say what the real helper
# says. Pin each classifier sentence to the real script.
HELPER="$REPO_SRC/lib/fetch-sast-findings.sh"
if [ -f "$HELPER" ]; then
  for phrase in "No pipeline associated with MR" "No security stage detected" \
                "Security scans are still in progress" "## NEW SAST findings"; do
    if grep -qF -- "$phrase" "$HELPER"; then ok "real helper emits: $phrase"
    else bad "real helper emits: $phrase" "not found in $HELPER — stubs are stale, SAST cases prove nothing"; fi
  done
else
  bad "fetch-sast-findings.sh present" "not found at $HELPER"
fi

# ---------------------------------------------------------------------------
echo "[schema-change scan — the CONFIGURED schema file(s)]"
# One path check against schema.files. The scan used to also glob sql/ and *.sql
# AND scan diff CONTENT for DDL keywords, which matched test fixtures, comments and
# test labels, so a zero-SQL change armed the human-approval gate over a printf
# string. A path check cannot match a comment: the false positive is impossible by
# construction, not guarded against. See docs/CASE-STUDIES.md #schema-drift.
# The fixture configures schema.files = ["db/template.sql"].
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/repo/db"
printf -- '-- the schema\n' > "$r/repo/db/template.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "touch the schema"
out=$(run_preflight "$r" 73 mono)
eq "configured schema file changed -> detected" "$(jq -r '.schema.detected' <<<"$out")" "true"
eq "  schema.state=checked"                     "$(jq -r '.schema.state' <<<"$out")" "checked"
rm -rf "$r"
# Nested path shape: a monorepo target sees apps/api/db/template.sql while the
# component target sees db/template.sql. Both must match the same config entry.
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/repo/apps/api/db"
printf -- '-- the schema\n' > "$r/repo/apps/api/db/template.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "touch the schema (nested)"
out=$(run_preflight "$r" 73 mono)
eq "nested configured schema path -> detected" "$(jq -r '.schema.detected' <<<"$out")" "true"
rm -rf "$r"
# An UNCONFIGURED gate must report that it did not run -- never a clean pass.
r=$(mkfixture "feature/x" "main" 'del(.schema)'); mkdir -p "$r/repo/db"
printf -- '-- the schema\n' > "$r/repo/db/template.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "schema change, gate unconfigured"
out=$(run_preflight "$r" 73 mono)
eq "no schema.files -> state=skipped:not-configured" "$(jq -r '.schema.state' <<<"$out")" "skipped:not-configured"
eq "  and detected stays false"                      "$(jq -r '.schema.detected' <<<"$out")" "false"
rm -rf "$r"
# Everything that is NOT the schema file must NOT trip it — these are the false
# positives the old content scan produced.
schema_neg() { # $1 label, $2 relative path, $3 file body
  local r; r=$(mkfixture "feature/x" "main")
  mkdir -p "$(dirname "$r/repo/$2")"; printf '%s\n' "$3" > "$r/repo/$2"
  git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "$1"
  local out; out=$(run_preflight "$r" 73 mono)
  eq "$1 -> schema.detected=false" "$(jq -r '.schema.detected' <<<"$out")" "false"
  rm -rf "$r"
}
schema_neg "plain code change"          "app.js"            "console.log(1)"
schema_neg "a different .sql file"      "sql/legacy.sql"    "-- not the configured schema"
schema_neg "an sql/ artifact subdir"    "sql/alters/001.sql" "-- historical artifact"
# THE case that motivated the rewrite: literal DDL in a shell/test file is NOT a
# schema change. Assembled at runtime only so this suite does not carry a literal
# that would confuse a human reader into thinking it matters — the scanner no
# longer looks at content at all.
schema_neg "literal DDL in a shell file" "runner.sh" "$(printf 'mysql -e "%s %s beacons ADD %s foo INT;"' ALTER TABLE COLUMN)"
schema_neg "DDL in a code comment"       "code.pl"   "$(printf '# e.g. %s %s widgets (id INT);' CREATE TABLE)"
# The same basename in a different directory is NOT the configured schema file.
schema_neg "same basename, wrong dir"   "other/template.sql" "-- decoy"
# RENAMING the schema file is a change to it. This needs --no-renames: with
# rename detection on, git prints ONLY the destination path (R098 ->
# `db/renamed.sql`), the grep misses the source, and a real DDL change ships with
# the gate un-armed.
# TWO fixture requirements, both learned the hard way:
#  1. the schema file must exist on the BASE branch — seeding it on the feature
#     branch makes the diff vs base just "renamed.sql added", with no rename to
#     detect, so the case passes for the wrong reason.
#  2. it must be big enough for git's similarity detection to fire (>=50%), or
#     git reports D+A instead of R and the bug hides.
seed_schema_on_base() { # $1 fixture root, $2 base branch, $3 body-generator cmd
  git -C "$1/repo" checkout -q "$2"
  mkdir -p "$1/repo/db"; eval "$3" > "$1/repo/db/template.sql"
  git -C "$1/repo" add -A >/dev/null; git -C "$1/repo" commit -qm "seed schema on base"
  git -C "$1/repo" push -q origin "$2"
  git -C "$1/repo" checkout -q feature/x
  git -C "$1/repo" merge -q "$2" -m merge
}
r=$(mkfixture "feature/x" "main")
seed_schema_on_base "$r" main 'for i in $(seq 1 200); do echo "-- schema line $i"; done'
git -C "$r/repo" mv db/template.sql db/renamed.sql
printf '%s TABLE t1 ADD %s newcol INT;\n' ALTER COLUMN >> "$r/repo/db/renamed.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "rename the schema file"
out=$(run_preflight "$r" 73 mono)
eq "renaming the schema file -> schema.detected=true" "$(jq -r '.schema.detected' <<<"$out")" "true"
rm -rf "$r"
# Deleting it is also a change to it.
r=$(mkfixture "feature/x" "main")
seed_schema_on_base "$r" main 'printf -- "-- schema\n"'
git -C "$r/repo" rm -q db/template.sql; git -C "$r/repo" commit -qm "delete the schema file"
out=$(run_preflight "$r" 73 mono)
eq "deleting the schema file -> schema.detected=true" "$(jq -r '.schema.detected' <<<"$out")" "true"
rm -rf "$r"

echo "[docs_only detection]"
r=$(mkfixture "feature/x" "main"); printf '# doc\n' > "$r/repo/README.md"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "docs"
out=$(run_preflight "$r" 73 mono)
eq "only a .md changed -> docs_only=true" "$(jq -r '.docs_only' <<<"$out")" "true"
rm -rf "$r"
r=$(mkfixture "feature/x" "main"); printf 'code\n' > "$r/repo/app.js"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "code"
out=$(run_preflight "$r" 73 mono)
eq "a code file changed -> docs_only=false" "$(jq -r '.docs_only' <<<"$out")" "false"
rm -rf "$r"

echo "[QA-token verify seeds qa_token_ok]"
# expected_username in the fixture is qa-bot; the auth stub reports
# devuser, so the token must NOT verify. This locks that qa_token_ok reflects a
# real identity match, not a hardwired true.
r=$(mkfixture "feature/x" "main")
out=$(TEST_QA_TOKEN=sometoken run_preflight "$r" 73 mono)
eq "token resolves but identity mismatch -> qa_token_ok=false" "$(jq -r '.qa_token_ok' <<<"$out")" "false"
rm -rf "$r"
# Identity match -> true. Point expected_username at the stub's reported user.
r=$(mkfixture "feature/x" "main" '.qa_agent.expected_username = "devuser"')
out=$(TEST_QA_TOKEN=sometoken run_preflight "$r" 73 mono)
eq "token + identity match -> qa_token_ok=true" "$(jq -r '.qa_token_ok' <<<"$out")" "true"
rm -rf "$r"

echo "[approval seeding — MR_APPROVED from GitLab, -F literal match]"
# Only meaningful when the QA token verifies, so use the devuser-expected fixture.
r=$(mkfixture "feature/x" "main" '.qa_agent.expected_username = "devuser"')
out=$(TEST_QA_TOKEN=sometoken GLAB_STUB_APPROVER=devuser run_preflight "$r" 73 mono)
eq "QA agent in approver list -> mr_approved=true" "$(jq -r '.mr_approved' <<<"$out")" "true"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.qa_agent.expected_username = "devuser"')
out=$(TEST_QA_TOKEN=sometoken GLAB_STUB_APPROVER=someone.else run_preflight "$r" 73 mono)
eq "someone else approved -> mr_approved=false" "$(jq -r '.mr_approved' <<<"$out")" "false"
rm -rf "$r"
# F-3 lock: the approval grep is -qxF. A username that is a REGEX SUBSTRING of the
# expected one must NOT count as a match. Set expected=dev.user (has a regex '.')
# and approve as devXuser: with -qxF this is no match; drop -F and '.' matches 'X'.
r=$(mkfixture "feature/x" "main" '.qa_agent.expected_username = "dev.user"')
out=$(TEST_QA_TOKEN=sometoken GLAB_STUB_USER=dev.user GLAB_STUB_APPROVER=devXuser run_preflight "$r" 73 mono)
eq "regex-metachar username: devXuser != dev.user (grep -F)" "$(jq -r '.mr_approved' <<<"$out")" "false"
rm -rf "$r"

echo "[contract ticket extraction]"
r=$(mkfixture "feature/x" "main")
out=$(GLAB_STUB_TITLE='PROJ-1234 fix the thing' run_preflight "$r" 73 mono)
eq "ticket in title -> title_ticket"        "$(jq -r '.contract.title_ticket' <<<"$out")" "PROJ-1234"
eq "  candidate_tickets includes it"        "$(jq -r '.contract.candidate_tickets|index("PROJ-1234")!=null' <<<"$out")" "true"
rm -rf "$r"
# Blocklist: HTTP-400 / SHA-256 / CVE-2024 look like tickets but must be dropped.
r=$(mkfixture "feature/x" "main")
out=$(GLAB_STUB_TITLE='handle HTTP-400 and CVE-2024 in SHA-256 path' run_preflight "$r" 73 mono)
eq "blocklisted non-tickets -> no candidates" "$(jq -r '.contract.candidate_tickets|length' <<<"$out")" "0"
eq "  title_ticket empty"                     "$(jq -r '.contract.title_ticket' <<<"$out")" ""
rm -rf "$r"
r=$(mkfixture "feature/x" "main")
DESC_FIXTURE='a longer description here'
out=$(GLAB_STUB_DESC="$DESC_FIXTURE" run_preflight "$r" 73 mono)
# Assert against the computed length, not a hand-counted literal (I miscounted it
# as 24 the first time — a hardcoded expectation is its own small trap).
eq "description_length is the real byte length" "$(jq -r '.contract.description_length' <<<"$out")" "${#DESC_FIXTURE}"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[lens selection — deterministic lenses[] array]"
# The core three always run; conditional lenses come from lens_tags + the live
# schema signal; cap 6, priority schema>api>ui>perf. Drive the REAL selector and
# assert the emitted .lenses.
lenses_of() { jq -r '.lenses | join(",")' ; }   # stdin: preflight.json
# monorepo-shaped target (no tags, no DDL) -> exactly the core three. This is the
# !73 fix: no dead schema lens, test-quality included.
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono)
eq "no tags, no DDL -> core three only" "$(lenses_of <<<"$out")" "contract-security,regression-edges,test-quality"
rm -rf "$r"
# Touching the schema file adds the lens, regardless of lens_tags.
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/repo/db"
printf -- '-- the schema\n' > "$r/repo/db/template.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm "touch the schema"
out=$(run_preflight "$r" 73 mono)
eq "schema file changed -> +schema-propagation" "$(jq -r '.lenses|index("schema-propagation")!=null' <<<"$out")" "true"
eq "  and schema.detected=true"                 "$(jq -r '.schema.detected' <<<"$out")" "true"
rm -rf "$r"
# ...and NOT touching it does not, even with SQL-ish files in the diff. This is
# the case that motivated deleting the DDL content scan.
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/repo/sql"
printf -- '-- historical artifact, not the schema\n' > "$r/repo/sql/legacy.sql"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm sqlfile
out=$(run_preflight "$r" 73 mono)
eq "other .sql file -> NO schema-propagation" "$(jq -r '.lenses|index("schema-propagation")' <<<"$out")" "null"
rm -rf "$r"
# A schema-tagged target gets schema-propagation WITHOUT any DDL (the code-only
# code-only-dependency case).
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["schema"]'); commit_lines "$r/repo" 5 plain.txt
out=$(run_preflight "$r" 73 mono)
eq "schema TAG, no DDL -> +schema-propagation" "$(jq -r '.lenses|index("schema-propagation")!=null' <<<"$out")" "true"
eq "  schema NOT detected in diff"            "$(jq -r '.schema.detected' <<<"$out")" "false"
rm -rf "$r"
# api / ui tags add their lenses.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["api"]'); commit_lines "$r/repo" 5 f.txt
out=$(run_preflight "$r" 73 mono)
eq "api tag -> +api-envelope" "$(jq -r '.lenses|index("api-envelope")!=null' <<<"$out")" "true"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["ui"]'); commit_lines "$r/repo" 5 f.txt
out=$(run_preflight "$r" 73 mono)
eq "ui tag -> +ui-styling" "$(jq -r '.lenses|index("ui-styling")!=null' <<<"$out")" "true"
rm -rf "$r"
# perf is suppressed on a docs-only MR (only a .md changed), present otherwise.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["perf"]'); printf '# d\n' > "$r/repo/README.md"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm docs
out=$(run_preflight "$r" 73 mono)
eq "perf tag + docs-only -> NO performance lens" "$(jq -r '.lenses|index("performance")' <<<"$out")" "null"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["perf"]'); commit_lines "$r/repo" 5 code.js
out=$(run_preflight "$r" 73 mono)
eq "perf tag + code change -> +performance" "$(jq -r '.lenses|index("performance")!=null' <<<"$out")" "true"
rm -rf "$r"
# Cap + priority: all four conditional qualify -> drop the lowest (perf), keep 6.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["schema","api","ui","perf"]')
# The schema lens here comes from the `schema` lens_tag on line above — NOT
# from any file content. Use a plain file: an sql/ artifact is provably inert
# under the one-file rule (see the schema_neg cases), and seeding DDL here would
# imply diff content arms the flag, which is the misconception this MR removes.
echo plain > "$r/repo/f.txt"
git -C "$r/repo" add -A >/dev/null; git -C "$r/repo" commit -qm ddl
out=$(run_preflight "$r" 73 mono)
eq "over-cap -> exactly 6 lenses"        "$(jq -r '.lenses|length' <<<"$out")" "6"
eq "  perf dropped (lowest priority)"    "$(jq -r '.lenses|index("performance")' <<<"$out")" "null"
eq "  schema/api/ui all kept"            "$(jq -r '[.lenses[]|select(.=="schema-propagation" or .=="api-envelope" or .=="ui-styling")]|length' <<<"$out")" "3"
rm -rf "$r"

echo "[lens_tags validation — config errors must not fail open]"
# A scalar instead of an array, or a typo'd tag, used to degrade SILENTLY to the
# core three while still emitting a valid lenses array — so neither the shape
# assertion nor the enum whitelist could catch it. One typo would drop rest-api
# from 6 lenses to 3, losing the very lens the schema tag exists for.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = "schema"')   # scalar, not array
run_preflight "$r" 73 mono >/dev/null; eq "lens_tags scalar -> exit 2 (not silent core-3)" "$?" "2"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = {"a":1}')    # object
run_preflight "$r" 73 mono >/dev/null; eq "lens_tags object -> exit 2" "$?" "2"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" 'del(.targets.mono.lens_tags)')          # absent is LEGITIMATE
out=$(run_preflight "$r" 73 mono); rc=$?
eq "lens_tags absent -> exit 0 (legitimate)" "$rc" "0"
eq "  -> core three"                         "$(lenses_of <<<"$out")" "contract-security,regression-edges,test-quality"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = null')        # explicit null == absent
run_preflight "$r" 73 mono >/dev/null; eq "lens_tags null -> exit 0" "$?" "0"
rm -rf "$r"
# An unknown tag is a typo: run, but WARN — never silently inert.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["schemas","perf"]'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono); rc=$?
eq "unknown tag -> still exit 0"        "$rc" "0"
eq "  warns unknown_lens_tags"          "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags"))]|length>0' <<<"$out")" "true"
eq "  names the offending tag"          "$(jq -r '.warnings|join(",")|test("schemas")' <<<"$out")" "true"
eq "  valid tags still honoured"        "$(jq -r '.lenses|index("performance")!=null' <<<"$out")" "true"
rm -rf "$r"
# A tag value containing a NEWLINE is one malformed element, not two valid tags.
# ASSERT .lenses — the EFFECT — not just the warning. The first version of this
# case checked only that a warning existed and rc==0, so it shipped green while
# BOTH api-envelope and ui-styling were still enabled off the one bad value: the
# fix had moved validation into jq but left selection reading the split text, and
# this test was blind to exactly that axis. A case that locks the REPORTING of a
# defect but not its EFFECT is the design rule at the top of this file failing in
# a new costume — it manufactures confidence. The adjacent unknown-tag case
# already asserted .lenses; this one simply had to do the same.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["api\nui"]'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono); rc=$?
eq "newline inside a tag -> reported as unknown" "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags"))]|length>0' <<<"$out")" "true"
eq "  and INERT: enables no lens"                "$(lenses_of <<<"$out")" "contract-security,regression-edges,test-quality"
eq "  specifically not api-envelope"             "$(jq -r '.lenses|index("api-envelope")' <<<"$out")" "null"
eq "  specifically not ui-styling"               "$(jq -r '.lenses|index("ui-styling")' <<<"$out")" "null"
eq "  still exit 0 (warn, not fatal)"            "$rc" "0"
eq "  warning is ONE element, not smeared"       "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags"))]|length' <<<"$out")" "1"
eq "  no contextless orphan warning"             "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags")|not)|select(test("^(api|ui)$"))]|length' <<<"$out")" "0"
rm -rf "$r"
# A TRAILING newline must not sneak through: jq's Oniguruma `$` matches before a
# trailing newline, so `^(...)$` accepted "api\n" as a valid tag. \A…\z does not.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["api\n"]'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "trailing-newline tag -> reported as unknown" "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags"))]|length>0' <<<"$out")" "true"
eq "  and INERT: no api-envelope"                "$(jq -r '.lenses|index("api-envelope")' <<<"$out")" "null"
rm -rf "$r"
# Control: the well-formed equivalent DOES enable both — proves the cases above
# fail for the right reason (malformed-ness) and not because the tags never work.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["api","ui"]'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "control: well-formed [api,ui] DOES enable both" \
   "$(jq -r '[.lenses[]|select(.=="api-envelope" or .=="ui-styling")]|length' <<<"$out")" "2"
eq "  and warns nothing"                         "$(jq -r '[.warnings[]|select(startswith("unknown_lens_tags"))]|length' <<<"$out")" "0"
rm -rf "$r"
# A non-string element is a config error, not a tag.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["api", 42]')
run_preflight "$r" 73 mono >/dev/null; eq "non-string tag element -> exit 2" "$?" "2"
rm -rf "$r"

echo "[lens priority ORDER is locked, not just the selected set]"
# Regression lock: a pure priority reorder (api above schema) preserved the set
# and shipped green, because every other case asserts membership/length only.
r=$(mkfixture "feature/x" "main" '.targets.mono.lens_tags = ["schema","api","ui"]'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "conditional order is schema,api,ui (priority)" \
   "$(jq -r '[.lenses[]|select(.=="schema-propagation" or .=="api-envelope" or .=="ui-styling")]|join(",")' <<<"$out")" \
   "schema-propagation,api-envelope,ui-styling"
eq "  core lenses come first" "$(jq -r '.lenses[0:3]|join(",")' <<<"$out")" "contract-security,regression-edges,test-quality"
rm -rf "$r"

echo "[shipped defaults and examples are structurally valid]"
# The old form of this block asserted one organisation's target list. That registry
# is now PROJECT config, so there is nothing shipped to lock -- but the concern it
# encoded is still real: shipped data that nothing exercises rots silently. Re-aimed
# at what this repo actually ships, which users copy verbatim: the defaults and the
# examples must parse, and every lens_tag in them must be one preflight understands.
# A typo'd tag in an example is a user-facing bug -- preflight rejects it at parse
# time, so the example would fail on first run.
BB_REAL="$REPO_SRC/config/defaults.json"
for f in "$BB_REAL" "$REPO_SRC/examples/"*.json; do
  if jq empty "$f" 2>/dev/null; then ok "  parses: $(basename "$f")"
  else bad "  parses: $(basename "$f")" "invalid JSON"; fi
done
# lens_tags must be an ARRAY everywhere. A scalar silently disables every
# conditional lens for that target (preflight validates this and dies; a shipped
# example that trips it would be a broken template).
for f in "$BB_REAL" "$REPO_SRC/examples/"*.json; do
  nonarray=$(jq -r '[.targets // {} | to_entries[] | select(.value.lens_tags != null and (.value.lens_tags|type) != "array") | .key] | join(",")' "$f")
  eq "  lens_tags all arrays: $(basename "$f")" "${nonarray:-none}" "none"
done
# Every tag in the shipped file must be one preflight actually understands.
# EXTRACT the vocabulary from preflight.sh — do not restate it here. A hardcoded
# copy drifts: widen preflight's tag set and this check keeps rejecting the new
# tag, or narrow it and this check keeps accepting a dead one. Same reason the
# lens enum is extracted rather than pasted.
TAGS_RE=$(grep -oE "KNOWN_LENS_TAGS_RE='[^']+'" "$PREFLIGHT_SRC" | head -1 | sed -E "s/^KNOWN_LENS_TAGS_RE='//; s/'$//")
if [ -z "$TAGS_RE" ]; then
  bad "  tag vocabulary extracted from preflight.sh" "extraction returned nothing — update the extractor, do NOT paste a copy"
else
  ok "  tag vocabulary extracted from preflight.sh (not a hardcoded copy)"
  bad_tags=$(jq -r --arg re "$TAGS_RE" '[.targets[].lens_tags[]?] | unique | map(select(test($re) | not)) | join(",")' "$BB_REAL")
  if [ -z "$bad_tags" ]; then ok "  no unknown tags in the shipped registry"
  else bad "  no unknown tags in the shipped registry" "found: $bad_tags"; fi
fi

echo "[lens enum <-> mr-qa-manager catalog agreement]"
# The !73 precedent: a fix added two SAST gate_states to the producer but not its
# consumer, hard-exiting a routine clean round. Same producer/consumer shape here
# — preflight's enum is the producer, the manager's catalog is the consumer.
MANAGER_MD="$REPO_SRC/agents/qa-manager.md"
if [ -f "$MANAGER_MD" ]; then
  enum=$(grep -oE '\^\(contract-security\|[a-z|-]+\)\$' "$PREFLIGHT_SRC" | head -1 \
    | sed -E 's/^\^\((.*)\)\$$/\1/' | tr '|' '\n' | sort -u)
  catalog=$(grep -oE '^- \*\*[a-z-]+\*\*' "$MANAGER_MD" | sed -E 's/^- \*\*([a-z-]+)\*\*/\1/' | sort -u)
  if [ -z "$enum" ]; then bad "lens enum extracted from preflight" "regex found nothing — update the test"
  elif [ -z "$catalog" ]; then bad "lens catalog extracted from mr-qa-manager.md" "found nothing — update the test"
  elif [ "$enum" = "$catalog" ]; then ok "preflight lens enum == mr-qa-manager catalog"
  else bad "preflight lens enum == mr-qa-manager catalog" "$(diff <(echo "$enum") <(echo "$catalog") | tr '\n' ' ')"; fi
else
  bad "mr-qa-manager.md present" "not found at $MANAGER_MD"
fi

# ---------------------------------------------------------------------------
echo "[producer/consumer enum agreement]"
# Regression lock: a fix added two gate_states to the producer + its assertion but
# not to SKILL.md's Step 3E whitelist, so a routine clean round hard-exited 7.
# Extract each list independently and compare as sets.
producer=$(grep -oE 'SAST_GATE_STATE="(clean|skipped:[a-z-]+)"' "$PREFLIGHT_SRC" \
  | sed -E 's/SAST_GATE_STATE="([^"]+)"/\1/' | sort -u)
assertion=$(grep -oE '\^\(clean\|skipped:\([a-z|-]+\)\)\$' "$PREFLIGHT_SRC" | head -1 \
  | sed -E 's/.*skipped:\(([a-z|-]+)\).*/\1/' | tr '|' '\n' | sed 's/^/skipped:/' | sort -u)
assertion=$(printf 'clean\n%s\n' "$assertion" | sort -u)
# Pull the Step 3E case arm by ANCHORING ON THE CASE STATEMENT, not on an
# expected shape. The old grep required the line to start with `clean|`, so a
# gate_state added out of that shape was invisible to the check that exists to
# catch exactly that drift.
consumer=$(awk '/case "\$\{SAST_GATE_STATE:-\}" in/{f=1;next} f&&/\)[[:space:]]*;;/{print;exit}' "$SKILL_MD" \
  | sed -E 's/\)[[:space:]]*;;.*//' | tr -d ' ' | tr '|' '\n' | grep . | sort -u)
if [ -z "$consumer" ]; then bad "Step 3E case arm found in SKILL.md" "extraction returned nothing"
elif [ "$producer" = "$consumer" ]; then ok "producer set == SKILL.md Step 3E whitelist"
else bad "producer set == SKILL.md Step 3E whitelist" "$(diff <(echo "$producer") <(echo "$consumer") | tr '\n' ' ')"; fi
if [ "$assertion" = "$producer" ]; then ok "producer set == preflight self-assertion"
else bad "producer set == preflight self-assertion" "$(diff <(echo "$producer") <(echo "$assertion") | tr '\n' ' ')"; fi

# ---------------------------------------------------------------------------
echo "[self-assertion fails closed -> exit 5, nothing emitted]"
r=$(mkfixture "feature/x" "main")
pf="$r/plugin/lib/preflight.sh"
sed -i.bak 's/^    remote: \$remote, scope: \$scope,$/    remote: $remote, scope: { broken: true },/' "$pf"
if grep -q 'scope: { broken: true }' "$pf"; then
  # Must run from INSIDE the repo: preflight resolves its root from git now.
  out=$( cd "$r/repo" && PATH="$r/bin:$PATH" bash "$pf" 73 mono 2>/dev/null ); rc=$?
  eq "corrupted scope -> exit 5 (internal, not usage)" "$rc" "5"
  # Real assertion, replacing an unconditional ok() that could not fail: nothing
  # may reach stdout, because die_internal fires before the tee.
  eq "  emitted nothing (refused before tee)" "$([ -z "$out" ] && echo empty || echo "non-empty")" "empty"
else
  bad "self-assertion test" "could not patch the emitter — test needs updating"
fi
rm -rf "$r"

echo "[hermetic — the suite writes nothing into the shared /tmp namespace]"
# Regression lock for the leak: with MR_QA_SCRATCH_ROOT honoured, every scratch
# dir lands under $SUITE_TMP. If a change ever hardcodes /tmp again, the count
# below goes to 0 and this fails.
n_here=$(ls -d "$SUITE_TMP"/mr-qa-* 2>/dev/null | grep -c . || true)
if [ "${n_here:-0}" -gt 0 ]; then ok "scratch dirs land under the suite's own tmp root ($n_here)"
else bad "scratch dirs land under the suite's own tmp root" "found none under $SUITE_TMP — is MR_QA_SCRATCH_ROOT still honoured?"; fi

echo "[scratch-root that cannot be created -> exit 5, not a silent 0]"
# Locks the mkdir guard: an unwritable/uncreatable MR_QA_SCRATCH_ROOT must be one
# clear internal failure, never a silent exit 0 that leaves downstream steps
# tripping over a missing preflight.json. Point the seam at a path whose parent
# is a FILE, so mkdir -p cannot succeed.
r=$(mkfixture "feature/x" "main")
blocker=$(mktemp); : > "$blocker"    # a regular file
out=$(MR_QA_SCRATCH_ROOT="$blocker/cannot" run_preflight "$r" 73 mono); rc=$?
eq "uncreatable scratch root -> exit 5" "$rc" "5"
eq "  emitted no JSON to stdout"        "$([ -z "$out" ] && echo empty || echo non-empty)" "empty"
rm -f "$blocker"; rm -rf "$r"

echo "[round derivation + proportionality tier]"
# These three paths shipped unexercised: hardcoding round=1, suppressing
# proportionality.md, and INVERTING the tier all left the suite green. Each
# assertion below is reachable from preflight's real output (.round, the file at
# .proportionality_path, .warnings) — no logic is re-implemented here.

# (a) round derives from the max posted "## QA Round N" heading, + 1. Notes are
# deliberately out of order so a max is proven rather than a last-wins.
r=$(mkfixture "feature/x" "main")
notes='[{"body":"## QA Round 1\nfindings"},{"body":"## QA Round 3\nfindings"},{"body":"## QA Round 2\nfindings"},{"body":"unrelated comment"}]'
out=$(GLAB_STUB_NOTES="$notes" run_preflight "$r" 73 mono)
eq "3 posted rounds -> round 4" "$(jq -r '.round' <<<"$out")" "4"
prop=$(jq -r '.proportionality_path' <<<"$out")
eq "  proportionality.md is non-empty" "$([ -s "$prop" ] && echo yes || echo no)" "yes"
eq "  round 4 renders the STRICT tier" \
   "$(grep -qi 'apply the above strictly' "$prop" && echo yes || echo no)" "yes"
rm -rf "$r"

# (b) no notes -> round 1 and the LIGHT tier. Pairs with (a): together they prove
# the tier tracks the round, so an inverted comparison fails one of the two.
r=$(mkfixture "feature/x" "main")
out=$(GLAB_STUB_NOTES='[]' run_preflight "$r" 73 mono)
eq "no notes -> round 1" "$(jq -r '.round' <<<"$out")" "1"
prop=$(jq -r '.proportionality_path' <<<"$out")
eq "  round 1 is non-empty too"        "$([ -s "$prop" ] && echo yes || echo no)" "yes"
eq "  round 1 renders the LIGHT tier"  \
   "$(grep -qi 'apply the above strictly' "$prop" && echo yes || echo no)" "no"
rm -rf "$r"

# (b2) the boundary itself. (a) proves round 4 is strict and (b) proves round 1 is
# light, but every threshold in 2..4 satisfies both — so the `>= 3` constant was the
# one number the suite did not pin (a `>= 4` mutation survived). Round 2 light +
# round 3 strict is the adjacent pair that fixes it to exactly 3.
r=$(mkfixture "feature/x" "main")
out=$(GLAB_STUB_NOTES='[{"body":"## QA Round 1\nx"}]' run_preflight "$r" 73 mono)
eq "1 posted round -> round 2" "$(jq -r '.round' <<<"$out")" "2"
eq "  round 2 is still LIGHT" \
   "$(grep -qi 'apply the above strictly' "$(jq -r '.proportionality_path' <<<"$out")" && echo yes || echo no)" "no"
out=$(GLAB_STUB_NOTES='[{"body":"## QA Round 1\nx"},{"body":"## QA Round 2\nx"}]' run_preflight "$r" 73 mono)
eq "2 posted rounds -> round 3" "$(jq -r '.round' <<<"$out")" "3"
eq "  round 3 is the first STRICT round" \
   "$(grep -qi 'apply the above strictly' "$(jq -r '.proportionality_path' <<<"$out")" && echo yes || echo no)" "yes"
rm -rf "$r"

# (b3) the round stamp must match .round. This is what makes "the tier is a function
# of the round at emit time" checkable: a caller that bumps the round without
# re-rendering leaves a file whose stamp disagrees with the round it is used for.
r=$(mkfixture "feature/x" "main")
for n in 1 3; do
  notes='[]'; [ "$n" = 3 ] && notes='[{"body":"## QA Round 1\nx"},{"body":"## QA Round 2\nx"}]'
  out=$(GLAB_STUB_NOTES="$notes" run_preflight "$r" 73 mono)
  eq "round $n stamp matches .round" \
     "$(grep -oE 'rendered for round [0-9]+' "$(jq -r '.proportionality_path' <<<"$out")" | grep -oE '[0-9]+')" \
     "$(jq -r '.round' <<<"$out")"
done
rm -rf "$r"

# (c) a FAILED notes probe must not masquerade as "no notes yet". Round still
# falls back to 1, but the caller is warned that the number is untrustworthy.
r=$(mkfixture "feature/x" "main")
out=$(GLAB_STUB_NOTES_EXIT=22 run_preflight "$r" 73 mono)
eq "failed notes probe -> still exit 0" "$?" "0"
eq "  round falls back to 1"            "$(jq -r '.round' <<<"$out")" "1"
eq "  warns round_probe_failed" \
   "$(jq -r '[.warnings[]?|select(startswith("round_probe_failed"))]|length' <<<"$out")" "1"
rm -rf "$r"

echo "[dead Workflow machinery stays deleted]"
if grep -q 'workflows_supported\|WORKFLOWS_SUPPORTED' "$PREFLIGHT_SRC"; then
  bad "preflight emits no workflows_supported" "the skill does not use the Workflow tool; this is dead weight"
else ok "preflight emits no workflows_supported"; fi
if [ -e "$SKILL_SRC/detect-workflows-support.sh" ]; then
  bad "detect-workflows-support.sh is gone" "still present"
else ok "detect-workflows-support.sh is gone"; fi

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
