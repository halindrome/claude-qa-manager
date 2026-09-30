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
RUNPANEL_SRC="$REPO_SRC/lib/run-panel.sh"
DEFAULTS_SRC="$REPO_SRC/config/defaults.json"
SKILL_MD="$REPO_SRC/skills/qa-cycle/SKILL.md"

export GIT_SSH_COMMAND=false     # any ssh fetch dies instantly, never hits DNS
export GIT_TERMINAL_PROMPT=0     # never block on credentials

# Redirect preflight's scratch root into a throwaway dir. Without this the suite
# writes ~30 dirs per run into /tmp/qa-cycle-* — the SAME namespace live QA runs
# use — so it both littered and could not safely clean up (it cannot tell its own
# dirs from a live round's). A trap that removed only the runs that emitted JSON
# leaked every crash-path fixture. The seam removes the problem instead of
# papering over it: one dir, removed wholesale, and no possible collision.
SUITE_TMP=$(mktemp -d)
export QA_CYCLE_SCRATCH_ROOT="$SUITE_TMP"

# A fixture's "remote" is a local bare repo, so it has no host for forge_detect
# to sniff. QA_FORGE is the production escape hatch for exactly that blind spot
# (self-hosted GitLab / GitHub Enterprise), used here for the same reason.
# The URL-parser block below unsets it where it asserts the sniffing itself.
export QA_FORGE=gitlab
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
  local proj_cfg="$repo/.claude/skills/qa-cycle/config.json"
  mkdir -p "$repo/.claude/skills/qa-cycle" "$bin" "$plugin/lib" "$plugin/config"

  git init -q --bare "$bare"
  git init -q -b "$tgt_branch" "$repo"
  git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
  git -C "$repo" remote add origin "$bare"

  cp "$PREFLIGHT_SRC" "$plugin/lib/preflight.sh"
  cp "$DEFAULTS_SRC"  "$plugin/config/defaults.json"
  # The REAL forge seam, not a stub: preflight reaches the forge only through
  # these, so stubbing them would re-implement production logic in the test —
  # the exact failure documented in this file's header. The `glab` binary on
  # $PATH is what gets stubbed instead, one layer lower.
  cp "$REPO_SRC/lib/forge.sh" "$REPO_SRC/lib/forge-gitlab.sh" "$REPO_SRC/lib/forge-github.sh" "$plugin/lib/"
  # Likewise the REAL verify detector: preflight shells out to it, and a stub here
  # would assert against a copy of the logic instead of the logic.
  cp "$REPO_SRC/lib/detect-verify.sh" "$plugin/lib/"

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
  cat > "$plugin/lib/fetch-sast-gitlab.sh" <<'SH'
#!/usr/bin/env bash
out=""; tp=""
while [ $# -gt 0 ]; do
  [ "$1" = "--output" ] && out="$2"
  [ "$1" = "--target-path" ] && tp="$2"
  shift
done
# Record what the helper was HANDED, and whether it could actually see it.
[ -n "${SAST_TP_LOG:-}" ] && printf '%s\n%s\n' "$tp" "$( [ -d "$tp" ] && echo resolvable || echo UNRESOLVABLE )" > "$SAST_TP_LOG"
# Mirror the real helper's FIRST ACT: `[ -d "$TARGET_PATH" ] || exit 3`
# (fetch-sast-gitlab.sh:74-77). Without this the stub happily scans a path it
# cannot see, and the "gate is not helper-failed" assertion passes even with the
# bug reinstated — a stub that is more forgiving than the real thing turns its
# own test vacuous. Caught by the red-first run: only 2 of 4 assertions went red.
[ -n "$tp" ] && [ ! -d "$tp" ] && { echo "stub: target path not found: $tp" >&2; exit 3; }
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

  # gh stub — the GitHub counterpart, emitting GITHUB's native shape so that
  # forge-github.sh's normalization is what the assertions actually exercise.
  # Stubbing the normalized shape here instead would re-implement the mapping in
  # the test and assert against the copy: 41/41 green while the real mapping is
  # broken. That is the failure this file's header exists to warn about.
  #   GH_STUB_USER      -> the authenticated login (ownership)
  #   GH_STUB_APPROVER  -> a login to place in the reviews list (MR_APPROVED seed)
  #   GH_STUB_NOTES     -> raw JSON array for the issue-comments endpoint
  #   GH_STUB_NOTES_EXIT-> non-zero to make the notes probe FAIL
  #   GH_STUB_ENVLOG    -> a path; every invocation appends the GH_REPO it saw.
  #                        Inert unless set, so it costs the other cases nothing.
  cat > "$bin/gh" <<SH
#!/usr/bin/env bash
if [ -n "\${GH_STUB_ENVLOG:-}" ]; then
  printf 'GH_REPO=%s\n' "\${GH_REPO:-<unset>}" >> "\${GH_STUB_ENVLOG}"
fi
case "\$*" in
  *"api user"*)     printf '%s' "\${GH_STUB_USER:-devuser}" ;;
  *"pr view"*)      jq -nc --arg s "$src_branch" --arg t "$tgt_branch" \
                      --arg title "\${GH_STUB_TITLE:-t}" --arg body "\${GH_STUB_DESC:-d}" \
                      '{title:\$title,author:{login:"devuser"},headRefName:\$s,baseRefName:\$t,state:"OPEN",isDraft:false,changedFiles:1,statusCheckRollup:[{conclusion:"SUCCESS"}],body:\$body}' ;;
  *"/reviews"*)     if [ -n "\${GH_STUB_APPROVER:-}" ]; then
                      jq -nc --arg u "\$GH_STUB_APPROVER" '[{user:{login:\$u},state:"APPROVED",submitted_at:"2026-01-01T00:00:00Z"}]'
                    else echo '[]'; fi ;;
  *"/comments"*)    if [ -n "\${GH_STUB_NOTES_EXIT:-}" ] && [ "\${GH_STUB_NOTES_EXIT}" != "0" ]; then
                      echo "stub notes failure" >&2; exit "\${GH_STUB_NOTES_EXIT}"
                    fi
                    printf '%s' "\${GH_STUB_NOTES:-[]}" ;;
  *)                echo '{}' ;;
esac
exit 0
SH
  chmod +x "$bin/gh"
  printf '%s\n' "$root"
}

# preflight resolves the repo root from git now, so it must be RUN FROM INSIDE the
# repo; the plugin lives outside that tree entirely. The subshell keeps the cd from
# leaking into the suite.
# HOME is overridden because preflight merges a USER config layer from
# $HOME/.config/claude-qa-manager/config.json. Without this, a developer's real
# user config merges into every fixture and the suite is not hermetic: it would
# pass or fail differently on their machine than in CI.
#
# CLAUDE_CONFIG_DIR must be pinned for the SAME reason and is NOT covered by HOME:
# the CMM/Context-Mode probe reads "${CLAUDE_CONFIG_DIR:-$HOME/.config/claude-code}",
# so an inherited CLAUDE_CONFIG_DIR points the probe straight back at the developer's
# real plugin cache and `tooling.cmm_available` becomes a property of the machine
# running the suite. Pinning HOME alone left that hole open — verified, not assumed.
# CLAUDE_PLUGIN_ROOT / CLAUDE_PROJECT_DIR are unset for the same reason: the probe
# walks CLAUDE_PLUGIN_ROOT up to a plugins/cache root, so an inherited value points
# it at the DEVELOPER'S real plugin cache. That is both a hermeticity leak and a
# performance cliff — a maxdepth-7 find over a populated cache, twice per run, on
# every fixture, took the suite from seconds to minutes.
run_preflight() { local root="$1"; shift; ( cd "$root/repo" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$root/home" CLAUDE_CONFIG_DIR="$root/home/.config/claude-code" PATH="$root/bin:$PATH" bash "$root/plugin/lib/preflight.sh" "$@" 2>/dev/null ); }

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
# The fix mandate is what Step 3B reads before editing code. Its whole purpose is
# that it is NEVER empty: the fixer must always know whether "no other call sites"
# is a graph answer or merely the absence of a regex match. An empty file here is
# the absent-check-reports-as-pass failure, so assert both regimes.
#
# CMM availability is driven by the fixture repo's own .mcp.json — reachable only
# because run_preflight pins HOME, so the probe cannot see the developer's real
# Claude config and decide this test's outcome for it.
echo "[fix mandate — emitted in both tooling regimes]"
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
fm=$(jq -r '.tooling.fix_mandate_path' <<<"$out")
eq "fix_mandate_path is emitted"        "$( [ -n "$fm" ] && [ "$fm" != "null" ] && echo yes || echo no )" "yes"
eq "  distinct from tool-mandate.md"    "$( [ "$fm" != "$(jq -r '.tooling.mandate_path' <<<"$out")" ] && echo yes || echo no )" "yes"
eq "  NO cmm -> file still non-empty"   "$( [ -s "$fm" ] && echo yes || echo no )" "yes"
eq "  and names the weaker regime"      "$(grep -q 'TEXT SEARCH' "$fm" && echo yes || echo no)" "yes"
eq "  and forbids an exhaustive claim"  "$(grep -q 'best-effort' "$fm" && echo yes || echo no)" "yes"
eq "  cmm_available false"              "$(jq -r '.tooling.cmm_available' <<<"$out")" "false"
# Test-run capture. Step 3B is the only participant that runs the suite, and the
# exit-status-through-a-pipe defect turns a NEGATIVE CONTROL into a silent pass —
# the run whose entire purpose is to fail reports success. Both regimes must name
# it; neither may leave the section out.
eq "  NO ctx -> shell capture regime"   "$(grep -q 'PIPESTATUS' "$fm" && echo yes || echo no)" "yes"
eq "  and forbids status via a pipe"    "$(grep -qi 'never through a pipe' "$fm" && echo yes || echo no)" "yes"
eq "  and does NOT mandate ctx_execute" "$(grep -q 'ctx_execute' "$fm" && echo yes || echo no)" "no"
eq "  ctx_available false"              "$(jq -r '.tooling.ctx_available' <<<"$out")" "false"
# Authoring rules are regime-INDEPENDENT: both were paid for on one MR, and neither
# depends on which tools are registered. A coverage-only test has no fix to revert,
# so the red-first check passes for free — that exemption is where the surviving
# defects landed. A partial read of a cloned precedent fails just as silently.
eq "  names the coverage-test case"     "$(grep -q 'coverage-only test' "$fm" && echo yes || echo no)" "yes"
eq "  and says mutate the code"         "$(grep -q 'Mutate the code under' "$fm" && echo yes || echo no)" "yes"
eq "  and demands the whole precedent"  "$(grep -q 'whole precedent' "$fm" && echo yes || echo no)" "yes"
rm -rf "$r"

# Same fixture, but with CMM registered in the repo's own .mcp.json.
r=$(mkfixture "feature/x" "main")
echo '{"mcpServers":{"codebase-memory-mcp":{"command":"x"}}}' > "$r/repo/.mcp.json"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
fm=$(jq -r '.tooling.fix_mandate_path' <<<"$out")
eq "cmm registered -> cmm_available"    "$(jq -r '.tooling.cmm_available' <<<"$out")" "true"
eq "  graph regime mandates trace_path" "$(grep -q 'trace_path' "$fm" && echo yes || echo no)" "yes"
# The freshness gate is the invariant this file exists to protect: a stale index
# answers with the callers of the PRE-MR code and reports no other sites.
eq "  and gates on index freshness"     "$(grep -q 'detect_changes' "$fm" && echo yes || echo no)" "yes"
eq "  and keeps the non-graph residue"  "$(grep -q 'search_code' "$fm" && echo yes || echo no)" "yes"
eq "  and does NOT claim text-only"     "$(grep -q 'TEXT SEARCH' "$fm" && echo yes || echo no)" "no"
rm -rf "$r"

# Same fixture with CONTEXT MODE registered. The fix step runs suites through
# ctx_execute payloads, where the no-truncation rule is advisory — no hook enforces
# it inside a sandbox payload, unlike plain Bash. One measured session showed 11
# truncating payloads against 1 truncating Bash call, so the mandate has to carry
# the rule itself rather than lean on the enforcer.
r=$(mkfixture "feature/x" "main")
echo '{"mcpServers":{"context-mode":{"command":"x"}}}' > "$r/repo/.mcp.json"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
fm=$(jq -r '.tooling.fix_mandate_path' <<<"$out")
eq "ctx registered -> ctx_available"    "$(jq -r '.tooling.ctx_available' <<<"$out")" "true"
eq "  ctx regime mandates ctx_execute"  "$(grep -q 'ctx_execute' "$fm" && echo yes || echo no)" "yes"
eq "  and forbids truncating the run"   "$(grep -q 'Never truncate' "$fm" && echo yes || echo no)" "yes"
eq "  and names the tail idiom"         "$(grep -q 'tail' "$fm" && echo yes || echo no)" "yes"
eq "  and says nothing enforces it"     "$(grep -q 'sandbox payload' "$fm" && echo yes || echo no)" "yes"
eq "  and drops the shell fallback"     "$(grep -q 'PIPESTATUS' "$fm" && echo yes || echo no)" "no"
# The authoring rules must NOT be inside the ctx branch — they hold in both regimes.
eq "  keeps the authoring rules"        "$(grep -q 'whole precedent' "$fm" && echo yes || echo no)" "yes"
# tool-mandate.md is the LENS prompt, and this is the wall-clock rule. One `find /`
# hung 1807s, was killed by the client timeout, took its batch's other four commands
# with it, and cost 30 of a 45-minute round while the other five lenses sat finished.
# The merge is barrier-joined, so one lens's stall is the round's. `-maxdepth` is not
# the fix: the retry used `find / -maxdepth 8` and still cost 3 minutes.
tm=$(jq -r '.tooling.mandate_path' <<<"$out")
eq "  lens mandate bans scanning /"     "$(grep -q 'Never scan outside the repository' "$tm" && echo yes || echo no)" "yes"
eq "  and rejects -maxdepth as the fix" "$(grep -q 'or without \`-maxdepth\`' "$tm" && echo yes || echo no)" "yes"
eq "  and gives the resolver instead"   "$(grep -q 'require.resolve' "$tm" && echo yes || echo no)" "yes"
# The ToolSearch bootstrap line listed the five CMM tool names unconditionally, so a
# ctx-only session was told to load five tools it does not have and none of the ones
# it does. The list has to follow the regime that was actually detected.
eq "  ctx-only bootstrap loads ctx"     "$(grep -c 'select:[^\"]*ctx_execute' "$tm")" "1"
eq "  and does not name graph tools"    "$(grep -c 'select:[^\"]*search_graph' "$tm")" "0"
rm -rf "$r"

# ---------------------------------------------------------------------------
# Tooling discovery. `env -u` is required, not decorative: an inherited
# CLAUDE_CONFIG_DIR would point the probe at the developer's real config and make
# the legacy-root case pass for the wrong reason.
run_preflight_nocfg() { local root="$1"; shift; ( cd "$root/repo" && env -u CLAUDE_CONFIG_DIR -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR HOME="$root/home" PATH="$root/bin:$PATH" bash "$root/plugin/lib/preflight.sh" "$@" 2>/dev/null ); }
mkplugincache() { # $1 = config root, $2 = plugin name; versioned nesting on purpose
  local d="$1/plugins/cache/mkt/$2/1.2.3/.claude-plugin"
  mkdir -p "$d"; printf '{"name": "%s", "version": "1.2.3"}\n' "$2" > "$d/plugin.json"
}

echo "[tooling probe — config roots, project roots, enabled vs disabled]"
# THE regression: ~/.claude is the legacy default and holds a plugin-form install.
# The previous probe resolved a single root as ${CLAUDE_CONFIG_DIR:-~/.config/claude-code}
# with no existence check, so it scanned a directory that does not exist and
# reported the graph as unavailable — which now also makes fix-mandate.md print
# the text-search-only regime while a real index sits there.
r=$(mkfixture "feature/x" "main"); mkplugincache "$r/home/.claude" "codebase-memory-mcp"
out=$(run_preflight_nocfg "$r" 73 mono); note_scratch "$out"
eq "legacy ~/.claude plugin cache found"  "$(jq -r '.tooling.cmm_available' <<<"$out")" "true"
eq "  and fix mandate uses graph regime"  "$(grep -q 'trace_path' "$(jq -r '.tooling.fix_mandate_path' <<<"$out")" && echo yes || echo no)" "yes"
rm -rf "$r"

# A DISABLED plugin must not read as available. The old substring grep matched the
# key regardless of its value, so the mandate asserted a graph that was not loaded.
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/home/.claude"
echo '{"enabledPlugins":{"codebase-memory-mcp@mkt":false}}' > "$r/home/.claude/settings.json"
out=$(run_preflight_nocfg "$r" 73 mono); note_scratch "$out"
eq "enabledPlugins:false -> unavailable"  "$(jq -r '.tooling.cmm_available' <<<"$out")" "false"
echo '{"enabledPlugins":{"codebase-memory-mcp@mkt":true}}' > "$r/home/.claude/settings.json"
out=$(run_preflight_nocfg "$r" 73 mono); note_scratch "$out"
eq "enabledPlugins:true  -> available"    "$(jq -r '.tooling.cmm_available' <<<"$out")" "true"
rm -rf "$r"

# settings.local.json is a registration site in its own right.
r=$(mkfixture "feature/x" "main"); mkdir -p "$r/home/.config/claude-code"
echo '{"mcpServers":{"context-mode":{"command":"x"}}}' > "$r/home/.config/claude-code/settings.local.json"
out=$(run_preflight_nocfg "$r" 73 mono); note_scratch "$out"
eq "XDG root settings.local.json counts"  "$(jq -r '.tooling.ctx_available' <<<"$out")" "true"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[concurrent rounds on ONE working tree are refused]"
# Two rounds on one target share a tree: A checks out branch-A, B checks out
# branch-B in the same directory, and A's lenses then review B's code while A's fix
# commit lands on B's branch. Nothing downstream catches it — each round has its
# own scratch dir and believes it is isolated.
r=$(mkfixture "feature/x" "main")
tabs=$(jq -r '.target_abs' <<<"$(run_preflight "$r" 73 mono)")
sroot2=$(mktemp -d); mkdir -p "$sroot2/qa-cycle-other-99"
printf '99|mono|1|lenses|2|6|%s|%s|1200\n' "$(date +%s)" "$tabs" > "$sroot2/qa-cycle-other-99/status"
out=$(QA_CYCLE_SCRATCH_ROOT="$sroot2" run_preflight "$r" 73 mono 2>&1); rc=$?
eq "live round on same tree -> exit 2" "$rc" "2"
# The guard keys on the PATH, so the two legitimate ways to parallelise still work:
# a different target, and worktree isolation (same target, different checkout).
printf '99|mono|1|lenses|2|6|%s|/somewhere/else/worktree|1200\n' "$(date +%s)" > "$sroot2/qa-cycle-other-99/status"
QA_CYCLE_SCRATCH_ROOT="$sroot2" run_preflight "$r" 73 mono >/dev/null 2>&1
eq "different path -> allowed"         "$?" "0"
# A finished round must not hold the tree hostage...
printf '99|mono|1|done|6|6|%s|%s|1200\n' "$(date +%s)" "$tabs" > "$sroot2/qa-cycle-other-99/status"
QA_CYCLE_SCRATCH_ROOT="$sroot2" run_preflight "$r" 73 mono >/dev/null 2>&1
eq "finished round -> allowed"         "$?" "0"
# ...nor must an abandoned one leave a lock nobody knows to delete.
printf '99|mono|1|lenses|2|6|%s|%s|60\n' "$(date +%s)" "$tabs" > "$sroot2/qa-cycle-other-99/status"
oldl=$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)
touch -t "$oldl" "$sroot2/qa-cycle-other-99/status"
QA_CYCLE_SCRATCH_ROOT="$sroot2" run_preflight "$r" 73 mono >/dev/null 2>&1
eq "stale round ages out -> allowed"   "$?" "0"
# The escape hatch exists, but is not the default.
printf '99|mono|1|lenses|2|6|%s|%s|1200\n' "$(date +%s)" "$tabs" > "$sroot2/qa-cycle-other-99/status"
QA_ALLOW_CONCURRENT=1 QA_CYCLE_SCRATCH_ROOT="$sroot2" run_preflight "$r" 73 mono >/dev/null 2>&1
eq "QA_ALLOW_CONCURRENT bypasses"      "$?" "0"
rm -rf "$sroot2" "$r"

# ---------------------------------------------------------------------------
echo "[round progress — a stalled panel must not look like a working one]"
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
st=$(jq -r '.status_path' <<<"$out")
eq "status_path emitted"          "$( [ -s "$st" ] && echo yes || echo no )" "yes"
eq "  seeded at phase=preflight"  "$(cut -d'|' -f4 "$st")" "preflight"
eq "  carries mr/target/round"    "$(cut -d'|' -f1,2,3 "$st")" "73|mono|1"
eq "  lens total matches panel"   "$(cut -d'|' -f6 "$st")" "$(jq -r '.lenses|length' <<<"$out")"
eq "  and reaches the brief"      "$(grep -c '^status_path=' "$(jq -r '.manager_brief_path' <<<"$out")")" "1"

# The fragment: silent when idle, alive vs stalled, silent when done.
FRAG="$REPO_SRC/lib/statusline-fragment.sh"
sroot=$(mktemp -d)
eq "no round -> prints nothing"   "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | wc -c | tr -d ' ')" "0"
mkdir -p "$sroot/qa-cycle-abc-706"
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api\n' "$(( $(date +%s) - 240 ))" > "$sroot/qa-cycle-abc-706/status"
# IDENTITY ONLY — no elapsed time, no lens count. A statusline repaints on
# main-thread activity, and the main thread is blocked for a round's whole
# duration, so any number it shows is a reading from before the work started.
# Identity does not go stale; a counter does, and a stale counter invites you to
# conclude a healthy round is stuck. Live progress is watch-round.sh's job.
eq "fresh round -> identity only" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a)" "QA !706 rest-api r1"
eq "  no elapsed or count leaks"  "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -cE '◆|[0-9]+[ms]$')" "0"

# THE two-concurrent-rounds bug: the scratch root is shared machine-wide, so
# "newest wins" made each session render the OTHER project's round.
mkdir -p "$sroot/qa-cycle-def-99"
printf '99|webapp|2|lenses|5|6|%s|/repo/b\n' "$(( $(date +%s) - 60 ))" > "$sroot/qa-cycle-def-99/status"
eq "project A sees only its round"  "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a)" "QA !706 rest-api r1"
eq "project B sees only its round"  "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/b)" "QA !99 webapp r2"
eq "unrelated project sees neither" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/c | wc -c | tr -d ' ')" "0"
# A session opened INSIDE the submodule under review still matches.
eq "session inside the target"      "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a/apps/rest-api)" "QA !706 rest-api r1"
# ...and it must still match on a NINE-field line, which is what preflight, the
# manager and the sequential path all actually write. Every scoping fixture above
# is 8-field, and that is why the consumer's short read went unnoticed for so
# long: with IFS='|' the last variable absorbs the remainder, so target_abs became
# "<path>|<lens_stall>". A session ABOVE the target still matched on the prefix —
# which is exactly why the stall cases further down kept passing — but a session
# IN the target compared "<path>|1200" against "<path>" and matched nothing, so
# the fragment rendered NOTHING AT ALL. Observed live, for every round, in the
# common submodule case.
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api|1200\n' "$(( $(date +%s) - 240 ))" > "$sroot/qa-cycle-abc-706/status"
eq "  9-field line, session in target"  "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a/apps/rest-api)" "QA !706 rest-api r1"
eq "  9-field line, session above it"   "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a)" "QA !706 rest-api r1"
eq "  9-field line leaks no count"      "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -cE '[0-9]+/[0-9]+')" "0"
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api\n' "$(( $(date +%s) - 240 ))" > "$sroot/qa-cycle-abc-706/status"
rm -rf "$sroot/qa-cycle-def-99"
# THE case this exists for: a crashed panel leaves the file behind, so existence
# cannot mean "running". Age of the last write is what separates them.
# A lens legitimately runs 5-15 min, so 10 minutes of quiet DURING fan-out is
# healthy and must not warn. A single short threshold reported a working panel as
# stalled -- observed on a real round, twice.
old=$(date -v-10M +%Y%m%d%H%M 2>/dev/null || date -d '10 minutes ago' +%Y%m%d%H%M)
touch -t "$old" "$sroot/qa-cycle-abc-706/status"
eq "10m quiet in lens phase is OK" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "0"
# ...but that tolerance belongs to the PROJECT. A fast repo sets it low, and the
# same 10 minutes of silence is then a wedge worth reporting. Field 9 carries it.
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api|60\n' "$(( $(date +%s) - 900 ))" > "$sroot/qa-cycle-abc-706/status"
touch -t "$old" "$sroot/qa-cycle-abc-706/status"
eq "  low project tolerance -> stall" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "1"
eq "  env overrides the project"      "$(QA_STATUS_LENS_STALL_SECONDS=99999 QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "0"
# A round predating field 9 must not become un-stallable (empty -> built-in 1200).
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api\n' "$(( $(date +%s) - 3600 ))" > "$sroot/qa-cycle-abc-706/status"
oldest=$(date -v-50M +%Y%m%d%H%M 2>/dev/null || date -d '50 minutes ago' +%Y%m%d%H%M)
touch -t "$oldest" "$sroot/qa-cycle-abc-706/status"
eq "  missing field 9 -> default fuse" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "1"
# restore the healthy line for the checks that follow
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api|1200\n' "$(( $(date +%s) - 240 ))" > "$sroot/qa-cycle-abc-706/status"
touch -t "$old" "$sroot/qa-cycle-abc-706/status"
# ...but the same silence in a phase that does not block on subagents is a stall.
printf '706|rest-api|1|merging|6|6|%s|/repo/a/apps/rest-api\n' "$(( $(date +%s) - 900 ))" > "$sroot/qa-cycle-abc-706/status"
touch -t "$old" "$sroot/qa-cycle-abc-706/status"
eq "10m quiet while merging -> stall" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "1"
# And a genuinely wedged fan-out still surfaces, just on a longer fuse.
printf '706|rest-api|1|lenses|3|6|%s|/repo/a/apps/rest-api\n' "$(( $(date +%s) - 3000 ))" > "$sroot/qa-cycle-abc-706/status"
oldr=$(date -v-40M +%Y%m%d%H%M 2>/dev/null || date -d '40 minutes ago' +%Y%m%d%H%M)
touch -t "$oldr" "$sroot/qa-cycle-abc-706/status"
eq "40m quiet in lens phase -> stall" "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | grep -c 'stalled')" "1"
# ...and an abandoned dir eventually goes quiet rather than nagging forever.
touch -t 200001010000 "$sroot/qa-cycle-abc-706/status"
eq "  abandoned dir -> silent"       "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | wc -c | tr -d ' ')" "0"
# A finished round stops writing; it must go quiet, not read as stalled forever.
printf '706|rest-api|1|done|6|6|%s|/repo/a/apps/rest-api\n' "$(date +%s)" > "$sroot/qa-cycle-abc-706/status"
eq "phase=done -> prints nothing"  "$(QA_CYCLE_SCRATCH_ROOT="$sroot" bash "$FRAG" /repo/a | wc -c | tr -d ' ')" "0"
rm -rf "$sroot" "$r"

# ---------------------------------------------------------------------------
echo "[timing history — records the max SILENCE, not the average duration]"
REC="$REPO_SRC/lib/record-timing.sh"
tdir=$(mktemp -d); thome=$(mktemp -d)
mkscratch() { # $1=dir, $2=fanout epoch, rest: lens mtimes as epochs
  local s="$1" fo="$2"; shift 2
  mkdir -p "$s"; echo "$fo" > "$s/fanout"
  printf '706|rest-api|1|done|%s|6|%s|/repo/a|1200\n' "$#" "$fo" > "$s/status"
  local i=0
  for t in "$@"; do
    i=$((i+1)); echo '{}' > "$s/lens-$i.json"
    touch -t "$(date -r "$t" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$t" +%Y%m%d%H%M.%S)" "$s/lens-$i.json"
  done
  touch -t "$(date -r "$(( ${!#} + 30 ))" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( ${!#} + 30 ))" +%Y%m%d%H%M.%S)" "$s/status"
}
base=$(( $(date +%s) - 4000 ))
# One long silence then a burst — the real shape observed on a live round. The
# statistic must be the 600s gap, NOT the ~150s mean spacing of the five returns.
mkscratch "$tdir/r1" "$base" $((base+600)) $((base+650)) $((base+700)) $((base+750)) $((base+800))
HOME="$thome" bash "$REC" "$tdir/r1" >/dev/null 2>&1
row=$(cat "$thome"/.config/claude-qa-manager/timings/*.tsv 2>/dev/null | tail -1)
eq "max gap is the long silence" "$(awk -F'\t' '{print $6}' <<<"$row")" "600"
eq "  lens count recorded"       "$(awk -F'\t' '{print $5}' <<<"$row")" "5"
eq "  project path recorded"     "$(awk -F'\t' '{print $2}' <<<"$row")" "/repo/a"
eq "  history is outside the repo" "$( [ -d "$thome/.config/claude-qa-manager/timings" ] && echo yes || echo no )" "yes"
# A second round appends rather than replacing — a distribution needs every sample.
mkscratch "$tdir/r2" "$base" $((base+120))
HOME="$thome" bash "$REC" "$tdir/r2" >/dev/null 2>&1
eq "rounds accumulate"           "$(cat "$thome"/.config/claude-qa-manager/timings/*.tsv | wc -l | tr -d ' ')" "2"
# No fan-out stamp => the biggest silence is unmeasurable, so record NOTHING rather
# than a row that quietly omits it.
mkdir -p "$tdir/r3"; printf '706|x|1|done|6|6|%s|/repo/a|1200\n' "$base" > "$tdir/r3/status"
HOME="$thome" bash "$REC" "$tdir/r3" >/dev/null 2>&1
eq "no fanout stamp -> no row"   "$(cat "$thome"/.config/claude-qa-manager/timings/*.tsv | wc -l | tr -d ' ')" "2"
rm -rf "$tdir" "$thome"

# ---------------------------------------------------------------------------
echo "[round-return — the verdict is COMPUTED, not composed]"
# The manager named its merged-findings file seven different ways across 21 real
# rounds and the spec named it nowhere, so a helper that read a file by name would
# find it a third of the time. Findings come in on stdin; this script owns the name.
RR="$REPO_SRC/lib/round-return.sh"
rrd=$(mktemp -d); rr="$rrd/qa-cycle-rr-42"; mkdir -p "$rr"
rrepo=$(mktemp -d); git init -q "$rrepo"
git -C "$rrepo" config user.email t@t.t; git -C "$rrepo" config user.name t
printf 'a\nb\nc\n' > "$rrepo/prod.ts"; printf 'x\n' > "$rrepo/prod.spec.ts"
git -C "$rrepo" add -A; git -C "$rrepo" commit -qm author
printf 'a\nQAFIX\nb\nc\n' > "$rrepo/prod.ts"; git -C "$rrepo" add -A; git -C "$rrepo" commit -qm "qa round 1"
RRFIX=$(git -C "$rrepo" rev-parse HEAD)
jq -n --arg ta "$rrepo" --arg sha "$RRFIX" \
  '{round:2, target_abs:$ta, qa_fix_commits:[$sha], test_path_pattern:"",
    lenses:["contract-security","regression-edges","test-quality"], schema:{detected:false}}' \
  > "$rr/preflight.json"
printf '42|api|2|merging|3|3|1700000000|%s|1200\n' "$rrepo" > "$rr/status"
printf '{"lens":"contract-security","navigation":"cmm+ctx","schema_change_detected":false}\n' > "$rr/lens-contract-security.json"
printf '{"lens":"regression-edges","navigation":"ctx","schema_change_detected":true}\n'      > "$rr/lens-regression-edges.json"
# test-quality never landed -> must appear in failed_lenses, derived not remembered
printf 'snap\n' > "$rr/tree-before.txt"; printf 'snap\n' > "$rr/tree-after.txt"
: > "$rr/note-round1.md"; : > "$rr/note-round2.md"
# A round-2 finding ON the round-1 fix line (blocking), one on author code, one
# observation, one minor in a spec file.
RRF='[{"title":"on qa line","area_file":"prod.ts","line_low":2,"severity":"major","relevance":"regression"},
      {"title":"author line","area_file":"prod.ts","line_low":1,"severity":"major","relevance":"regression"},
      {"title":"an observation","area_file":"prod.ts","line_low":3,"severity":"minor","relevance":"observation"},
      {"title":"spec nit","area_file":"prod.spec.ts","line_low":1,"severity":"minor","relevance":"regression"}]'
rrout=$(printf '%s' "$RRF" | bash "$RR" "$rr" --summary "two majors" --contract-all-pass true 2>/dev/null)
# minor is 1, not 2: the observation is reported under Observations, not counted.
eq "counts are derived"            "$(jq -c '.counts' <<<"$rrout")" '{"critical":0,"major":2,"minor":1}'
eq "  round_has_critical_or_major" "$(jq -r '.round_has_critical_or_major' <<<"$rrout")" "true"
# The field that exceeded its own denominator in 62 of 262 measured rounds. Here
# TWO findings sit on the fix commit, but only ONE of them is blocking.
eq "qa_introduced_blocking is blocking-only" "$(jq -r '.qa_introduced_blocking' <<<"$rrout")" "1"
eq "  qa_introduced_total counts all"        "$(jq -r '.qa_introduced_total'    <<<"$rrout")" "1"
eq "observations are filtered on relevance"  "$(jq -r '.observations_count'     <<<"$rrout")" "1"
eq "  and carry their location"              "$(jq -r '.observations[0].area_file' <<<"$rrout")" "prod.ts"
# Derived from what LANDED, so a lens that died cannot be omitted by forgetting it.
eq "failed_lenses derived from disk"  "$(jq -c '.failed_lenses' <<<"$rrout")" '["test-quality"]'
eq "lens_navigation derived per lens" "$(jq -r '.lens_navigation."regression-edges"' <<<"$rrout")" "ctx"
eq "schema_change_detected ORs lenses" "$(jq -r '.schema_change_detected' <<<"$rrout")" "true"
eq "tree_mutated from the snapshots"   "$(jq -r '.tree_mutated' <<<"$rrout")" "false"
# THIS round's note, by number -- the scratch dir keeps every round's, and an
# earlier one gets touched whenever a trailer is appended at Step 3C.
eq "note_path is this round's note"    "$(basename "$(jq -r '.note_path' <<<"$rrout")")" "note-round2.md"
# Model-authored fields pass through untouched.
eq "blocking_summary passes through"   "$(jq -r '.blocking_summary' <<<"$rrout")" "two majors"
eq "contract_all_pass passes through"  "$(jq -r '.contract_all_pass' <<<"$rrout")" "true"
# Side effects, so they cannot be the step that is skipped.
eq "attribution written back to disk"  "$(jq '[.[]|select(has("qa_introduced"))]|length' "$rr/merged-findings.json")" "4"
eq "  in_test_file stamped too"        "$(jq '[.[]|select(.in_test_file==true)]|length'  "$rr/merged-findings.json")" "1"
eq "  canonical filename is owned"     "$( [ -f "$rr/merged-findings.json" ] && echo yes || echo no )" "yes"
eq "  status advanced to done"         "$(cut -d'|' -f4 "$rr/status")" "done"
eq "  and preserved its other fields"  "$(cut -d'|' -f1,2,3,7,9 "$rr/status")" "42|api|2|1700000000|1200"
# diminishing_returns is COMPUTED: 1 of 2 blocking is below max(2, ceil(2/2)).
eq "dim-returns not raised below threshold" \
   "$(jq -c '[.decisions_needed[]|select(.kind=="diminishing_returns")]|length' <<<"$rrout")" "0"
# Two self-inflicted blocking findings out of two -> raised, without being asked.
RRF2='[{"title":"qa1","area_file":"prod.ts","line_low":2,"severity":"major","relevance":"regression"},
       {"title":"qa2","area_file":"prod.ts","line_low":2,"severity":"critical","relevance":"regression"}]'
rrout2=$(printf '%s' "$RRF2" | bash "$RR" "$rr" --summary s 2>/dev/null)
eq "dim-returns raised at/above threshold" \
   "$(jq -r '[.decisions_needed[]|select(.kind=="diminishing_returns")]|length' <<<"$rrout2")" "1"
eq "  and carries the arithmetic"  "$(jq -r '.decisions_needed[0].self_referential' <<<"$rrout2")" "2"
eq "  against the blocking total"  "$(jq -r '.decisions_needed[0].blocking_total'   <<<"$rrout2")" "2"
# A model-supplied one is not duplicated.
rrout3=$(printf '%s' "$RRF2" | bash "$RR" "$rr" --summary s \
          --decisions '[{"kind":"diminishing_returns","reason":"mine"}]' 2>/dev/null)
eq "  a supplied dim-returns is not doubled" \
   "$(jq -r '[.decisions_needed[]|select(.kind=="diminishing_returns")]|length' <<<"$rrout3")" "1"
# The counts are the note's counts: an observation is reported in its own section and
# a hypothetical finding is not confirmed, so neither is counted nor blocks. The first
# item is the live shape: a round-2 re-raise of an item the operator decided in round
# 1, filed as an observation, still rated major, and sitting on the round-1 fix line.
RRF4='[{"title":"decided in r1","area_file":"prod.ts","line_low":2,"severity":"major","relevance":"observation","status":"confirmed"},
       {"title":"a guess","area_file":"prod.ts","line_low":1,"severity":"critical","relevance":"regression","status":"hypothetical"}]'
rrout4=$(printf '%s' "$RRF4" | bash "$RR" "$rr" --summary s 2>/dev/null)
eq "an observation rated major, and a hypothetical critical, are not counted" \
   "$(jq -c '.counts' <<<"$rrout4")" '{"critical":0,"major":0,"minor":0}'
eq "  and do not block the round" "$(jq -r '.round_has_critical_or_major' <<<"$rrout4")" "false"
eq "  nor count as QA-introduced" "$(jq -r '.qa_introduced_blocking' <<<"$rrout4")" "0"
eq "  the observation is still reported" "$(jq -r '.observations_count' <<<"$rrout4")" "1"
# Excluded only by an explicit value. A finding missing both fields is counted:
# dropping it would let an unlabelled major through as a clean round.
RRF5='[{"title":"unlabelled","area_file":"prod.ts","line_low":1,"severity":"major"}]'
rrout5=$(printf '%s' "$RRF5" | bash "$RR" "$rr" --summary s 2>/dev/null)
eq "a finding with no relevance or status still blocks" \
   "$(jq -r '.round_has_critical_or_major' <<<"$rrout5")" "true"
# Refusals: a bad decisions payload must not produce a half-valid verdict.
printf '%s' "$RRF" | bash "$RR" "$rr" --decisions 'not-json' >/dev/null 2>&1
eq "non-array --decisions -> exit 2" "$?" "2"
printf 'not-an-array' | bash "$RR" "$rr" >/dev/null 2>&1
eq "non-array stdin -> exit 2"       "$?" "2"
rm -rf "$rrd" "$rrepo"

# ---------------------------------------------------------------------------
echo "[lens-landed — progress that cannot be forgotten or drift from disk]"
# The manager used to do two hand-written Bash writes per lens return: save the
# findings, then rewrite the status line copying six fields through and
# incrementing `done` itself. Marked MANDATORY, and it did not happen — observed
# live, four lens files landing across 100s while status sat at 0/4. So the
# helper does both in ONE call and COUNTS `done` from the files on disk.
LL="$REPO_SRC/lib/lens-landed.sh"
ld=$(mktemp -d)
printf '706|webapp|2|lenses|0|4|1700000000|/repo/a|1200\n' > "$ld/status"
printf '[{"title":"one"}]' | bash "$LL" "$ld" contract-security >/dev/null
eq "findings persisted"            "$(jq -r '.[0].title' "$ld/lens-contract-security.json")" "one"
eq "  counter advanced to 1/4"     "$(cut -d'|' -f5,6 "$ld/status")" "1|4"
eq "  phase PRESERVED, not asserted" "$(cut -d'|' -f4 "$ld/status")" "lenses"
# The sequential path's vocabulary is reviewing/merging/rendering/posting/done, and
# a returning reviewer there means review is OVER. Hardcoding `lenses` mislabelled
# it AND handed merge/render work the long 1200s lens fuse instead of the short one
# (statusline-fragment.sh keys that limit on phase == "lenses"). Observed live.
# A CLEAN scratch dir: `done` is counted from every lens-*.json present, so reusing
# the dir above would count that round's five files and report 6/1.
sd=$(mktemp -d)
printf '1151|mobile|1|reviewing|0|1|1700000000|/repo/m|1200\n' > "$sd/status"
printf '[{"title":"seq"}]' | bash "$LL" "$sd" sequential >/dev/null
eq "sequential phase survives a landing" "$(cut -d'|' -f4 "$sd/status")" "reviewing"
eq "  and its counter still advances"    "$(cut -d'|' -f5,6 "$sd/status")" "1|1"
rm -rf "$sd"
# Every pass-through field survives: epoch_start is what elapsed time is measured
# from, target_abs scopes the round, lens_stall is the project's resolved fuse.
eq "  mr/target/round preserved"   "$(cut -d'|' -f1,2,3 "$ld/status")" "706|webapp|2"
eq "  epoch_start preserved"       "$(cut -d'|' -f7 "$ld/status")" "1700000000"
eq "  target_abs preserved"        "$(cut -d'|' -f8 "$ld/status")" "/repo/a"
eq "  lens_stall preserved"        "$(cut -d'|' -f9 "$ld/status")" "1200"
printf '[{"title":"two"}]' | bash "$LL" "$ld" regression-edges >/dev/null
eq "second lens -> 2/4"            "$(cut -d'|' -f5 "$ld/status")" "2"
# THE property that makes it un-forgettable: `done` is counted from disk, so a
# stale or wrong number in the status line cannot survive the next landing.
printf '706|webapp|2|lenses|99|4|1700000000|/repo/a|1200\n' > "$ld/status"
printf '[{"title":"three"}]' | bash "$LL" "$ld" test-quality >/dev/null
eq "a bogus counter is corrected from disk" "$(cut -d'|' -f5 "$ld/status")" "3"
# The status mtime is what the stall detector reads; landing a lens must move it.
touch -t 202001010000 "$ld/status"
printf '[{"title":"four"}]' | bash "$LL" "$ld" ui-styling >/dev/null
eq "status mtime refreshed on landing" \
  "$([ "$(date -r "$ld/status" +%Y)" != "2020" ] && echo yes || echo no)" "yes"
# Findings are the round's work; a missing status file must not lose them.
rm -f "$ld/status"
printf '[{"title":"five"}]' | bash "$LL" "$ld" performance >/dev/null 2>"$ld/err"
eq "no status file -> findings still saved" "$(jq -r '.[0].title' "$ld/lens-performance.json")" "five"
eq "  and it says so on stderr"             "$(grep -c 'progress NOT refreshed' "$ld/err")" "1"
# A path-bearing name would write outside the scratch dir.
printf '[]' | bash "$LL" "$ld" "../escape" >/dev/null 2>&1
eq "rejects a path-bearing lens name" "$?" "2"
rm -rf "$ld"

# ---------------------------------------------------------------------------
echo "[self-inflicted findings — blame attribution, not line arithmetic]"
ATTR="$REPO_SRC/lib/attribute-findings.sh"
a=$(mktemp -d); git init -q "$a/r"
git -C "$a/r" config user.email t@t.t; git -C "$a/r" config user.name t
printf 'a\nb\nc\nd\n' > "$a/r/f.txt"; git -C "$a/r" add -A; git -C "$a/r" commit -qm "author work"
printf 'a\nb\nFIXED\nc\nd\n' > "$a/r/f.txt"; git -C "$a/r" add -A; git -C "$a/r" commit -qm "qa round 1"
FIXSHA=$(git -C "$a/r" rev-parse HEAD)
# THE case that defeats a line-range comparison: the author inserts 10 lines ABOVE
# the QA-written line, so it is now at 13 while the fix commit "touched line 3".
{ printf 'x\n%.0s' 1 2 3 4 5 6 7 8 9 10; printf 'a\nb\nFIXED\nc\nd\n'; } > "$a/r/f.txt"
git -C "$a/r" add -A; git -C "$a/r" commit -qm "author adds lines above"
eq "QA line really did shift"     "$(grep -n FIXED "$a/r/f.txt" | cut -d: -f1)" "13"
F='[{"file":"f.txt","line_low":13,"title":"t1"},{"file":"f.txt","line_low":1,"title":"t2"}]'
res=$(printf '%s' "$F" | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]")
eq "  shifted QA line attributed"  "$(jq -r '.[0].qa_introduced' <<<"$res")" "true"
eq "  and carries the sha"         "$(jq -r '.[0].qa_introduced_commit' <<<"$res")" "$FIXSHA"
eq "  author's line NOT attributed" "$(jq -r '.[1].qa_introduced' <<<"$res")" "false"
# An abbreviated SHA in a note trailer must still resolve.
eq "  short sha resolves"          "$(printf '%s' "$F" | bash "$ATTR" "$a/r" "[\"${FIXSHA:0:8}\"]" | jq -r '.[0].qa_introduced')" "true"
# Round 1 has no recorded fix commits: "not known", never a claim of clean.
eq "no fix commits -> all false"   "$(printf '%s' "$F" | bash "$ATTR" "$a/r" '[]' | jq -c '[.[].qa_introduced]')" "[false,false]"
eq "unknown sha -> all false"      "$(printf '%s' "$F" | bash "$ATTR" "$a/r" '["0000000"]' | jq -c '[.[].qa_introduced]')" "[false,false]"
eq "missing file -> not attributed" "$(printf '[{"file":"nope.txt","line_low":1}]' | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" | jq -r '.[0].qa_introduced')" "false"
eq "empty findings -> empty array" "$(printf '[]' | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" | jq -c .)" "[]"

# THE REAL WIRE SHAPE. Everything above uses this script's own `.file` key, which
# no caller actually sends: the manager pipes LENS findings, whose location key is
# `area_file`. Reading only `.file` made every finding of a round come back
# `qa_introduced=false` while all 8 of them sat on the cycle's own fix commit
# (observability-stack !14 round 2). A test in the `.file` shape passed throughout
# and proved nothing — so this case is the one that matters.
FA='[{"area_file":"f.txt","line_low":13,"title":"t1"},{"area_file":"f.txt","line_low":1,"title":"t2"}]'
res=$(printf '%s' "$FA" | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" 2>/dev/null)
eq "area_file (lens schema) attributed"    "$(jq -r '.[0].qa_introduced' <<<"$res")" "true"
eq "  and still discriminates"             "$(jq -r '.[1].qa_introduced' <<<"$res")" "false"
eq "  .file still accepted (back-compat)"  "$(printf '%s' "$F" | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" | jq -r '.[0].qa_introduced')" "true"
# An unreadable location must be DISTINGUISHABLE from "blamed, not ours" — both
# emit qa_introduced=false, so the only signal is the stderr count. Without it,
# a total shape mismatch reads as the good news "none of these are ours".
err=$(printf '[{"title":"no location at all"}]' | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" 2>&1 >/dev/null)
eq "unreadable location warns on stderr" "$(printf '%s' "$err" | grep -c 'no usable <file,line>')" "1"
eq "  and names the count"               "$(printf '%s' "$err" | grep -c '1 of 1')" "1"
eq "a fully-resolved batch stays silent" \
  "$(printf '%s' "$FA" | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" 2>&1 >/dev/null | wc -c | tr -d ' ')" "0"

# --- .in_test_file -------------------------------------------------------
# Step 3B routes a MINOR self-inflicted finding differently depending on this
# flag: in a test file it goes to the observations ledger untouched; in code a
# customer executes it is still offered as a fix. So the flag has to be present
# on EVERY exit path, or "not a test file" becomes indistinguishable from "this
# never ran" — which is the absent-check-reads-as-pass shape invariant 2 forbids.
tf() { printf '[{"area_file":"%s","line_low":1,"title":"t"}]' "$1" | bash "$ATTR" "$a/r" '[]' | jq -r '.[0].in_test_file'; }
eq "tests/ dir is a test file"        "$(tf 'tests/foo.js')"                  "true"
eq "test/ dir is a test file"         "$(tf 'test/foo.js')"                   "true"
eq "spec/ dir is a test file"         "$(tf 'spec/foo.rb')"                   "true"
eq "__tests__/ is a test file"        "$(tf 'src/__tests__/foo.js')"          "true"
# Capitalised, because Tests/ is as common as tests/ and the corpus has it.
eq "Tests/ (capitalised) matches"     "$(tf 'Tests/CodeIslandTests/A.swift')" "true"
# Test INFRASTRUCTURE outside a tests/ dir -- both of these are real paths from
# the corpus that a tests?/ + *.spec.* pattern alone would miss.
eq "src/testing/ is a test file"      "$(tf 'src/testing/global-shim.ts')"    "true"
eq "a bare test.ts is a test file"    "$(tf 'src/test.ts')"                   "true"
eq "*.spec.ts is a test file"         "$(tf 'src/app/foo.spec.ts')"           "true"
eq "*_test.go is a test file"         "$(tf 'pkg/foo_test.go')"               "true"
eq "a Perl .t is a test file"         "$(tf 't/fiix/createFiixWorkOrder.t')"  "true"
# Production code a customer executes -- these must stay askable.
eq "production .ts is NOT a test"     "$(tf 'src/app/services/check.service.ts')" "false"
eq "a .cgi is NOT a test"             "$(tf 'linkAssetToFiix.cgi')"           "false"
eq "'latest.json' is NOT a test"      "$(tf 'ota/latest.json')"               "false"
# "contest"/"protest" must not match on a bare substring.
eq "contest.js is NOT a test"         "$(tf 'src/contest.js')"                "false"
# A finding with no location at all still carries the field, as false.
eq "no location -> flag still present" \
  "$(printf '[{"title":"nowhere"}]' | bash "$ATTR" "$a/r" '[]' | jq -r '.[0] | has("in_test_file")')" "true"
# Present on the BLAME path too, not just the early exits.
eq "flag survives the blame path" \
  "$(printf '[{"area_file":"f.txt","line_low":13}]' | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" | jq -r '.[0] | has("in_test_file")')" "true"
eq "  and blame still attributes" \
  "$(printf '[{"area_file":"f.txt","line_low":13}]' | bash "$ATTR" "$a/r" "[\"$FIXSHA\"]" | jq -r '.[0].qa_introduced')" "true"
# Overridable for a project whose tests live somewhere unusual.
eq "custom pattern wins" \
  "$(printf '[{"area_file":"checks/foo.pl","line_low":1}]' | bash "$ATTR" "$a/r" '[]' '(^|/)checks/' | jq -r '.[0].in_test_file')" "true"
eq "  and narrows as well as widens" \
  "$(printf '[{"area_file":"tests/foo.js","line_low":1}]' | bash "$ATTR" "$a/r" '[]' '(^|/)checks/' | jq -r '.[0].in_test_file')" "false"
rm -rf "$a"

# preflight recovers the cycle's fix commits from prior round-note trailers.
r=$(mkfixture "feature/x" "main")
notes='[{"body":"## QA Round 1\nstuff\nQA-Fix-Commit: aabbccdd1122\n"},{"body":"## QA Round 2\nQA-Fix-Commit: 99887766ffee\n"}]'
out=$(GLAB_STUB_NOTES="$notes" run_preflight "$r" 73 mono); note_scratch "$out"
eq "fix commits read from notes"   "$(jq -r '.qa_fix_commits | sort | join(",")' <<<"$out")" "99887766ffee,aabbccdd1122"
eq "  and reach the brief"         "$(grep -c '^qa_fix_commits=' "$(jq -r '.manager_brief_path' <<<"$out")")" "1"
out=$(GLAB_STUB_NOTES='[{"body":"## QA Round 1\nno trailer here\n"}]' run_preflight "$r" 73 mono); note_scratch "$out"
eq "no trailer -> empty array"     "$(jq -c '.qa_fix_commits' <<<"$out")" "[]"
# A round is SUPPOSED to land one commit, but a follow-up fix is normal and happened
# on a real round. Both must be attributable, or the second commit's lines read as MR
# defects in the next round. The reader takes every trailer; the writer is told to
# emit one line per commit rather than one per round.
two='[{"body":"## QA Round 1\nx\nQA-Fix-Commit: 953e24ea5c4b\ny\nQA-Fix-Commit: 9880c49cdead\n"}]'
out=$(GLAB_STUB_NOTES="$two" run_preflight "$r" 73 mono); note_scratch "$out"
eq "two trailers in one note -> both" "$(jq -r '.qa_fix_commits|sort|join(",")' <<<"$out")" "953e24ea5c4b,9880c49cdead"
# The WRITER-side rule must exist somewhere a renderer will read, but which file
# that is has already moved once (the note template left the spine for
# references/round-note.md). Pin the rule, not its address — the same reasoning
# the SAST whitelist check uses. Searching only SKILL.md would fail on a pure
# relocation and, worse, would pass if the rule were deleted from the reference
# while a stale copy lingered in the spine.
eq "  and the skill tree says one per commit" \
  "$(cat "$REPO_SRC/skills/qa-cycle/SKILL.md" "$REPO_SRC"/skills/qa-cycle/references/*.md 2>/dev/null \
     | grep -c 'ONE LINE PER COMMIT')" "1"
# ...and the manager, which renders the note on the default path, must be pointed at
# whichever file holds it. A format that drifts between the two renderers breaks the
# next round's derivation for whichever path did not change.
eq "  and the manager is pointed at the template" \
  "$(grep -c 'references/round-note\.md' "$REPO_SRC/agents/qa-manager.md")" "1"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[manager brief + approval_eligible are computed once, by preflight]"
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
brief=$(jq -r '.manager_brief_path' <<<"$out")
eq "manager_brief_path emitted"   "$( [ -s "$brief" ] && echo yes || echo no )" "yes"
# Every key the manager is contracted to receive. This list is the point of the
# change: hand-transcription dropped fields silently, and nothing caught it until
# the manager misbehaved. Assert the WHOLE set, not a sample.
for k in target_abs mr round feature_branch target_branch diff_range lenses forge \
         project project_enc qa_scratch contract_path sast_path schema_change_path \
         tool_mandate_path proportionality_path schema_change_detected qa_token_ok \
         expected_qa_user qa_token_env qa_token_file mr_approved approval_eligible \
         unapprove_on_dirty_reround sast_running; do
  eq "  brief has $k" "$(grep -c "^$k=" "$brief")" "1"
done
# No key may render empty-valued where preflight has a real value for it.
eq "  paths are absolute"         "$(grep -c '^qa_scratch=/' "$brief")" "1"
eq "  lenses is the JSON array"   "$(grep '^lenses=' "$brief" | sed 's/^lenses=//' | jq -r 'type')" "array"
eq "  diff_range is three-part"   "$(grep -c '^diff_range=origin/main\.\.HEAD' "$brief")" "1"

# The same credential NAMES must also be in preflight.json, not only the brief.
# Step 0.25 and Step 3E do not run in the manager, so brief-only publication left
# them re-deriving from config — and a wrong guess resolves EMPTY, which the
# forge reads as "act as the developer".
for k in qa_token_env qa_token_file expected_qa_user; do
  eq "  preflight.json has $k" "$(jq -r "has(\"$k\")" <<<"$out")" "true"
done
eq "  qa_token_env is non-empty"  "$(jq -r '.qa_token_env  | length > 0' <<<"$out")" "true"
eq "  qa_token_file is non-empty" "$(jq -r '.qa_token_file | length > 0' <<<"$out")" "true"

# approval_eligible: round-based and tiny-relax paths, plus the negative case.
# It used to be computed by the model at spawn time; when it was omitted the
# manager could never raise `approval` and the hands-free path silently never
# approved anything.
# The fixture's diff is tiny, so the tiny-relax clause alone makes round 1
# eligible — assert that path first, then disable it to expose the round rule.
eq "round 1 + tiny relax -> true"  "$(jq -r '.approval_eligible' <<<"$out")" "true"
eq "  diff really is tiny"         "$(jq -r '.diff_scope.is_tiny' <<<"$out")" "true"
cfg="$r/repo/.claude/skills/qa-cycle/config.json"
jq '.qa_agent.approval.tiny_mr_relax_to_round_1 = false' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  relax off, round 1 -> false" "$(jq -r '.approval_eligible' <<<"$out")" "false"
eq "  and the brief agrees"        "$(grep -c '^approval_eligible=false' "$(jq -r '.manager_brief_path' <<<"$out")")" "1"
jq '.qa_agent.approval.min_clean_round = 1' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  min_clean_round 1 -> true"   "$(jq -r '.approval_eligible' <<<"$out")" "true"
# Explicitly disabling a boolean knob must actually disable it. jq's `//` fires on
# `false` as well as `null`, so `.x // true` silently overrides the user; this
# asserts the knob is read with a null test instead.
jq '.qa_agent.approval.unapprove_on_dirty_reround = false' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  explicit false survives"     "$(grep -c '^unapprove_on_dirty_reround=false' "$(jq -r '.manager_brief_path' <<<"$out")")" "1"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[verify detection — the project's own rules, discovered not configured]"
DETECT="$REPO_SRC/lib/detect-verify.sh"
dv() { bash "$DETECT" "$1" | jq -r "$2"; }
d=$(mktemp -d)

mkdir -p "$d/mk"; printf 'test:\n\techo hi\n' > "$d/mk/Makefile"
eq "Makefile test target"            "$(dv "$d/mk" .command)" "make test"
eq "  state detected"                "$(dv "$d/mk" .state)"   "detected"

mkdir -p "$d/np"; echo '{"scripts":{"test":"jest"}}' > "$d/np/package.json"
eq "package.json scripts.test"       "$(dv "$d/np" .command)" "npm test"
touch "$d/np/pnpm-lock.yaml"
# The lockfile decides the runner: `npm test` in a pnpm workspace resolves a
# different tree than CI does.
eq "  lockfile picks the runner"     "$(dv "$d/np" .command)" "pnpm test"

# THE case that breaks the obvious implementation, taken from a real submodule:
# a package.json with an EMPTY scripts object next to a Makefile that has the
# real test target. Presence of a manifest must not short-circuit detection.
mkdir -p "$d/ft"; echo '{"scripts":{}}' > "$d/ft/package.json"; printf 'test:\n\techo hi\n' > "$d/ft/Makefile"
eq "empty scripts falls through"     "$(dv "$d/ft" .command)" "make test"
mkdir -p "$d/ft2"; echo '{"scripts":{"build":"tsc"}}' > "$d/ft2/package.json"
eq "no test entry anywhere -> none"  "$(dv "$d/ft2" .state)"  "none-found"
eq "  and command is empty"          "$(dv "$d/ft2" .command)" ""
eq "  but build is still reported"   "$(dv "$d/ft2" .build_command)" "npm run build"

# Ansible. A real repo reported none-found on EVERY round while its CI ran yamllint,
# ansible-lint, syntax-check and a playbook assert job; the session then hand-rolled
# ansible-lint 516 times and yamllint 323 times, none of it recorded as verify
# evidence. The gate was honest — it never claimed clean — but Step 3B's "run the
# project's own checks" was nominally unsatisfied on every round.
mkdir -p "$d/ans"; touch "$d/ans/.ansible-lint" "$d/ans/.yamllint"
eq "ansible-lint config detected"    "$(dv "$d/ans" .command)" "ansible-lint --offline"
eq "  source names the config"       "$(dv "$d/ans" .source)"  ".ansible-lint"
eq "  yamllint is the build side"    "$(dv "$d/ans" .build_command)" "yamllint ."
# THE correction. Adding this detector turned an honest none-found into a `detected`
# that runs a LINTER while reading as though the project's suite passed — a reviewer
# spotted it within one round ("a linter, not the behavioural suite"). `state` answers
# "is there something to run"; `kind` answers the question Step 3B actually needs.
eq "  and is labelled kind=lint"     "$(dv "$d/ans" .kind)" "lint"
eq "  real suites are kind=suite"    "$(dv "$d/mk" .kind)"  "suite"
# Keyed on the LINT config, never on ansible.cfg: every Ansible repo has one whether
# or not anything lints it, so keying there emits a command for repos that never run
# it — rule 1, presence must prove the entry point exists.
mkdir -p "$d/anscfg"; touch "$d/anscfg/ansible.cfg"
eq "ansible.cfg ALONE is not a gate" "$(dv "$d/anscfg" .state)" "none-found"
# Stronger signals still win: a Makefile test target outranks the lint config.
mkdir -p "$d/ansmk"; touch "$d/ansmk/.ansible-lint"; printf 'test:\n\techo hi\n' > "$d/ansmk/Makefile"
eq "  Makefile outranks ansible-lint" "$(dv "$d/ansmk" .command)" "make test"
# ...and molecule, the stronger Ansible signal, outranks the lint config too.
mkdir -p "$d/ansmol/molecule"; touch "$d/ansmol/.ansible-lint"
eq "  molecule outranks ansible-lint" "$(dv "$d/ansmol" .command)" "molecule test"
eq "  and molecule is behavioural"    "$(dv "$d/ansmol" .kind)" "suite"

mkdir -p "$d/empty"
eq "bare directory -> none-found"    "$(dv "$d/empty" .state)" "none-found"
eq "missing directory -> none-found" "$(bash "$DETECT" "$d/nope" | jq -r .state)" "none-found"
# `kind` must be absent-shaped wherever `command` is empty. A consumer that reads
# kind without first checking state would otherwise conclude the opposite of the
# truth — and BOTH no-command paths must agree, including the early exit for a
# missing directory, which builds its JSON by hand rather than through jq.
eq "  bare dir -> kind=none"         "$(dv "$d/empty" .kind)" "none"
eq "  missing dir -> kind=none"      "$(bash "$DETECT" "$d/nope" | jq -r .kind)" "none"
eq "  build-only -> kind=none"       "$(dv "$d/ft2" .kind)" "none"
rm -rf "$d"

# End to end: preflight must carry the result, and an undiscoverable project must
# reach the skill as an explicit none-found rather than as an absent key.
r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "preflight verify.state none-found" "$(jq -r '.verify.state' <<<"$out")" "none-found"
printf 'test:\n\techo hi\n' > "$r/repo/Makefile"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  detected once the repo has one"  "$(jq -r '.verify.command' <<<"$out")" "make test"
eq "  and names where it came from"    "$(jq -r '.verify.source' <<<"$out" | grep -c Makefile)" "1"
# An override exists for when detection is wrong, but must announce itself as
# configured so it is never mistaken for the project's own rule.
cfg="$r/repo/.claude/skills/qa-cycle/config.json"
jq '. + {verify:{command:"bazel test //..."}}' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  config override wins"            "$(jq -r '.verify.command' <<<"$out")" "bazel test //..."
eq "  and is labelled configured"      "$(jq -r '.verify.state' <<<"$out")" "configured"
# Per-target beats project-wide. In a monorepo one submodule's detected command can
# be right while a sibling's also tears the dev environment down, so a single
# project-wide override would have to break the working one to fix the broken one.
jq '.targets.mono.verify = {"command":"perl autotest.pl -S"}' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  per-target beats project-wide"   "$(jq -r '.verify.command' <<<"$out")" "perl autotest.pl -S"
eq "  and names which key won"         "$(jq -r '.verify.source' <<<"$out")" "config targets.mono.verify.command"

# The bound travels with the command. The config above sets `verify.command`
# and nothing else, and still gets 900: the layers are merged with jq's `*`,
# which merges objects RECURSIVELY, so the sibling `timeout_seconds` survives a
# partial override. This asserts that inheritance -- NOT the in-script fallback,
# which this case never reaches.
eq "  shipped default is inherited"    "$(jq -r '.verify.timeout_seconds' <<<"$out")" "900"
jq '.verify.timeout_seconds = 120' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  project-wide timeout is read"    "$(jq -r '.verify.timeout_seconds' <<<"$out")" "120"
jq '.targets.mono.verify.timeout_seconds = 45' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  per-target timeout wins"         "$(jq -r '.verify.timeout_seconds' <<<"$out")" "45"
# Junk must not read as "no limit". An unbounded run is the failure with no floor.
jq '.targets.mono.verify.timeout_seconds = "soon"' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  junk timeout falls back to 900"  "$(jq -r '.verify.timeout_seconds' <<<"$out")" "900"
# The baseline knobs are policy in config, resolved like every other verify key.
# Hardcoding them in the helper over-fits a generic driver to whichever suite
# they were first measured against.
eq "  expect travels with the command" "$(jq -r '.verify | has("expect")' <<<"$out")" "true"
eq "  shipped baseline reaches JSON"   "$(jq -r '.verify.baseline.min_samples' <<<"$out")" "3"
eq "  ...with the whole policy"        "$(jq -r '[.verify.baseline|keys[]]|sort|join(",")' <<<"$out")" "floor_seconds,min_samples,multiplier,window"
jq '.verify.baseline = {"multiplier":9}' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  project override merges in"      "$(jq -r '.verify.baseline.multiplier' <<<"$out")" "9"
eq "  ...keeping the shipped siblings"  "$(jq -r '.verify.baseline.min_samples' <<<"$out")" "3"
jq '.targets.mono.verify.baseline = {"multiplier":2}' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "  per-target baseline wins"        "$(jq -r '.verify.baseline.multiplier' <<<"$out")" "2"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[run-verify bounds the suite it was handed]"
# detect-verify proves a test entry point EXISTS; nothing proves it TERMINATES.
# These drive lib/run-verify.sh itself -- the thing the fix step actually runs.
RV="$REPO_SRC/lib/run-verify.sh"
bounded() { [ "$1" -lt 20 ] && echo yes || echo no; }
# A pass must be POSITIVELY confirmed, so a fixture that means "this suite
# succeeded" has to print a marker and declare it. `exit 0` alone is deliberately
# NOT a pass -- see run-verify.sh's note on the observed 13-second false pass.
MARK='SUITE-OK-MARK'
pass_cmd() { printf 'echo %s; exit 0' "$MARK"; }
# Sleep durations are derived from this run's PID, never hardcoded. A fixed
# duration is matched by ANY other copy of this suite on the machine — an
# isolated red-first tree, a concurrent run — and a deliberately-broken copy
# leaks exactly the processes these assertions grep for, so the marker must be
# unique per run or a neighbour's leak is reported as this run's.
GC=$(( 8000 + ($$ % 900) ))       # grandchild marker
WD=$(( 7000 + ($$ % 900) ))       # watchdog marker
survivors() { ps -Ao args | grep -c "[s]leep $1"; }
# The watchdog is a perl process carrying the limit in its argv, NOT a `sleep`.
# Grepping for `sleep $WD` here would match nothing and pass vacuously — an
# assertion that cannot fail is the thing this suite exists not to ship.
wd_survivors() { ps -Ao args | grep -c "[s]etpgrp.* $1 "; }
d=$(mktemp -d); lg="$d/v.log"
rv() { bash "$RV" "$d" "$1" --log "$lg" --expect "$MARK" ${2:+--timeout-seconds "$2"}; }

eq "confirmed pass -> passed"   "$(rv "$(pass_cmd)"     | jq -r .state)" "passed"
eq "nonzero -> failed"          "$(rv 'exit 3'          | jq -r .state)" "failed"
eq "  and carries its status"   "$(rv 'exit 3'          | jq -r .exit)"  "3"
eq "empty command -> not-run"   "$(rv ''               | jq -r .state)" "not-run"

# THE false pass, reproduced. A recipe that starts containers, runs a harness and
# tears them down exits 0 because the TEARDOWN succeeded -- the harness aborted
# and emitted no test output. Exit 0 must therefore never be a pass on its own.
#
# The abort text is deliberately generic. Nothing in run-verify.sh matches on it
# -- the only string the tool ever looks for is the project's own configured
# `expect` -- so naming a particular harness's error here would imply detection
# logic that does not exist, and must not be added.
abort='echo "harness aborted before running anything"; echo teardown-ok; exit 0'
eq "exit 0 with no marker"      "$(rv "$abort"          | jq -r .state)"  "unconfirmed"
eq "  and says why"             "$(rv "$abort"          | jq -r .reason)" "expect_not_met"
eq "  no --expect at all"       "$(bash "$RV" "$d" 'exit 0' --log "$lg" | jq -r .state)"  "unconfirmed"
eq "  ...and says that too"     "$(bash "$RV" "$d" 'exit 0' --log "$lg" | jq -r .reason)" "no_expect_configured"
# A crash must not be laundered into "we ran out of time": the round has to see
# a segfaulting suite as a failure it can act on. This is why the timeout state
# comes from a watchdog sentinel and not from an exit-code range -- SIGSEGV is
# 139, which any `rc >= 128` test would misreport.
eq "crash -> failed, not timeout" "$(rv 'kill -SEGV $$' | jq -r .state)" "failed"

# stdin is closed: a suite that prompts gets EOF instead of waiting for a human.
t0=$(date +%s); st=$(rv "IFS= read -r x; echo $MARK; exit 0" | jq -r .state); el=$(( $(date +%s) - t0 ))
eq "stdin reader does not block"  "$st" "passed"
eq "  and returns promptly"       "$(bounded "$el")" "yes"

t0=$(date +%s); st=$(rv 'sleep 600' 2 | jq -r .state); el=$(( $(date +%s) - t0 ))
eq "unbounded run -> timeout"     "$st" "timeout"
eq "  and is actually bounded"    "$(bounded "$el")" "yes"

# THE discriminating case. A watchdog that TERMs only its direct child passes
# the row above and still hangs in production: a real suite is a tree
# (`make test` -> `npm test` -> a watcher), and the process that will not die is
# the grandchild. Kill the process GROUP or this helper buys nothing.
t0=$(date +%s); st=$(rv "sh -c \"sleep $GC\"" 2 | jq -r .state); el=$(( $(date +%s) - t0 ))
eq "grandchild -> timeout"        "$st" "timeout"
eq "  bounded too"                "$(bounded "$el")" "yes"
sleep 1
eq "  and no grandchild survives" "$(survivors "$GC")" "0"

# The watchdog must not outlive the run either: its `sleep` is a separate
# process, and an orphan holding this script's stdout blocks any caller reading
# the JSON from a pipe for the rest of the limit -- on a command that finished.
# Repeated deliberately. The watchdog's group is created by perl's setpgrp, so
# an INSTANT command can finish before that group exists and a single kill then
# hits nothing — measured at roughly one leak in seven, which a single-shot
# assertion passes straight over.
n=0
for _ in 1 2 3 4 5 6 7 8; do
  [ "$(rv "$(pass_cmd)" "$WD" | jq -r .state)" = "passed" ] || n=$((n+1))
done
eq "fast run under a long limit"  "$n" "0"
sleep 1
eq "  leaves no watchdog orphan"  "$(wd_survivors "$WD")" "0"
# Guard the guard: the matcher must actually match a LIVE watchdog, or the line
# above proves nothing. Start one, see it, then confirm it is reaped.
rv 'sleep 4' "$WD" >/dev/null &
sleep 1
eq "  the orphan matcher works"   "$([ "$(wd_survivors "$WD")" -ge 1 ] && echo yes || echo no)" "yes"
wait
sleep 1
eq "  and the watchdog is reaped" "$(wd_survivors "$WD")" "0"

# The suite's own output goes to the log, not into the caller's stdout.
rv 'echo to-stdout; echo to-stderr >&2' >/dev/null
eq "log captures stdout"          "$(grep -c 'to-stdout' "$lg")" "1"
eq "log captures stderr"          "$(grep -c 'to-stderr' "$lg")" "1"
eq "stderr is clean"              "$(rv 'echo hi' 2>&1 >/dev/null | wc -c | tr -d ' ')" "0"

# --- the learned bound -----------------------------------------------------
# A fixed ceiling is safe but blunt: a 20s suite that wedges burns the whole
# quarter hour. These drive the derivation, not a copy of it.
tf="$d/timings"
# $3 = baseline policy JSON (the knobs are config, not literals in the script).
rvt() { bash "$RV" "$d" "$1" --log "$lg" --timeout-seconds "$2" --timings "$tf" \
             --canonical-command "$1" --expect "$MARK" ${3:+--baseline "$3"}; }
# Same, but the run is NOT the declared gate: canonical stays 'make test'.
rvnc() { bash "$RV" "$d" "$1" --log "$lg" --timeout-seconds "$2" --timings "$tf" \
              --canonical-command 'make test' --expect "$MARK" ${3:+--baseline "$3"}; }
seed() { printf '%s\n' "$@" > "$tf"; }

# ONE invocation, both fields read from it. Calling rvt twice would not repeat
# the experiment: the first run appends its own duration, so the second sees
# three samples and legitimately reports a baseline.
seed 20 20
out=$(rvt 'exit 0' 900)
eq "under min_samples -> configured" "$(jq -r .limit_source <<<"$out")" "configured"
eq "  and claims no baseline"        "$(jq -r .baseline_seconds <<<"$out")" "null"

# multiplier(5) x median(20) = 100, below the 900 ceiling, so the baseline governs.
seed 20 20 20
out=$(rvt 'exit 0' 900)
eq "3 samples -> baseline governs"  "$(jq -r .limit_source <<<"$out")" "baseline"
eq "  median is reported"           "$(jq -r .baseline_seconds <<<"$out")" "20"
eq "  limit is multiplier x median" "$(jq -r .limit_used <<<"$out")" "100"

# Floor: a 1-second suite must not get a 5-second bound that normal variance trips.
seed 1 1 1
eq "fast suite hits the floor"      "$(rvt 'exit 0' 900 | jq -r .limit_used)" "60"

# Ceiling: the baseline may LOWER the configured limit, never raise it.
seed 500 500 500
out=$(rvt 'exit 0' 120)
eq "baseline cannot exceed config"  "$(jq -r .limit_used <<<"$out")" "120"
eq "  and says so"                  "$(jq -r .limit_source <<<"$out")" "configured"

# ONLY THE DECLARED GATE IS MEASURED. A round runs a narrow red-first check on
# one test file AND the full suite against the same target, seconds apart: 22s
# against minutes. Pool them and the narrow run sets the bound for the suite,
# which is then killed and reported unverified -- permanently, because timeouts
# are not recorded so the suite never contributes a counter-sample. Found on a
# real round, not by a fixture: every fixture had used one command shape.
seed 400 400 400
before=$(wc -l < "$tf" | tr -d ' ')
# These are CONFIRMED passes, so non-canonicality is the only thing stopping the
# record. A bare `exit 0` would now be `unconfirmed` and go unrecorded anyway,
# which would make the assertion below pass for the wrong reason.
rvnc "$(pass_cmd)" 900 >/dev/null      # a real pass, but not the declared gate
rvnc "$(pass_cmd)" 900 >/dev/null
rvnc "$(pass_cmd)" 900 >/dev/null
eq "non-canonical pass not recorded" "$(wc -l < "$tf" | tr -d ' ')" "$before"
out=$(bash "$RV" "$d" "$(pass_cmd)" --log "$lg" --timeout-seconds 900 --timings "$tf" \
        --canonical-command "$(pass_cmd)" --expect "$MARK")
eq "  so the gate's bound is intact" "$(jq -r .baseline_seconds <<<"$out")" "400"
eq "  ...and the gate DID record"    "$(( $(wc -l < "$tf" | tr -d ' ') - before ))" "1"
eq "  and one file serves the target" "$(ls "$tf"* | wc -l | tr -d ' ')" "1"

# THE self-poisoning case. If a timeout were recorded, every firing would ratchet
# the baseline up using the number that means "this did not finish" -- a gate
# that widens itself each time it fires until it bounds nothing.
seed 2 2 2
rvt 'sleep 600' 3 >/dev/null
eq "a timeout is not recorded"      "$(wc -l < "$tf" | tr -d ' ')" "3"
# ...while terminated runs ARE recorded, or nothing would ever be learned.
seed 5 5; before=$(wc -l < "$tf" | tr -d ' ')
rvt 'exit 1' 900 >/dev/null
eq "a failed run IS recorded"       "$(( $(wc -l < "$tf" | tr -d ' ') - before ))" "1"

# The knobs are CONFIG. Same samples, different policy, different bound -- and
# min_samples 0 opts out of the learned bound entirely.
seed 20 20 20
eq "multiplier is honoured"         "$(rvt 'exit 0' 900 '{"multiplier":2,"floor_seconds":1}' | jq -r .limit_used)" "40"
eq "floor is honoured"              "$(rvt 'exit 0' 900 '{"multiplier":1,"floor_seconds":300}' | jq -r .limit_used)" "300"
eq "min_samples is honoured"        "$(rvt 'exit 0' 900 '{"min_samples":9}' | jq -r .limit_source)" "configured"
eq "min_samples 0 disables it"      "$(rvt 'exit 0' 900 '{"min_samples":0}' | jq -r .limit_source)" "configured"
seed 9 9 9 9 9 1 1 1
eq "window trims to the recent runs" "$(rvt 'exit 0' 900 '{"window":3,"floor_seconds":1,"multiplier":1}' | jq -r .baseline_seconds)" "1"

# --from-preflight is the form the orchestrator uses: the command never passes
# through a shell line, so its spaces and quotes cannot be mis-quoted.
pf="$d/pf.json"
jq -n --arg tp "$tf" --arg c "$(pass_cmd)" --arg m "$MARK" \
  '{verify:{command:$c, expect:$m, timeout_seconds:900,
            timings_path:$tp, baseline:{min_samples:3,multiplier:5,floor_seconds:60,window:10}}}' > "$pf"
seed 20 20 20
out=$(bash "$RV" "$d" --from-preflight "$pf" --log "$lg")
eq "--from-preflight supplies all"  "$(jq -r .limit_used <<<"$out")" "100"
eq "  including the expect marker"  "$(jq -r .state <<<"$out")" "passed"
eq "  and the command it ran"       "$(jq -r .command <<<"$out")" "$(pass_cmd)"
eq "  explicit flag still wins"     "$(bash "$RV" "$d" --from-preflight "$pf" --log "$lg" --timeout-seconds 30 | jq -r .limit_used)" "30"

# An unwritable timings path must cost the round nothing AND say nothing. A
# redirection is processed before the command's own 2>/dev/null applies, so
# `>> "$f" 2>/dev/null` on a read-only path still prints -- the suppression has
# to wrap the whole group. The `stderr is clean` check above only ever exercises
# the writable path, so it cannot catch this.
ro="$d/ro"; mkdir -p "$ro"; chmod a-w "$ro"
rvro() { bash "$RV" "$d" "$(pass_cmd)" --log "$lg" --timeout-seconds 900 \
              --timings "$ro/k" --canonical-command "$(pass_cmd)" --expect "$MARK"; }
err=$(rvro 2>&1 >/dev/null)
eq "unwritable timings: silent"     "$(printf '%s' "$err" | wc -c | tr -d ' ')" "0"
st=$(rvro 2>/dev/null)
# A confirmed pass, so the ONLY thing being tested is that an unwritable timings
# path costs the round nothing. A bare `exit 0` would now be `unconfirmed` and
# the assertion would be measuring pass semantics instead.
eq "  and still reports the run"    "$(jq -r .state <<<"$st")" "passed"
eq "  falling back to configured"   "$(jq -r .limit_source <<<"$st")" "configured"
chmod u+w "$ro"

# Which bound was hit has to reach the round: a wedge and a slow suite are
# different findings.
seed 1 1 1
out=$(rvt 'sleep 600' 900 '{"multiplier":2,"floor_seconds":2}')
eq "baseline timeout names itself"   "$(jq -r .reason <<<"$out")" "exceeded_baseline"
eq "  and the bound was the baseline" "$(jq -r .limit_source <<<"$out")" "baseline"
rm -f "$tf"
eq "configured timeout names itself" "$(rvt 'sleep 600' 2 | jq -r .reason)" "exceeded_configured"
rm -rf "$d"

# ---------------------------------------------------------------------------
echo "[subproject concepts appear only when there are subprojects]"
# A single-target project config models a plain repo (gitops-ansible shape); the
# stock fixture, which defines `mono`, stays as the multi-target control.
r=$(mkfixture "feature/x" "main")
cfg="$r/repo/.claude/skills/qa-cycle/config.json"; mkdir -p "$(dirname "$cfg")"
echo '{"targets":{"default":{"path":".","remote":"origin","scope":"","lens_tags":[]}}}' > "$cfg"
out=$(run_preflight "$r" 73); rc=$?; note_scratch "$out"   # TARGET omitted on purpose
eq "target arg optional -> exit 0"        "$rc" "0"
eq "  multi_target false"                 "$(jq -r '.layout.multi_target' <<<"$out")" "false"
eq "  target_count 1"                     "$(jq -r '.layout.target_count' <<<"$out")" "1"
eq "  target_is_submodule false"          "$(jq -r '.layout.target_is_submodule' <<<"$out")" "false"
# The shipped bug: jq's // does not fire on "" (an empty string is truthy), so the
# scope stayed empty and Step 3B rendered a literal `fix(): …` — malformed
# conventional-commit, rejected outright by a commitlint hook.
eq "  commit subject has no empty parens" "$(jq -r '.commit_subject' <<<"$out")" "fix: address QA round 1"
# .project must remain the forge slug: `layout` is a separate key precisely so the
# duplicate-key collision that once destroyed `scope` cannot repeat.
eq "  .project still the forge slug"      "$(jq -r '.project|type' <<<"$out")" "string"
rm -rf "$r"

r=$(mkfixture "feature/x" "main"); out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "multi-target -> multi_target true"    "$(jq -r '.layout.multi_target' <<<"$out")" "true"
eq "  commit subject carries the scope"   "$(jq -r '.commit_subject' <<<"$out")" "fix(mono): address QA round 1"
# Omitting the target where targets ARE named must fail loudly, never silently
# review some other subproject.
run_preflight "$r" 73 >/dev/null; eq "  omitted target, named targets -> exit 2" "$?" "2"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[review_mode routing]"
r=$(mkfixture "feature/x" "main"); commit_lines "$r/repo" 10 big.txt
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "10 lines -> sequential" "$(jq -r '.review_mode' <<<"$out")" "sequential"; rm -rf "$r"
r=$(mkfixture "feature/x" "main"); commit_lines "$r/repo" 200 big.txt
out=$(run_preflight "$r" 73 mono); note_scratch "$out"
eq "200 lines -> manager" "$(jq -r '.review_mode' <<<"$out")" "manager"; rm -rf "$r"

# The tool mandate is IDENTICAL on both paths, and that is the assertion: a
# subagent CAN load deferred MCP tools. A restrictive `tools:` grant on
# qa-reviewer once made it look otherwise (its `mcp__*` wildcard matched nothing,
# since MCP tools are deferred rather than concretely loaded), and the mandate was
# briefly branched on review_mode to describe that as a platform limit. Deleting
# the grant fixed it: the next round's lenses — all on the MANAGER path, i.e.
# subagents — loaded ctx_* via ToolSearch and made 5-14 real calls. These cases
# pin the branch back out, so a future reader does not reintroduce it.
        # Sets globals; does NOT print the path. `m=$(mandate_for 200)` would run the
        # whole body in a SUBSHELL and MANDATE_MODE/MANDATE_FIXTURE would never escape
        # it — the same subshell trap forge_approvers documents.
mandate_for() { # $1 lines changed -> sets $m, $MANDATE_MODE, $MANDATE_FIXTURE
  MANDATE_FIXTURE=$(mkfixture "feature/x" "main")
  commit_lines "$MANDATE_FIXTURE/repo" "$1" big.txt
  echo '{"mcpServers":{"codebase-memory-mcp":{"command":"x"}}}' > "$MANDATE_FIXTURE/repo/.mcp.json"
  local out; out=$(run_preflight "$MANDATE_FIXTURE" 73 mono); note_scratch "$out"
  MANDATE_MODE=$(jq -r '.review_mode' <<<"$out")
  m=$(jq -r '.tooling.mandate_path' <<<"$out")
}
mandate_for 200
eq "manager path renders a mandate"        "$( [ -s "$m" ] && echo yes || echo no )" "yes"
eq "  (and it really is the manager path)" "$MANDATE_MODE" "manager"
eq "  asserts availability"                "$(grep -c 'ARE available' "$m")" "1"
eq "  orders the ToolSearch bootstrap"     "$(grep -c 'Load them FIRST' "$m")" "1"
# ...and the bootstrap has to name tools ToolSearch can actually resolve. It listed
# BARE names (`select:search_graph`), which do not resolve, so every lens burned a
# round-trip rediscovering `mcp__codebase-memory-mcp__search_graph`. Scoped to the
# select: line on purpose — the descriptive bullets above it stay bare, and asserting
# "no bare name anywhere" would fail on those.
eq "  and qualifies the CMM tool names"    "$(grep -c 'select:mcp__codebase-memory-mcp__search_graph' "$m")" "1"
eq "  and no bare name survives there"     "$(grep -c 'select:search_graph' "$m")" "0"
eq "  requires the disclosure line"        "$(grep -c 'Navigation: <cmm' "$m")" "1"
# The last mile: resolving the CMM schema is not enough — the graph tools take a
# `project`, and a lens that cannot name it abandons them. Every lens on one round
# resolved the schemas and then made ZERO graph calls for exactly this reason.
eq "  names the CMM project"               "$(grep -c 'CMM project for this repo' "$m")" "1"
# Derive the expectation from the fixture's own repo root rather than hardcoding a
# prefix — the fixture lives under a temp root, so a literal `Users-` passed only on
# this machine and would have failed in CI. Ask git for the toplevel rather than
# building the path by hand: on macOS mktemp -d hands back /var/... while git
# reports the physical /private/var/..., and the two do not compare equal.
want_root=$(git -C "$MANDATE_FIXTURE/repo" rev-parse --show-toplevel)
want_cmm="${want_root#/}"; want_cmm="${want_cmm//\//-}"
eq "  and the name is path-derived"        "$(grep -c "CMM project for this repo: \`${want_cmm}" "$m")" "1"
eq "  and warns off subtree indexes"       "$(grep -c 'ANCESTOR' "$m")" "1"
# Vocabulary must separate "used ctx, skipped the graph" from "had nothing":
# collapsing them made 6 lenses self-report a fallback while making real ctx calls.
eq "  ctx-only is its own verdict"         "$(grep -c 'answer is `ctx` or `cmm+ctx`' "$m")" "1"
eq "  forbids a false unreachable claim"   "$(grep -c 'never requested it' "$m")" "1"
# Compare with the CMM project line dropped: the two fixtures are different temp
# dirs, so that ONE line is legitimately different and everything else must not be.
strip_proj() { grep -v 'CMM project for this repo' "$1"; }
MANAGER_MANDATE=$(strip_proj "$m"); rm -rf "$MANDATE_FIXTURE"

mandate_for 10
eq "sequential path renders a mandate"     "$( [ -s "$m" ] && echo yes || echo no )" "yes"
eq "  (and it really is sequential)"       "$MANDATE_MODE" "sequential"
# Identical apart from the path-derived project name. A per-path difference is what
# encoded the wrong conclusion last time; comparing whole files catches its return.
eq "  is IDENTICAL to the manager mandate" "$( [ "$MANAGER_MANDATE" = "$(strip_proj "$m")" ] && echo yes || echo no )" "yes"
rm -rf "$MANDATE_FIXTURE"
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
echo "[remote-URL parser — via the REAL script's emitted .project]"
# Drives forge_project_slug through preflight. Hosts are .invalid and
# GIT_SSH_COMMAND=false, so the fetch dies instantly with no DNS; preflight still
# emits preflight.json on the exit-4 path, so .project remains assertable.
#
# QA_FORGE stays set here on purpose: these cases test the PARSER, and most of
# these hosts are .invalid with no forge name to sniff. Detection itself is
# asserted separately in the block below, with QA_FORGE unset.
url_case() {
  local r; r=$(mkfixture "feature/x" "main")
  git -C "$r/repo" remote set-url origin "$2"
  local out; out=$(run_preflight "$r" 73 mono); note_scratch "$out"
  eq "$1" "$(jq -r '.project // "<none>"' <<<"$out")" "$3"
  rm -rf "$r"
}
url_case "scp-style + .git"   'git@host.invalid:grp/proj.git'       'grp/proj'
url_case "ssh alias, no .git" 'githost:grp/proj'                    'grp/proj'
url_case "https + .git"       'https://host.invalid/grp/proj.git'   'grp/proj'
url_case "https, no .git"     'https://host.invalid/grp/proj'       'grp/proj'
url_case "nested subgroups"   'git@host.invalid:a/b/c/proj.git'     'a/b/c/proj'
url_case "ssh:// with path"   'ssh://git@host.invalid/a/b/proj.git' 'a/b/proj'
# A URL with no group/project path must die loudly (exit 2), not silently pass
# the whole URL through as the "project" — the old parser's actual failure mode.
r=$(mkfixture "feature/x" "main"); git -C "$r/repo" remote set-url origin 'notaurl'
run_preflight "$r" 73 mono >/dev/null; eq "unparseable remote -> exit 2" "$?" "2"; rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[forge selection — QA_FORGE overrides, URL sniffing is the fallback]"
# The suite exports QA_FORGE=gitlab globally (a fixture remote is a local path
# with no host). Unset it here so these cases exercise the real precedence:
#   QA_FORGE > .forge config key > URL sniffing.
#
# An UNRESOLVABLE forge must be exit 2 with a named cause, never a silent
# default to GitLab: a GitHub repo quietly reviewed through glab would fail in
# ways that look like an auth problem, ten steps later.
forge_case() {
  local label="$1" url="$2" want="$3" cfg="${4:-.}"
  local r; r=$(mkfixture "feature/x" "main" "$cfg")
  git -C "$r/repo" remote set-url origin "$url"
  local out; out=$(QA_FORGE="" run_preflight "$r" 73 mono); local rc=$?
  note_scratch "$out"
  if [ "$want" = "exit2" ]; then eq "$label" "$rc" "2"
  else eq "$label" "$(jq -r '.forge // "<none>"' <<<"$out")" "$want"; fi
  rm -rf "$r"
}
forge_case "gitlab.com URL -> gitlab" 'git@gitlab.com:grp/proj.git'   'gitlab'
forge_case "github.com URL -> github" 'git@github.com:grp/proj.git'   'github'
forge_case "self-hosted host, no config -> exit 2" 'git@git.example.invalid:grp/proj.git' 'exit2'
forge_case "self-hosted host + .forge config -> gitlab" \
  'git@git.example.invalid:grp/proj.git' 'gitlab' '.forge = "gitlab"'
# Config must not beat an explicit env value.
r=$(mkfixture "feature/x" "main" '.forge = "gitlab"')
git -C "$r/repo" remote set-url origin 'git@git.example.invalid:grp/proj.git'
out=$(QA_FORGE=github run_preflight "$r" 73 mono); note_scratch "$out"
eq "QA_FORGE beats the .forge config key" "$(jq -r '.forge // "<none>"' <<<"$out")" "github"
rm -rf "$r"

echo "[every gh call is pinned to the slug preflight resolved, not gh's own guess]"
# A `gh` invocation without --repo falls back to gh's remote resolution, which in
# a FORK checkout prefers the PARENT repository. `forge_view_mr` is such a call,
# and it supplies the branch names and diff range the whole round is built on --
# so PR #N of a fork silently returns upstream's PR #N, every field internally
# consistent. Observed live: preflight resolved the fork slug correctly and then
# reported a different, already-merged PR by another author.
#
# Asserted from what the CLI actually SAW (the stub logs its own GH_REPO), not
# from the presence of the export line in preflight.sh -- an assertion on the
# source text would pass while the export sat after the first forge call.
r=$(mkfixture "feature/x" "main" '.')
git -C "$r/repo" remote set-url origin 'git@github.com:forkowner/proj.git'
commit_lines "$r/repo" 5 f.js
envlog="$r/gh-env.log"; : > "$envlog"
out=$(QA_FORGE=github GH_STUB_ENVLOG="$envlog" run_preflight "$r" 73 mono); note_scratch "$out"
eq "fork remote still resolves as github" "$(jq -r '.forge // "<none>"' <<<"$out")" "github"
eq "  at least one gh call was made"      "$( [ -s "$envlog" ] && echo yes || echo no)" "yes"
eq "  every gh call saw the fork slug"    "$(sort -u "$envlog" | tr '\n' ' ' | sed 's/ *$//')" "GH_REPO=forkowner/proj"
eq "  no gh call ran with GH_REPO unset"  "$(grep -c '<unset>' "$envlog"; true)" "0"
rm -rf "$r"

# ---------------------------------------------------------------------------
echo "[approval is not degradable — an empty token must never reach the forge]"
# An empty token makes glab/gh act as the DEFAULT (developer) identity. For a
# round NOTE that degradation is deliberate; for an APPROVAL it manufactures a
# self-approval on a self-authored MR, which passes an approvals check and reads
# as independent review. See CASE-STUDIES.md §self-approval-fallback.
#
# This drives the REAL lib/forge.sh through forge_init, with glab/gh replaced by
# a stub that logs its argv — so "no API call" is asserted from the absence of a
# log line, not from re-implementing the guard here.
forge_guard_case() { # $1 forge, $2 cli, $3 remote url
  local forge="$1" cli="$2" url="$3"
  local d; d=$(mktemp -d); local log="$d/calls"
  printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$log" > "$d/$cli"
  chmod +x "$d/$cli"; : > "$log"
  local out rc
  # QA_FORGE is exported =gitlab suite-wide; without overriding it here the
  # github case would source the GITLAB backend, look for `glab`, find no stub,
  # and pass every "no call reached gh" assertion VACUOUSLY.
  out=$(QA_FORGE="$forge" PATH="$d:$PATH" bash -c '
    set -u
    . "$1/lib/forge.sh"
    forge_init "$2" "$1/lib" || exit 90
    forge_approve   grp/proj 73 "" ; echo "approve_rc=$?"
    forge_unapprove grp/proj 73 "" ; echo "unapprove_rc=$?"
    forge_post_note grp/proj 73 /dev/null "" >/dev/null 2>&1 ; echo "note_rc=$?"
  ' _ "$REPO_SRC" "$url" 2>/dev/null); rc=$?
  eq "$forge: harness ran"                "$rc" "0"
  eq "$forge: approve refuses empty token"   "$(sed -n 's/^approve_rc=//p'   <<<"$out")" "3"
  eq "$forge: unapprove refuses empty token" "$(sed -n 's/^unapprove_rc=//p' <<<"$out")" "3"
  # The asymmetry, asserted rather than described: post_note still degrades.
  eq "$forge: post_note still degrades"      "$(sed -n 's/^note_rc=//p'      <<<"$out")" "0"
  # No approve/revoke/review ever reached the CLI; only the note did.
  # `grep -c` PRINTS 0 and RETURNS 1 on no match, so a `|| echo 0` fallback here
  # emits "0\n0" and the comparison fails on a passing case. Let it print alone.
  eq "$forge: no approval call reached $cli" \
    "$(grep -cE 'approve|revoke|review|dismissal' "$log"; true)" "0"
  eq "$forge: the note DID reach $cli" \
    "$(grep -cE 'note|comment' "$log"; true)" "1"
  rm -rf "$d"
}
forge_guard_case gitlab glab 'git@gitlab.com:grp/proj.git'
forge_guard_case github gh   'git@github.com:grp/proj.git'

# ---------------------------------------------------------------------------
echo "[forge_head_ci — the CI gate Step 3E approves behind]"
# A round once approved an MR while the pipeline for its OWN fix commit was still
# running, resting the approval on a local suite run — in a repo that had already
# had CI go red on a QA fix commit because the local run covered 5 of N suites.
# preflight's .pipeline_status cannot close that: it describes the head BEFORE the
# fix commit exists. So this probe is live, and it returns the SHA so the caller
# can prove CI ran on the code being approved.
#
# Each stub emits its forge's NATIVE payload, never the normalized answer — the
# mapping under test is exactly what a normalized stub would hide (see this file's
# header). `running` and `none` are asserted as distinct from both success and
# failure: collapsing either into a pass is the absent-check-reports-clean defect.
head_ci_case() { # $1 forge, $2 cli, $3 url, $4 stub-case-body, $5 want-state, $6 want-sha
  local d; d=$(mktemp -d)
  { echo '#!/usr/bin/env bash'; echo 'case "$*" in'; echo "$4"; echo '*) echo "{}" ;;'
    echo 'esac'; echo 'exit 0'; } > "$d/$2"
  chmod +x "$d/$2"
  local got
  got=$(QA_FORGE="$1" PATH="$d:$PATH" bash -c '
    set -u
    . "$1/lib/forge.sh"
    forge_init "$2" "$1/lib" || exit 90
    forge_head_ci grp/proj 73 tok
  ' _ "$REPO_SRC" "$3" 2>/dev/null)
  eq "$1/$5" "$got" "$5 $6"
  rm -rf "$d"
}
# GitLab: head_pipeline.status IS the blocking outcome — it reports success when
# only allow_failure jobs fail, which is why this gate does not read job results.
_gl() { printf '*"merge_requests/73"*) jq -nc %s ;;' "'{head_pipeline:{status:\"$1\",sha:\"cafe123\"},sha:\"cafe123\"}'"; }
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl success)" success cafe123
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl failed)"  failed  cafe123
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl running)" running cafe123
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl pending)" running cafe123
# `canceled` carries no verdict: not a pass, and NOT a failure either. Reporting
# it as failed tells the operator to fix a defect that does not exist.
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl canceled)" did-not-run cafe123
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl weird_new_status)" unknown cafe123
# No pipeline at all -> `none`, which the caller must REPORT, never treat as clean.
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' \
  '*"merge_requests/73"*) echo "{\"sha\":\"cafe123\"}" ;;' none cafe123

# GitHub: no single blocking field, so it is derived — and the precedence is the
# assertion. failure outranks in-flight; in-flight outranks success; NEUTRAL and
# SKIPPED are how a path-filtered workflow says "did not apply" and are NOT red.
_ghp() { printf '*"pulls/73"*) echo %s ;; *check-runs*) echo %s ;;' \
  "'{\"head\":{\"sha\":\"cafe123\"}}'" "'{\"check_runs\":$1}'"; }
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"success"}]')" success cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"failure"}]')" failed cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"in_progress","conclusion":null}]')" running cafe123
# Half-green must never report success: one pending among passes is still running.
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"success"},{"status":"queued","conclusion":null}]')" running cafe123
# ...and one failure among pending is FAILED, not running — red outranks in-flight.
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"queued","conclusion":null},{"status":"completed","conclusion":"failure"}]')" failed cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"skipped"},{"status":"completed","conclusion":"neutral"}]')" success cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' "$(_ghp '[]')" none cafe123
# A check that ended without judging the code is its OWN state — and it outranks a
# real failure, because "fix it" is the wrong instruction for a job that never ran.
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"cancelled"}]')" did-not-run cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"timed_out"}]')" did-not-run cafe123
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"cancelled"}]')" did-not-run cafe123
# ...but a plain failure with everything else green is still `failed`, not swallowed.
head_ci_case github gh 'git@github.com:grp/proj.git' \
  "$(_ghp '[{"status":"completed","conclusion":"failure"},{"status":"completed","conclusion":"success"}]')" failed cafe123

# Non-vacuity: with a token present the same calls MUST reach the CLI. Without
# this, a guard that refused unconditionally would pass every assertion above.
d=$(mktemp -d); log="$d/calls"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "%s"\n' "$log" > "$d/glab"; chmod +x "$d/glab"; : > "$log"
out=$(QA_FORGE=gitlab PATH="$d:$PATH" bash -c '
  set -u
  . "$1/lib/forge.sh"
  forge_init "git@gitlab.com:grp/proj.git" "$1/lib" || exit 90
  forge_approve grp/proj 73 tok-abc; echo "approve_rc=$?"
' _ "$REPO_SRC" 2>/dev/null)
eq "with a token, approve DOES call glab" "$(grep -c 'mr approve' "$log"; true)" "1"
eq "  and returns the CLI's status"       "$(sed -n 's/^approve_rc=//p' <<<"$out")" "0"
rm -rf "$d"

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
# THE defect this state exists for. An unrun job uploads no artifact, and a
# missing artifact printed "likely no NEW findings" UNDER a "## NEW SAST findings"
# header — so a scan that never executed classified as `clean` and got written
# into a permanent approval comment. Observed live: gitleaks_scan died with
# runner_system_failure ("0/2 nodes are available … timed out waiting for pod to
# start") while the pipeline stayed green around it, because the security jobs are
# allow_failure. running=false is part of the assertion: unlike pipeline-running
# this does NOT resolve by waiting, and a true here would make the cycle sit
# forever on a job that needs a human to retry it.
sast_case "runner never started" '## SAST review skipped

Security jobs did not run — the runner never started them.' 'skipped:runner-unavailable' 'false'
sast_case "unrecognized stub" 'something the helper never says' 'skipped:unknown' 'false'

# Non-vacuity for the case above: the classifier must key on the "did not run"
# sentence, not merely on "## SAST review skipped" (which every skip path emits).
sast_case "skip heading alone is NOT runner-unavailable" '## SAST review skipped

Some other reason entirely.' 'skipped:unknown' 'false'

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
#
# BOTH helpers, not just the GitLab one. preflight's classifier is shared, so a
# phrase reworded on one side only silently drops that forge into
# skipped:unknown — a whole forge losing its security gate with every test still
# green. Checking one helper is what would let that ship.
for helper_forge in gitlab github; do
  HELPER="$REPO_SRC/lib/fetch-sast-${helper_forge}.sh"
  if [ -f "$HELPER" ]; then
    for phrase in "No pipeline associated with MR" "No security stage detected" \
                  "Security scans are still in progress" "## NEW SAST findings" \
                  "Security jobs did not run"; do
      if grep -qF -- "$phrase" "$HELPER"; then ok "$helper_forge helper emits: $phrase"
      else bad "$helper_forge helper emits: $phrase" "not found in $HELPER — stubs are stale, SAST cases prove nothing"; fi
    done
  else
    bad "fetch-sast-${helper_forge}.sh present" "not found at $HELPER"
  fi
done

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
# THE FRAME MISMATCH, from a real round. When the target is its own repo (a
# submodule), `git diff` runs inside it and prints SUBMODULE-relative paths --
# `db/template.sql`, never `apps/api/db/template.sql`. An operator who configures
# the superproject-relative path (the path they see in their editor, and the path
# examples/monorepo-submodules.json used to show) then gets a gate that CANNOT
# match anything: schema.detected=false with state=checked, on an MR that did
# change the schema. That is invariant 2 -- an absent check reporting as a pass --
# on the one gate that arms mandatory human approval. Preflight strips the target's
# own path prefix so both spellings work.
r=$(mkfixture "feature/x" "main" '.targets.api = {path:"apps/api", base_branch:"main", remote:"origin", scope:"api", security_stage:false}
                                 | .schema.files = ["apps/api/db/template.sql"]')
git init -q --bare "$r/sub-remote.git"
git init -q -b main "$r/repo/apps/api"
git -C "$r/repo/apps/api" config user.email t@t.t; git -C "$r/repo/apps/api" config user.name t
git -C "$r/repo/apps/api" remote add origin "$r/sub-remote.git"
mkdir -p "$r/repo/apps/api/db"; echo sub-base > "$r/repo/apps/api/base.txt"
git -C "$r/repo/apps/api" add -A >/dev/null; git -C "$r/repo/apps/api" commit -qm base
git -C "$r/repo/apps/api" push -q origin main
git -C "$r/repo/apps/api" checkout -q -b feature/x
printf -- '-- the schema\n' > "$r/repo/apps/api/db/template.sql"
git -C "$r/repo/apps/api" add -A >/dev/null; git -C "$r/repo/apps/api" commit -qm "touch the schema"
out=$(run_preflight "$r" 73 api)
eq "superproject-relative config, submodule-relative diff -> detected" \
   "$(jq -r '.schema.detected' <<<"$out")" "true"
eq "  and the evidence names the file"          \
   "$(jq -r '.schema.state' <<<"$out")" "checked"
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
# A schema-tagged target gets schema-propagation WITHOUT any DDL. This asserts
# INTENT, not incidental behaviour: the lens's second mandate is code-only schema
# dependencies — code reading a column absent from the schema file, with no .sql
# change — which is the §schema-drift production-outage class and the only thing
# that catches it. Do NOT "optimise" this by gating the lens on schema.detected.
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

echo "[review.model / review.lens_models / review.allowed_models — a named frontier model, never the session's]"
# Default: the shipped config names a frontier model. There is no "inherit the
# session" default — a lens that inherited would review on Haiku under a Haiku
# session.
r=$(mkfixture "feature/x" "main" '.'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "default review_model is opus"     "$(jq -r '.review_model' <<<"$out")" "opus"
eq "default lens_models is {}"        "$(jq -r '.lens_models' <<<"$out")" "{}"
eq "default allowed_models"           "$(jq -c '.allowed_models' <<<"$out")" '["opus","fable"]'
brief=$(jq -r '.manager_brief_path' <<<"$out")
eq "  brief carries review_model=opus" "$(grep -c '^review_model=opus$' "$brief")" "1"
eq "  brief carries lens_models={}"   "$(grep -c '^lens_models={}$' "$brief")" "1"
eq "  brief carries allowed_models"   "$(grep -c '^allowed_models=\["opus","fable"\]$' "$brief")" "1"
# set-phase.sh rebuilds the status line's identity fields from the brief rather
# than copying them through from a file a model can overwrite. Field 2 is the
# target SHORT name, so without this key the repair falls back to the very value
# it exists to distrust.
eq "  brief carries the target short name" \
   "$( [ "$(grep -c '^target=' "$brief")" -eq 1 ] && echo yes || echo no )" "yes"
rm -rf "$r"
# A global override applies; lens_models stays empty.
r=$(mkfixture "feature/x" "main" '.review.model = "opus"'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "review.model flows to review_model"      "$(jq -r '.review_model' <<<"$out")" "opus"
brief=$(jq -r '.manager_brief_path' <<<"$out")
eq "  brief carries review_model=opus"       "$(grep -c '^review_model=opus$' "$brief")" "1"
rm -rf "$r"
# Per-lens override, keyed by LENS NAME.
r=$(mkfixture "feature/x" "main" '.review.lens_models = {"contract-security":"opus"}'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "review.lens_models flows through"        "$(jq -r '.lens_models."contract-security"' <<<"$out")" "opus"
eq "  no unknown_lens_model_keys warning"    "$(jq -r '[.warnings[]|select(startswith("unknown_lens_model_keys"))]|length' <<<"$out")" "0"
rm -rf "$r"
# Unknown key (a lens_tag, not a lens name — the exact mix-up fe0d99a fixed for
# lens_tags) warns, does not fail the round.
r=$(mkfixture "feature/x" "main" '.review.lens_models = {"api":"opus"}'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono); rc=$?
eq "unknown lens_models key -> still exit 0"          "$rc" "0"
eq "  warned as unknown_lens_model_keys"              "$(jq -r '[.warnings[]|select(startswith("unknown_lens_model_keys"))]|length' <<<"$out")" "1"
rm -rf "$r"
# Wrong types are config errors (exit 2), same treatment as lens_tags.
r=$(mkfixture "feature/x" "main" '.review.model = 42')
run_preflight "$r" 73 mono >/dev/null; eq "non-string review.model -> exit 2" "$?" "2"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.review.lens_models = ["opus"]')
run_preflight "$r" 73 mono >/dev/null; eq "non-object review.lens_models -> exit 2" "$?" "2"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.review.lens_models = {"contract-security": 42}')
run_preflight "$r" 73 mono >/dev/null; eq "non-string lens_models value -> exit 2" "$?" "2"
rm -rf "$r"
# The floor. Each of these is a round that would review below it, so each is a
# refusal (exit 2), never a warning a hands-free round would sail past.
floor_case() {  # $1 label, $2 jq config edit, $3 expected rc
  local r; r=$(mkfixture "feature/x" "main" "$2"); commit_lines "$r/repo" 5 f.js
  run_preflight "$r" 73 mono >/dev/null; eq "$1 -> exit $3" "$?" "$3"
  rm -rf "$r"
}
floor_case "empty review.model (the inherit case)"      '.review.model = ""'                                 2
floor_case "review.model below the floor"               '.review.model = "haiku"'                            2
floor_case "a lens_models value below the floor"        '.review.lens_models = {"contract-security":"sonnet"}' 2
floor_case "empty allowed_models"                       '.review.allowed_models = []'                        2
floor_case "an allowed full id, any case"               '.review.model = "Claude-Fable-5-1"'                 0
floor_case "the operator's own allow-list is honoured"  '.review.model = "sonnet" | .review.allowed_models = ["sonnet"]' 0

echo "[review.test_path_pattern — reaches the manager, or the override is inert]"
# The manager passes this to attribute-findings.sh as argv[3]. If it never reaches
# the brief, the override silently does nothing and every project quietly gets the
# built-in default -- a configured knob that reports success while doing nothing.
r=$(mkfixture "feature/x" "main" '.'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "default test_path_pattern is empty"  "$(jq -r '.test_path_pattern' <<<"$out")" ""
brief=$(jq -r '.manager_brief_path' <<<"$out")
eq "  brief carries the key even empty"  "$(grep -c '^test_path_pattern=$' "$brief")" "1"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.review.test_path_pattern = "(^|/)checks/"'); commit_lines "$r/repo" 5 f.js
out=$(run_preflight "$r" 73 mono)
eq "a configured pattern flows to JSON"  "$(jq -r '.test_path_pattern' <<<"$out")" "(^|/)checks/"
brief=$(jq -r '.manager_brief_path' <<<"$out")
eq "  and to the brief verbatim"         "$(grep -c '^test_path_pattern=(\^|/)checks/$' "$brief")" "1"
rm -rf "$r"
# A pattern jq cannot compile makes every test() call throw, and the helper's
# `// false` would then read as "nothing is a test file" -- a wrong answer wearing
# the shape of a clean one. Reject it at source instead.
r=$(mkfixture "feature/x" "main" '.review.test_path_pattern = "(unclosed"')
run_preflight "$r" 73 mono >/dev/null; eq "an uncompilable regex -> exit 2" "$?" "2"
rm -rf "$r"
r=$(mkfixture "feature/x" "main" '.review.test_path_pattern = 42')
run_preflight "$r" 73 mono >/dev/null; eq "non-string test_path_pattern -> exit 2" "$?" "2"
rm -rf "$r"
# The manager must be TOLD the key exists, or it cannot pass what it never reads.
eq "qa-manager.md lists it as a brief input" \
   "$(grep -c 'test_path_pattern.*may' "$REPO_SRC/agents/qa-manager.md")" "1"

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
  # select(type=="object") is load-bearing: `targets` carries a `_comment`
  # STRING beside the target objects. Index it and jq raises a type error, the
  # substitution comes back empty, and `${nonarray:-none}` turns that into a
  # pass -- a check that errored out reporting clean. Keep the type filter and
  # the `jq -e` status check together; either alone restores the silent pass.
  if ! nonarray=$(jq -er '[.targets // {} | to_entries[]
                           | select((.value|type) == "object")
                           | select(.value.lens_tags != null and (.value.lens_tags|type) != "array")
                           | .key] | join(",")' "$f" 2>&1); then
    bad "  lens_tags all arrays: $(basename "$f")" "jq failed: $nonarray"
  else
    eq "  lens_tags all arrays: $(basename "$f")" "${nonarray:-none}" "none"
  fi
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
  # Loop the EXAMPLES too, not just defaults.json. This check ran on $BB_REAL
  # alone, whose lens_tags are all `[]` — so it passed vacuously for the whole
  # life of the file while examples/monorepo-submodules.json shipped
  # ["api-envelope"] and ["ui-styling"] (the LENS names, not the tags). An
  # operator copied it and got a silently inert lens. Invariant 4: the two loops
  # directly above already iterated the examples; this one did not.
  for f in "$BB_REAL" "$REPO_SRC/examples/"*.json; do
    # Same two hazards as the loop above: `.targets[]` hits the `_comment`
    # string in defaults.json, and single-repo.json has no `targets` at all
    # ("Cannot iterate over null"). Both error to empty, and empty reads as
    # "no unknown tags" -- a clean report from a check that never ran.
    if ! bad_tags=$(jq -er --arg re "$TAGS_RE" '[.targets // {} | to_entries[]
                       | select((.value|type) == "object")
                       | .value.lens_tags[]?]
                     | unique | map(select(test($re) | not)) | join(",")' "$f" 2>&1); then
      bad "  no unknown tags: $(basename "$f")" "jq failed: $bad_tags"
    elif [ -z "$bad_tags" ]; then ok "  no unknown tags: $(basename "$f")"
    else bad "  no unknown tags: $(basename "$f")" "found: $bad_tags"; fi
  done
  # Same for the JSON snippets in the docs — users copy those verbatim, and the
  # one in CONFIGURING.md carried "api-envelope" alongside the example file.
  for f in "$REPO_SRC/docs/"*.md; do
    doc_tags=$(grep -oE '"lens_tags"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$f" \
      | grep -oE '"[a-z][a-z0-9-]*"' | grep -v '^"lens_tags"$' | sort -u | tr -d '"')
    doc_bad=$(printf '%s\n' "$doc_tags" | jq -Rr --arg re "$TAGS_RE" 'select(length>0) | select(test($re)|not)' | tr '\n' ',')
    if [ -z "$doc_bad" ]; then ok "  no unknown tags in doc snippets: $(basename "$f")"
    else bad "  no unknown tags in doc snippets: $(basename "$f")" "found: ${doc_bad%,}"; fi
  done
fi
# review.lens_models keys must be LENS NAMES, extracted the same way as the tag
# vocabulary above — a hardcoded copy here would drift the same way a hardcoded
# tag list would.
NAMES_RE=$(grep -oE "KNOWN_LENS_NAMES_RE='[^']+'" "$PREFLIGHT_SRC" | head -1 | sed -E "s/^KNOWN_LENS_NAMES_RE='//; s/'$//")
if [ -z "$NAMES_RE" ]; then
  bad "  lens-name vocabulary extracted from preflight.sh" "extraction returned nothing — update the extractor, do NOT paste a copy"
else
  ok "  lens-name vocabulary extracted from preflight.sh (not a hardcoded copy)"
  for f in "$BB_REAL" "$REPO_SRC/examples/"*.json; do
    bad_keys=$(jq -r --arg re "$NAMES_RE" '[.review.lens_models // {} | keys[]] | unique | map(select(test($re) | not)) | join(",")' "$f")
    if [ -z "$bad_keys" ]; then ok "  no unknown lens_models keys: $(basename "$f")"
    else bad "  no unknown lens_models keys: $(basename "$f")" "found: $bad_keys"; fi
  done
fi

echo "[lens enum <-> qa-manager catalog agreement]"
# The !73 precedent: a fix added two SAST gate_states to the producer but not its
# consumer, hard-exiting a routine clean round. Same producer/consumer shape here
# — preflight's enum is the producer, the manager's catalog is the consumer.
# The catalog moved out of agents/qa-manager.md prose into config/lens-catalog.json
# when lib/run-panel.sh took over composing lens prompts. The producer/consumer
# check is the same one; only the consumer's address changed.
CATALOG_JSON="$REPO_SRC/config/lens-catalog.json"
if [ -f "$CATALOG_JSON" ]; then
  enum=$(grep -oE '\^\(contract-security\|[a-z|-]+\)\$' "$PREFLIGHT_SRC" | head -1 \
    | sed -E 's/^\^\((.*)\)\$$/\1/' | tr '|' '\n' | sort -u)
  catalog=$(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$CATALOG_JSON" | sort -u)
  if [ -z "$enum" ]; then bad "lens enum extracted from preflight" "regex found nothing — update the test"
  elif [ -z "$catalog" ]; then bad "lens catalog extracted from config/lens-catalog.json" "found nothing — update the test"
  elif [ "$enum" = "$catalog" ]; then ok "preflight lens enum == lens-catalog.json"
  else bad "preflight lens enum == lens-catalog.json" "$(diff <(echo "$enum") <(echo "$catalog") | tr '\n' ' ')"; fi
  # Every entry needs a focus. A key with no focus is a lens the driver treats as
  # unknown, which fails the whole lens rather than reviewing without a mandate.
  eq "  every catalog entry has a focus" \
     "$(jq -r '[to_entries[] | select(.key | startswith("$") | not)
                | select((.value.focus // "") == "")] | length' "$CATALOG_JSON")" "0"
else
  bad "config/lens-catalog.json present" "not found at $CATALOG_JSON"
fi

# ---------------------------------------------------------------------------
echo "[status-line format agrees across BOTH review paths]"
# The manager owns the round on the default path; the sequential fallback owns it for
# a tiny diff or when Agent nesting is unavailable. Both now write the same status
# file, so the field list has to stay identical in both writers — preflight seeds
# 9 fields and either writer dropping one silently breaks project scoping or the
# stall threshold. Extract from the real sources; do not restate the format here.
#
# The MANAGER's writer is now lib/lens-landed.sh, not prose in qa-manager.md: asking
# the agent to hand-copy six pass-through fields per lens return was marked MANDATORY
# and still did not happen (four lens files landed while status sat at 0/4). This
# assertion therefore follows the format to the script that now owns it — checking
# qa-manager.md would only prove the prose still exists, which was never the problem.
#
# There are now exactly TWO writers, and that is itself the fix: preflight seeds
# the line, lib/set-phase.sh owns every change after it. The manager path, the
# sequential path and round-return.sh used to each carry their own copy of this
# printf, copying fields 1-3 through from the file — so one prose overwrite was
# laundered by all of them. `only ONE script may write this line` at the end of
# this suite is the guard against that coming back.
MGR="$REPO_SRC/lib/set-phase.sh"
SEQ="$REPO_SRC/skills/qa-cycle/references/sequential-and-multimodel.md"
# Count the SEPARATORS, not the %s: preflight stamps its own phase as a literal
# (`|preflight|0|`), so a format string is not all %s.
fields() { local fmt; fmt=$(grep -ohE "printf '[^']*\|[^']*\\\\n'" "$1" | grep '|%s' | head -1)
           echo $(( $(printf '%s' "$fmt" | tr -cd '|' | wc -c | tr -d ' ') + 1 )); }
eq "preflight seeds 9 status fields"  "$(fields "$REPO_SRC/lib/preflight.sh")" "9"
eq "  set-phase.sh writes 9"          "$(fields "$MGR")" "9"
# The preflight-resolved fields must be preserved, never re-derived here. This
# used to compare `grep -c` against itself, which passes for any value including
# zero — a check that could not fail, guarding the field that a live round came
# back with as `0`.
for f in epoch_start target_abs lens_stall; do
  eq "  set-phase preserves $f" \
     "$( [ "$(grep -c "$f" "$MGR")" -ge 1 ] && echo yes || echo no )" "yes"
done
# Both writers must CLEAR the previous round's per-lens files. The scratch dir is
# keyed to the MR, not the round, so leftovers read as this round's results —
# observed live: `ls lens-*.json` showed 6 on a round that had finished 2.
# On the default path the writer is now lib/run-panel.sh, not the manager's prose;
# the sequential path still owns its own bookkeeping.
for doc in "$RUNPANEL_SRC" "$SEQ"; do
  eq "  $(basename "$doc") clears stale lens files" \
     "$( grep -c 'rm -f .*lens-\*\.json' "$doc" )" "1"
done
# And both must route the per-lens landing through the helper rather than
# hand-writing the two files, which is what made the counter forgettable.
# At least once, not exactly once: the sequential doc states the obligation once,
# while run-panel.sh calls it and explains why in its header.
for doc in "$RUNPANEL_SRC" "$SEQ"; do
  eq "  $(basename "$doc") uses lens-landed.sh" \
     "$( [ "$(grep -c 'lens-landed\.sh' "$doc")" -ge 1 ] && echo yes || echo no )" "yes"
done
# The default path must actually REACH the driver, and must no longer describe the
# Agent fan-out it replaced. Both halves matter: a doc that still tells the manager
# to spawn qa-reviewer subagents gives it two contradictory ways to run the panel,
# and prose the model can cite is prose the model will follow.
MANAGER_MD="$REPO_SRC/agents/qa-manager.md"   # NOT $MGR — that is set-phase.sh
eq "qa-manager.md runs the panel via run-panel.sh" \
   "$( [ "$(grep -c 'run-panel\.sh' "$MANAGER_MD")" -ge 1 ] && echo yes || echo no )" "yes"
eq "  ...and no longer spawns qa-reviewer Agents" \
   "$( grep -c 'subagent_type.*qa-reviewer' "$MANAGER_MD" )" "0"
eq "  ...and no longer carries the lens catalog in prose" \
   "$( grep -cE '^- \*\*(contract-security|regression-edges|test-quality)\*\*' "$MANAGER_MD" )" "0"
# The sequential path is the exception and keeps its own reviewer spawn — asserted
# so that "no Agent spawn anywhere" is never mistaken for the rule.
eq "  the sequential path still spawns its reviewer" \
   "$( [ "$(grep -c 'qa-reviewer' "$SEQ")" -ge 1 ] && echo yes || echo no )" "yes"

# The watcher does not TRUST that: it filters by the fanout stamp, so a round that
# forgets to clear still reports the right count.
eq "watcher filters lens files by fanout" \
   "$( grep -c 'lt "\$fo"' "$REPO_SRC/lib/watch-round.sh" )" "1"

# The fallback must also carry the round-level bookkeeping the manager does.
for m in 'fanout' 'tree-before' 'record-timing.sh' 'lens-'; do
  eq "  sequential does '$m'"   "$( [ "$(grep -c -- "$m" "$SEQ")" -ge 1 ] && echo yes || echo no )" "yes"
done

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
# The consumer whitelist lives wherever the approval step is documented. It moved
# from SKILL.md into references/ when the spine was split, so search the whole skill
# tree rather than one hardcoded file -- otherwise a future reorganisation silently
# disables the one check that catches producer/consumer drift.
SKILL_TREE_DIR="$(dirname "$SKILL_MD")"
consumer=$(cat "$SKILL_MD" "$SKILL_TREE_DIR"/references/*.md 2>/dev/null \
  | awk '/case "\$\{SAST_GATE_STATE:-\}" in/{f=1;next} f&&/\)[[:space:]]*;;/{print;exit}' \
  | sed -E 's/\)[[:space:]]*;;.*//' | tr -d ' ' | tr '|' '\n' | grep . | sort -u)
if [ -z "$consumer" ]; then bad "SAST gate_state whitelist found in the skill tree" "extraction returned nothing in $SKILL_MD or its references/"
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
# Regression lock for the leak: with QA_CYCLE_SCRATCH_ROOT honoured, every scratch
# dir lands under $SUITE_TMP. If a change ever hardcodes /tmp again, the count
# below goes to 0 and this fails.
n_here=$(ls -d "$SUITE_TMP"/qa-cycle-* 2>/dev/null | grep -c . || true)
if [ "${n_here:-0}" -gt 0 ]; then ok "scratch dirs land under the suite's own tmp root ($n_here)"
else bad "scratch dirs land under the suite's own tmp root" "found none under $SUITE_TMP — is QA_CYCLE_SCRATCH_ROOT still honoured?"; fi

echo "[scratch-root that cannot be created -> exit 5, not a silent 0]"
# Locks the mkdir guard: an unwritable/uncreatable QA_CYCLE_SCRATCH_ROOT must be one
# clear internal failure, never a silent exit 0 that leaves downstream steps
# tripping over a missing preflight.json. Point the seam at a path whose parent
# is a FILE, so mkdir -p cannot succeed.
r=$(mkfixture "feature/x" "main")
blocker=$(mktemp); : > "$blocker"    # a regular file
out=$(QA_CYCLE_SCRATCH_ROOT="$blocker/cannot" run_preflight "$r" 73 mono); rc=$?
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

# ===========================================================================
# lib/run-panel.sh — the `claude -p` lens driver
#
# The stub is a fake `claude` on $PATH, one layer below the driver, for the same
# reason the forge cases stub `glab` rather than lib/forge.sh: stubbing anything
# higher would re-implement the driver's own logic in the test. Its success
# envelope is the SHAPE of a real `--output-format json` run recorded on
# 2026-09-04 (claude 2.1.260) — `modelUsage` with camelCase token keys,
# `structured_output` as an object, `stop_reason: tool_use` on a multi-turn run.
# Those three are exactly what the driver reads, and each was a guess before the
# run: a hand-invented envelope would have had snake_case, a string
# `structured_output`, and `end_turn`, and the driver would have passed its tests
# and failed in production on all three.
# ===========================================================================
echo "[run-panel.sh — the lens driver]"

mkpanel() {   # -> echoes a root dir with plugin/, repo/, scratch/, bin/
  local root; root=$(mktemp -d)
  local plugin="$root/plugin" repo="$root/repo" S="$root/scratch" bin="$root/bin"
  mkdir -p "$plugin/lib" "$plugin/config" "$repo" "$S" "$bin"

  # The REAL driver and the REAL counter helper. lens-landed.sh is what makes the
  # progress counter ground-truth, so a stub here would assert against a copy of
  # the property under test.
  cp "$RUNPANEL_SRC" "$plugin/lib/run-panel.sh"
  cp "$REPO_SRC/lib/lens-landed.sh" "$REPO_SRC/lib/set-phase.sh" \
     "$REPO_SRC/lib/lens-tool-log.sh" "$REPO_SRC/lib/lens-tools-summary.sh" "$plugin/lib/"
  cp "$REPO_SRC/config/lens-catalog.json" "$REPO_SRC/config/lens-schema.json" "$plugin/config/"

  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
  # A real commit, so the snapshot's HEAD line is a real sha rather than empty —
  # an empty HEAD would make the tree-mutation snapshot compare equal by accident.
  echo x > "$repo/a.sh"; git -C "$repo" add a.sh; git -C "$repo" commit -qm init

  # Field 9 is the resolved stall tolerance and the driver takes its watchdog
  # bound from it — 2s here so the hang case costs two seconds, not twenty
  # minutes.
  printf '73|mono|2|preflight|0|3|%s|%s|2\n' "$(date +%s)" "$repo" > "$S/status"
  printf 'x\n' > "$S/proportionality.md"
  printf 'use the graph tools\n' > "$S/tool-mandate.md"
  # The pinned tool surface preflight generates. The fixture did NOT have this
  # file for the driver's first three commits, and its absence hid a live-round
  # failure: the driver's round hygiene deleted it before the first lens ran.
  printf '{"mcpServers":{}}\n' > "$S/panel-mcp.json"

  {
    printf 'target_abs=%s\n' "$repo"
    printf 'target=api\n'
    printf 'mr=73\nround=2\n'
    printf 'feature_branch=feature/x\ntarget_branch=main\n'
    printf 'diff_range=origin/main..HEAD\n'
    printf 'lenses=["contract-security","regression-edges","test-quality"]\n'
    printf 'review_model=opus\n'
    printf 'lens_models={}\n'
    printf 'allowed_models=["opus","fable"]\n'
    printf 'qa_scratch=%s\n' "$S"
    printf 'contract_path=%s/contract.md\n' "$S"
    printf 'sast_path=%s/sast.md\n' "$S"
    printf 'schema_change_path=%s/schema-change.md\n' "$S"
    printf 'tool_mandate_path=%s/tool-mandate.md\n' "$S"
    printf 'proportionality_path=%s/proportionality.md\n' "$S"
    printf 'status_path=%s/status\n' "$S"
    printf 'lens_mcp_path=%s/panel-mcp.json\n' "$S"
    printf 'lens_mcp_state=ok\n'
  } > "$S/manager-brief.txt"

  cat > "$bin/claude" <<'STUB'
#!/usr/bin/env bash
# Fake `claude`. Records its own argv per lens so the driver's invocation is
# asserted from what the CLI actually SAW, never from the driver's intent.
prompt=$(cat)
lens=$(printf '%s\n' "$prompt" | sed -n '1s/^# QA lens: \([a-z-]*\).*/\1/p')
[ -n "$lens" ] || lens=unknown
printf '%s\n' "$*" > "$FAKE_LOG/argv-$lens.txt"
printf '%s' "$prompt" > "$FAKE_LOG/stdin-$lens.txt"

mode=$(printf '%s\n' ${FAKE_MODES:-} | sed -n "s/^$lens://p")
[ -n "$mode" ] || mode=success

# Drive the telemetry hook the way Claude Code does: read the --settings file the
# driver passed and run every command registered for an event, payload on stdin.
# Payload keys are those a live `claude -p` 2.1.284 delivered on 2026-09-30. The
# three calls are the three shapes the log must distinguish: ran and succeeded, ran
# and failed, never ran (a gate blocked it -- Pre with no Post).
settings=""; prev=""
for a in "$@"; do [ "$prev" = "--settings" ] && settings="$a"; prev="$a"; done
if [ -n "$settings" ] && [ -f "$settings" ]; then
  fire() {  # $1 event, $2 payload
    jq -r --arg e "$1" '.hooks[$e][]?.hooks[]?.command' "$settings" \
      | while IFS= read -r c; do printf '%s' "$2" | bash -c "$c"; done
  }
  fire PreToolUse '{"hook_event_name":"PreToolUse","tool_name":"mcp__codebase-memory-mcp__search_graph","tool_use_id":"t1","tool_input":{"name_pattern":"foo"}}'
  fire PostToolUse '{"hook_event_name":"PostToolUse","tool_name":"mcp__codebase-memory-mcp__search_graph","tool_use_id":"t1","tool_input":{"name_pattern":"foo"},"duration_ms":12}'
  fire PreToolUse '{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"t2","tool_input":{"file_path":"/nope"}}'
  fire PostToolUseFailure '{"hook_event_name":"PostToolUseFailure","tool_name":"Read","tool_use_id":"t2","tool_input":{"file_path":"/nope"},"duration_ms":3,"error":"File does not exist."}'
  fire PreToolUse '{"hook_event_name":"PreToolUse","tool_name":"Bash","tool_use_id":"t3","tool_input":{"command":"cat a.sh"}}'
fi

envelope() {  # $1 = model id in modelUsage, $2 = structured_output or empty
  local so="$2"
  if [ -n "$so" ]; then so="\"structured_output\": $so,"; else so=""; fi
  cat <<JSON
{
  "type": "result", "subtype": "success", "is_error": false,
  "stop_reason": "tool_use", "terminal_reason": "completed",
  "num_turns": 4, "duration_ms": 47557, "total_cost_usd": 0.2844136,
  "permission_denials": [],
  $so
  "modelUsage": { "$1": {
      "inputTokens": 4, "outputTokens": 3921,
      "cacheReadInputTokens": 51158, "cacheCreationInputTokens": 58741,
      "costUSD": 0.2844136, "canonicalModel": "$1", "provider": "firstParty" } }
}
JSON
}
SO='{"navigation":"cmm","schema_change_detected":false,"contract_verification":[],
     "findings":[{"title":"t","area_file":"a.sh","line_low":1,"severity":"minor",
                  "relevance":"regression","status":"confirmed"}]}'

case "$mode" in
  nonzero)  echo "stub lens failure" >&2; exit 7 ;;
  hang)     exec sleep 120 ;;
  noschema) envelope "claude-opus-5" "" ;;
  garbage)  envelope "claude-opus-5" '{"nope":true}' ;;
  mismatch) envelope "claude-haiku-4-5" "$SO" ;;
  # A real envelope carries HELPER traffic alongside the reviewer's own model.
  # Picking the wrong key here reports the wrong model as the one that ran.
  #
  # These numbers are COPIED FROM A LIVE ENVELOPE (round 1153, the ui-styling
  # lens), and the shape is the whole point of the case. The earlier fixture gave
  # the reviewer `inputTokens: 40` and no cache fields at all, and the helper a
  # tiny 210-token output — so ANY rule picked the reviewer and the case could
  # not fail. Reality is the opposite on both axes:
  #
  #   reviewer:  in 12, cacheRead 345109, cacheCreate 54699,  out 3873
  #   helper:    in 73955, cacheRead 0,   cacheCreate 0,      out 4043
  #
  # The helper WINS on output by 4% and LOSES on input by 10x. A fixture that
  # does not reproduce that inversion is a fixture that cannot catch the defect
  # it exists for — which is exactly what happened: this suite was green while a
  # live round published "the ui-styling lens ran on claude-fable-5-1" to an MR.
  helper)
    cat <<JSON
{ "type":"result","subtype":"success","is_error":false,"stop_reason":"tool_use",
  "num_turns":4,"duration_ms":47557,"total_cost_usd":4.42,"permission_denials":[],
  "structured_output": $SO,
  "modelUsage": {
    "claude-fable-5-1": { "inputTokens": 73955, "outputTokens": 4043,
                          "cacheReadInputTokens": 0, "cacheCreationInputTokens": 0,
                          "costUSD": 1.62 },
    "claude-opus-5":    { "inputTokens": 12, "outputTokens": 3873,
                          "cacheReadInputTokens": 345109, "cacheCreationInputTokens": 54699,
                          "costUSD": 2.80 } } }
JSON
    ;;
  *)        envelope "claude-opus-5" "$SO" ;;
esac
STUB
  chmod +x "$bin/claude"
  echo "$root"
}

run_panel() {  # $1 root, rest: env assignments already exported by the caller
  local root="$1"; shift
  ( cd "$root/repo" && env PATH="$root/bin:$PATH" FAKE_LOG="$root/scratch" \
      bash "$root/plugin/lib/run-panel.sh" "$root/scratch" "$@" 2>"$root/panel.err" )
}

# --- clean panel --------------------------------------------------------------
p=$(mkpanel)
out=$(run_panel "$p"); rc=$?
eq "clean panel -> exit 0" "$rc" "0"
eq "  three lens files landed" "$(ls "$p/scratch"/lens-*.json 2>/dev/null | wc -l | tr -d ' ')" "3"
eq "  no failed-*.json"        "$(ls "$p/scratch"/failed-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
eq "  counter reached 3/3"     "$(awk -F'|' '{print $5"/"$6}' "$p/scratch/status")" "3/3"
eq "  phase is lenses during the panel" "$(awk -F'|' '{print $4}' "$p/scratch/status")" "lenses"
# The lens watchdog must not outlive its lens. Written as
# `( sleep N; kill ... ) &` the sleep is a CHILD of the subshell, so killing the
# watchdog orphans it for the rest of the fuse -- one per lens, six per round,
# still holding this script's descriptors. The stall value is per-run so a
# concurrent suite's orphans cannot be miscounted as this run's.
WSTALL=$(( 6000 + ($$ % 900) ))
q=$(mkpanel)
awk -F'|' -v n="$WSTALL" 'BEGIN{OFS="|"} {$9=n; print}' "$q/scratch/status" > "$q/s.t"
mv "$q/s.t" "$q/scratch/status"
run_panel "$q" >/dev/null 2>&1
eq "  watchdog fuse was read"      "$(awk -F'|' '{print $9}' "$q/scratch/status")" "$WSTALL"
sleep 1
# Both shapes: the `sleep` a subshell watchdog would orphan, and the perl
# watchdog itself. Either surviving the panel is the leak.
eq "  no orphaned watchdog sleep"  "$(ps -Ao args | grep -c "[s]leep $WSTALL")" "0"
eq "  no orphaned perl watchdog"   "$(ps -Ao args | grep -c "[p]erl.*$WSTALL")" "0"
rm -rf "$q"
eq "  lens payload is the structured_output, not the envelope" \
   "$(jq -r '.navigation' "$p/scratch/lens-contract-security.json")" "cmm"
# fanout + tree snapshots: absent, these two degrade to "no history row" and
# "tree_mutated=false" — an absent check reporting clean.
eq "  fanout stamp written"      "$([ -s "$p/scratch/fanout" ] && echo yes || echo no)" "yes"
eq "  tree-before.txt written"   "$([ -f "$p/scratch/tree-before.txt" ] && echo yes || echo no)" "yes"
eq "  tree-after.txt written"    "$([ -f "$p/scratch/tree-after.txt" ] && echo yes || echo no)" "yes"
eq "  lens-models-actual records the model that RAN" \
   "$(jq -r '."contract-security".model' "$p/scratch/panel-models.json")" "claude-opus-5"
eq "  ...and its cost, from the run record not a self-report" \
   "$(jq -r '."test-quality".cost_usd' "$p/scratch/panel-models.json")" "0.2844136"

# --- the invocation itself, asserted from what the CLI saw --------------------
argv=$(cat "$p/scratch/argv-contract-security.txt")
eq "  passes --strict-mcp-config" \
   "$(case "$argv" in *--strict-mcp-config*) echo yes ;; *) echo no ;; esac)" "yes"
eq "  passes --json-schema (the format is forced, not requested)" \
   "$(case "$argv" in *--json-schema*) echo yes ;; *) echo no ;; esac)" "yes"
eq "  passes --agent claude-qa-manager:qa-reviewer" \
   "$(case "$argv" in *"--agent claude-qa-manager:qa-reviewer"*) echo yes ;; *) echo no ;; esac)" "yes"
# Always an explicit --model: omitting it would inherit the operator's session
# model, which is how a Haiku session gets a Haiku panel (invariant 6).
eq "  passes --model review_model explicitly" \
   "$(case "$argv" in *"--model opus"*) echo yes ;; *) echo no ;; esac)" "yes"
# Up to six lenses run concurrently in ONE checkout; without this they all persist
# sessions into the same per-directory project slug, and nothing ever resumes one.
# Tool use is measured from tools-<lens>.jsonl, not from a transcript.
eq "  passes --no-session-persistence (six lenses, one checkout)" \
   "$(case "$argv" in *--no-session-persistence*) echo yes ;; *) echo no ;; esac)" "yes"

# The tree snapshot must carry HEAD and the branch name, not just porcelain: a
# concurrent round doing a CLEAN branch switch in the same working tree leaves
# porcelain byte-identical, and tree_mutated would compare equal.
eq "  snapshot carries HEAD" \
   "$(head -1 "$p/scratch/tree-before.txt" | grep -cE '^[0-9a-f]{40}$')" "1"
eq "  snapshot carries the branch name" \
   "$(sed -n 2p "$p/scratch/tree-before.txt")" "main"

# --- prompt composition -------------------------------------------------------
eq "  a prompt is composed per lens" "$(ls "$p/scratch"/prompt-*.txt | wc -l | tr -d ' ')" "3"
eq "  mandate arrives as a TITLED section, not a preamble" \
   "$(grep -c '^## Code navigation' "$p/scratch/prompt-regression-edges.txt")" "1"
eq "  proportionality arrives as a titled section" \
   "$(grep -c '^## Proportionality' "$p/scratch/prompt-regression-edges.txt")" "1"
eq "  the lens focus is the catalog's, verbatim" \
   "$(grep -c 'OWNS the Contract Verification table' "$p/scratch/prompt-contract-security.txt")" "1"
eq "  ...and each lens gets its OWN focus" \
   "$(grep -c 'OWNS the Contract Verification table' "$p/scratch/prompt-test-quality.txt")" "0"
eq "  contract path is offered by default" \
   "$(grep -c 'Contract / acceptance criteria' "$p/scratch/prompt-contract-security.txt")" "1"

# --- tool-call telemetry --------------------------------------------------------
# Lenses leave no transcript, so this log is the only record of what tools a lens
# called. The hook must reach the lens through --settings and nothing wider.
eq "  passes --settings panel-hooks.json" \
   "$(case "$argv" in *"--settings $p/scratch/panel-hooks.json"*) echo yes ;; *) echo no ;; esac)" "yes"
eq "  panel-hooks.json registers the log hook on Pre, Post and PostFailure" \
   "$(jq -r '[.hooks.PreToolUse, .hooks.PostToolUse, .hooks.PostToolUseFailure]
             | map(.[0].hooks[0].command | test("lib/lens-tool-log\\.sh")) | all' \
         "$p/scratch/panel-hooks.json")" "true"
eq "  every lens wrote its own log" \
   "$(ls "$p/scratch"/tools-*.jsonl 2>/dev/null | wc -l | tr -d ' ')" "3"
eq "  one line per hook event (2 + 2 + 1)" \
   "$(wc -l < "$p/scratch/tools-regression-edges.jsonl" | tr -d ' ')" "5"
eq "  the failure reason is kept" \
   "$(jq -r 'select(.ev == "PostToolUseFailure") | .err' "$p/scratch/tools-regression-edges.jsonl")" \
   "File does not exist."

rm -f "$p/scratch/tools-test-quality.jsonl"
summ=$(bash "$p/plugin/lib/lens-tools-summary.sh" "$p/scratch"); rc=$?
eq "  summary exits 0" "$rc" "0"
eq "  summary counts calls from PreToolUse" \
   "$(jq -r '.lenses."regression-edges".calls' <<<"$summ")" "3"
eq "  summary classes the calls (cmm/raw)" \
   "$(jq -r '.lenses."regression-edges".by_class | "\(.cmm)/\(.ctx)/\(.raw)/\(.other)"' <<<"$summ")" "1/0/2/0"
eq "  summary: a failed call is failed" \
   "$(jq -r '.lenses."regression-edges".failed' <<<"$summ")" "1"
eq "  summary: Pre with no Post is no_result (the blocked shape)" \
   "$(jq -r '.lenses."regression-edges".no_result' <<<"$summ")" "1"
eq "  summary: denied comes from the run record, not the log" \
   "$(jq -r '.lenses."regression-edges".denied' <<<"$summ")" "0"
eq "  summary sums Claude Code's own call durations" \
   "$(jq -r '.lenses."regression-edges".tool_ms' <<<"$summ")" "15"
# A zero is only readable next to the tool surface the lens actually had.
eq "  summary carries lens_mcp_state from the brief" \
   "$(jq -r '.lens_mcp_state' <<<"$summ")" "ok"
# Invariant 2: a lens with no log did not report zero tools -- it reported nothing.
eq "  summary: a lens with no log is not-recorded, not zero calls" \
   "$(jq -c '.lenses."test-quality"' <<<"$summ")" '{"state":"not-recorded"}'
rm -rf "$p"

# The hook exits 0 and writes no stdout in every case: stdout from a PreToolUse
# hook can be read as a decision, and a telemetry failure must never fail a lens.
hk="$REPO_SRC/lib/lens-tool-log.sh"
ht=$(mktemp -d)
pl='{"hook_event_name":"PreToolUse","tool_name":"Read","tool_use_id":"x","tool_input":{"file_path":"/a"}}'
o=$(printf '%s' "$pl" | env -u QA_LENS_LOG bash "$hk"); rc=$?
eq "lens-tool-log.sh without QA_LENS_LOG: exit 0" "$rc" "0"
eq "  ...no stdout" "$o" ""
o=$(printf '%s' "$pl" | QA_LENS_LOG="$ht/l.jsonl" bash "$hk"); rc=$?
eq "lens-tool-log.sh with QA_LENS_LOG: exit 0, no stdout" "$rc:$o" "0:"
eq "  ...one line appended" "$(wc -l < "$ht/l.jsonl" | tr -d ' ')" "1"
o=$(printf 'not json' | QA_LENS_LOG="$ht/l.jsonl" bash "$hk"); rc=$?
eq "lens-tool-log.sh on malformed input: still exit 0, no stdout" "$rc:$o" "0:"
o=$(printf '%s' "$pl" | QA_LENS_LOG="$ht/missing-dir/l.jsonl" bash "$hk" 2>&1); rc=$?
eq "lens-tool-log.sh with an unwritable log: still exit 0, silent" "$rc:$o" "0:"
rm -rf "$ht"

# A retried round must not append to last round's log: the scratch dir is keyed to
# the MR, not the round, so a stale log would double-count every call.
p=$(mkpanel)
printf '{"ev":"STALE"}\n' > "$p/scratch/tools-contract-security.jsonl"
run_panel "$p" >/dev/null
eq "round hygiene removes last round's tool log" \
   "$(grep -c STALE "$p/scratch/tools-contract-security.jsonl")" "0"
rm -rf "$p"

# --skip-contract-verification is a per-invocation flag preflight never sees.
# This case is why prompt composition lives in the driver and not in preflight.
p=$(mkpanel)
run_panel "$p" --skip-contract-verification >/dev/null
eq "--skip-contract-verification reaches the prompt" \
   "$(grep -c 'Contract: SKIPPED at user request' "$p/scratch/prompt-contract-security.txt")" "1"
rm -rf "$p"

# --- the mandate is ABSENT, not empty, when no graph tooling is registered ----
p=$(mkpanel)
rm -f "$p/scratch/tool-mandate.md"
out=$(run_panel "$p"); rc=$?
eq "absent tool-mandate -> panel still runs" "$rc" "0"
eq "  no empty Code navigation section" \
   "$(grep -c '^## Code navigation' "$p/scratch/prompt-test-quality.txt")" "0"
rm -rf "$p"

# A MISSING proportionality file is different: it always exists in production, so
# its absence is reported rather than passed over. A round run without it is not
# comparable to one run with it.
p=$(mkpanel)
rm -f "$p/scratch/proportionality.md"
run_panel "$p" >/dev/null
eq "missing proportionality is announced in the prompt" \
   "$(grep -c 'NOT AVAILABLE' "$p/scratch/prompt-test-quality.txt")" "1"
rm -rf "$p"

# --- every failure mode is distinguishable, and none reports clean ------------
# The shared assertion: a failed lens writes failed-<lens>.json and NOT
# lens-<lens>.json. round-return.sh derives failed_lenses as
# `preflight.lenses - basename(lens-*.json)`, so a failure file matching that
# glob would make a dead lens count as landed.
panel_failure_case() {  # $1 label, $2 FAKE_MODES, $3 expected state, $4 expected rc
  local p; p=$(mkpanel)
  FAKE_MODES="$2" run_panel "$p" >/dev/null; local rc=$?
  eq "$1 -> exit $4" "$rc" "$4"
  eq "  $1: state recorded" \
     "$(jq -r '.state' "$p/scratch/failed-contract-security.json" 2>/dev/null)" "$3"
  eq "  $1: no lens-contract-security.json" \
     "$([ -f "$p/scratch/lens-contract-security.json" ] && echo present || echo absent)" "absent"
  eq "  $1: the other two still landed" \
     "$(ls "$p/scratch"/lens-*.json 2>/dev/null | wc -l | tr -d ' ')" "2"
  rm -rf "$p"
}
panel_failure_case "nonzero exit"     "contract-security:nonzero"  "nonzero_exit"   1
panel_failure_case "no structured_output" "contract-security:noschema" "invalid_output" 1
panel_failure_case "wrong-shaped structured_output" "contract-security:garbage" "invalid_output" 1
# A wedged lens is today undetectable except by a stall heuristic. macOS has no
# timeout(1), so this proves the background+watchdog idiom actually fires.
panel_failure_case "watchdog kill"    "contract-security:hang"     "watchdog_killed" 1

# All three dead -> exit 3, distinct from a partial panel. A caller that treats
# every non-zero the same cannot tell "no review happened" from "most of it did".
p=$(mkpanel)
FAKE_MODES="contract-security:nonzero regression-edges:nonzero test-quality:nonzero" \
  run_panel "$p" >/dev/null; rc=$?
eq "whole panel dead -> exit 3" "$rc" "3"
eq "  nothing landed" "$(ls "$p/scratch"/lens-*.json 2>/dev/null | wc -l | tr -d ' ')" "0"
rm -rf "$p"

# --- a lens that RAN below the floor is not a review --------------------------
# The request said opus; the run record says haiku. Config describes intent, the
# envelope describes reality, and only reality is checked against the floor.
p=$(mkpanel)
FAKE_MODES="contract-security:mismatch" run_panel "$p" >/dev/null; rc=$?
eq "a lens that ran below the floor -> partial panel (exit 1)" "$rc" "1"
eq "  recorded as model_below_floor" \
   "$(jq -r '.state' "$p/scratch/failed-contract-security.json")" "model_below_floor"
# Landing it would count the lens as done — a sub-floor review reporting clean.
eq "  ...and its findings do NOT land" \
   "$([ -f "$p/scratch/lens-contract-security.json" ] && echo present || echo absent)" "absent"
eq "  the actual model is on the record" \
   "$(jq -r '."contract-security".model' "$p/scratch/panel-models.json")" "claude-haiku-4-5"
eq "  ...with model_check below_floor" \
   "$(jq -r '."contract-security".model_check' "$p/scratch/panel-models.json")" "below_floor"
rm -rf "$p"

# A swap WITHIN the allow-list is recorded, and the review still counts.
p=$(mkpanel)
sed -i.bak 's/^review_model=opus$/review_model=fable/' "$p/scratch/manager-brief.txt"
run_panel "$p" >/dev/null
eq "requested model is passed through" \
   "$(case "$(cat "$p/scratch/argv-test-quality.txt")" in *"--model fable"*) echo yes ;; *) echo no ;; esac)" "yes"
eq "  an allowed swap is RECORDED as model_mismatch" \
   "$(jq -r '.state' "$p/scratch/failed-contract-security.json")" "model_mismatch"
eq "  ...and its findings still land" \
   "$([ -f "$p/scratch/lens-contract-security.json" ] && echo present || echo absent)" "present"
rm -rf "$p"

# No model in the brief is the inherit case: the lens is never spawned. A brief
# preflight did not write (or an older one) must not reopen what preflight closed.
for _bad in 'review_model=' 'review_model=haiku'; do
  p=$(mkpanel)
  sed -i.bak "s/^review_model=opus\$/$_bad/" "$p/scratch/manager-brief.txt"
  run_panel "$p" >/dev/null; rc=$?
  eq "brief '$_bad' -> nothing landed (exit 3)" "$rc" "3"
  eq "  recorded as model_not_allowed" \
     "$(jq -r '.state' "$p/scratch/failed-contract-security.json")" "model_not_allowed"
  eq "  ...and claude was never invoked" \
     "$(ls "$p/scratch"/argv-*.txt 2>/dev/null | wc -l | tr -d ' ')" "0"
  rm -rf "$p"
done
p=$(mkpanel)
sed -i.bak '/^allowed_models=/d' "$p/scratch/manager-brief.txt"
run_panel "$p" >/dev/null
eq "brief with no allowed_models -> fails closed" \
   "$(jq -r '.state' "$p/scratch/failed-contract-security.json")" "model_not_allowed"
rm -rf "$p"
# jq's contains("") is always true, so an empty entry would admit every model.
p=$(mkpanel)
sed -i.bak -e 's/^allowed_models=.*/allowed_models=[""]/' -e 's/^review_model=opus$/review_model=haiku/' \
  "$p/scratch/manager-brief.txt"
run_panel "$p" >/dev/null
eq "brief allowed_models [\"\"] admits nothing" \
   "$(jq -r '.state' "$p/scratch/failed-contract-security.json")" "model_not_allowed"
rm -rf "$p"

# A real envelope carries helper traffic in modelUsage alongside the reviewer's
# own model. Picking the wrong key reports the wrong model as the one that ran —
# and a wrong model on the record is worse than none, because it looks checked.
p=$(mkpanel)
FAKE_MODES="contract-security:helper" run_panel "$p" >/dev/null
eq "the reviewer's model wins over helper traffic" \
   "$(jq -r '."contract-security".model' "$p/scratch/panel-models.json")" "claude-opus-5"
eq "  ...and the helper is still on the record" \
   "$(jq -r '."contract-security".all_models | sort | join(",")' "$p/scratch/panel-models.json")" \
   "claude-fable-5-1,claude-opus-5"
# The discriminator, asserted as a discriminator: on this envelope the helper
# out-produces the reviewer, so a rule that ranks by output tokens gets it
# BACKWARDS. Naming the losing rule here is what stops it being reinstated as a
# simplification.
eq "  ...even though the helper emitted MORE output tokens" \
   "$(jq -r 'if (.modelUsage["claude-fable-5-1"].outputTokens
                 > .modelUsage["claude-opus-5"].outputTokens) then "yes" else "no" end' \
        "$p/scratch/raw-contract-security.json")" "yes"
eq "  model_check is allowed for a frontier reviewer" \
   "$(jq -r '."contract-security".model_check' "$p/scratch/panel-models.json")" "allowed"
rm -rf "$p"

# --- stale files from the PREVIOUS round must not count as this round's work --
# $QA_SCRATCH is keyed to the MR, not the round.
p=$(mkpanel)
echo '{"navigation":"cmm"}' > "$p/scratch/lens-contract-security.json"
FAKE_MODES="contract-security:nonzero" run_panel "$p" >/dev/null
eq "a stale lens file does not survive into the new round" \
   "$([ -f "$p/scratch/lens-contract-security.json" ] && echo present || echo absent)" "absent"
rm -rf "$p"

# --- REGRESSION: the driver must not eat the config it is about to pass -------
# First live round, 2026-09-04: preflight wrote lens-mcp.json, run-panel.sh's
# round hygiene (`rm -f "$S"/lens-*.json`) deleted it microseconds later, and all
# four lenses died instantly with "MCP config file not found" while preflight.json
# still said lens_mcp_state=ok. Two independent fixes, and BOTH are asserted here
# because either alone would have prevented it and neither alone is sufficient in
# general: the file left the `lens-*` namespace, and the cleanup deletes by name.
p=$(mkpanel)
run_panel "$p" >/dev/null
eq "the mcp config survives the driver's round hygiene" \
   "$([ -f "$p/scratch/panel-mcp.json" ] && echo present || echo DELETED)" "present"
# The rename matters beyond deletion: `lens-*.json` is also what lens-landed.sh
# counts for the progress denominator and what round-return.sh:101 uses to derive
# failed_lenses, so a config under that prefix reports as a landed lens.
eq "  ...and is not counted as a landed lens" \
   "$(ls "$p/scratch"/lens-*.json 2>/dev/null | wc -l | tr -d ' ')" "3"
rm -rf "$p"
# The name-driven cleanup, proven independently of the rename: a decoy file under
# the old glob must survive, because the driver no longer sweeps by wildcard.
p=$(mkpanel)
printf '{"decoy":true}\n' > "$p/scratch/lens-mcp.json"
run_panel "$p" >/dev/null
eq "cleanup deletes by NAME, so an unknown lens-*.json is left alone" \
   "$([ -f "$p/scratch/lens-mcp.json" ] && echo present || echo DELETED)" "present"
rm -rf "$p"

# --- REGRESSION: panel-models.json must parse even when every lens failed ------
# jq on a ZERO-BYTE file prints nothing and exits 0, so `jq … || printf null`
# never fires. The first live round produced `"contract-security": ,` — not JSON,
# in the file whose entire job is to record what actually ran.
p=$(mkpanel)
FAKE_MODES="contract-security:nonzero regression-edges:nonzero test-quality:nonzero" \
  run_panel "$p" >/dev/null
eq "panel-models.json is valid JSON with every lens dead" \
   "$(jq -e . "$p/scratch/panel-models.json" >/dev/null 2>&1 && echo valid || echo INVALID)" "valid"
eq "  ...and a dead lens is recorded as null, not omitted" \
   "$(jq -r '."contract-security"' "$p/scratch/panel-models.json")" "null"
rm -rf "$p"

# --- a lens name with no catalog entry is fatal, never an invented mandate ----
p=$(mkpanel)
sed -i.bak 's/"test-quality"/"no-such-lens"/' "$p/scratch/manager-brief.txt"
run_panel "$p" >/dev/null
eq "unknown lens -> recorded, not invented" \
   "$(jq -r '.state' "$p/scratch/failed-no-such-lens.json")" "unknown_lens"
eq "  no prompt was composed for it" \
   "$([ -f "$p/scratch/prompt-no-such-lens.txt" ] && echo present || echo absent)" "absent"
rm -rf "$p"

# --- the catalog must cover every name preflight can emit --------------------
# These two lists drifting apart is invisible until a real round selects the
# conditional lens that was never added here.
_known=$(sed -n "s/^KNOWN_LENS_NAMES_RE=.*(\(.*\)).*/\1/p" "$PREFLIGHT_SRC" | tr '|' ' ')
eq "preflight's lens-name enum is readable" \
   "$(printf '%s' "$_known" | wc -w | tr -d ' ')" "7"
for _n in $_known; do
  eq "catalog covers preflight's lens '$_n'" \
     "$(jq -r --arg n "$_n" 'has($n)' "$REPO_SRC/config/lens-catalog.json")" "true"
done

# --- the `lens-*.json` glob is a namespace, not just a filename --------------
# round-return.sh:101 derives failed_lenses as `preflight.lenses - basename(
# lens-*.json)` and lens-landed.sh counts the same glob for the progress
# denominator. Any OTHER file the driver writes under that prefix reports as a
# landed lens. This is not hypothetical: the driver's own run record was called
# lens-models-actual.json for exactly one test run, and every panel came back
# one lens over.
p=$(mkpanel)
run_panel "$p" >/dev/null
for _f in "$p"/scratch/lens-*.json; do
  _b=$(basename "$_f" .json); _b=${_b#lens-}
  eq "  lens-*.json holds only real lenses ($_b)" \
     "$(printf '%s' '["contract-security","regression-edges","test-quality"]' \
        | jq -r --arg n "$_b" 'index($n) != null')" "true"
done
rm -rf "$p"

# --- lens-mcp.json: generated from THIS machine's registration ---------------
# It cannot be a shipped file: --mcp-config takes launch commands, which are
# machine-local. The cases below drive the real preflight and assert on what it
# wrote, because "registered" and "launchable" are two different questions and
# the whole point of the block is that it answers the second one.
echo "[lens-mcp.json — the pinned lens tool surface]"

# (a) nothing registered -> an EMPTY config with a state that says so, never a
# config that merely looks fine.
r=$(mkfixture "feature/x" "main")
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "unregistered -> the mcp config is still written" "$([ -f "$lm" ] && echo yes || echo no)" "yes"
# It must NOT be named lens-*.json: that namespace is swept and counted elsewhere.
eq "  ...and it is outside the lens-* namespace" \
   "$(case "$(basename "$lm")" in lens-*) echo INSIDE ;; *) echo outside ;; esac)" "outside"
eq "  ...with no servers"   "$(jq -r '.mcpServers | length' "$lm")" "0"
eq "  ...and state says so" "$(jq -r '.tooling.lens_mcp_state' <<<"$out")" "none:not-registered"
rm -rf "$r"

# (b) a plain mcpServers registration -> the LAUNCH COMMAND is carried over, not
# just the name. A config naming a server with no command starts nothing.
r=$(mkfixture "feature/x" "main")
cat > "$r/repo/.mcp.json" <<'JSON'
{ "mcpServers": { "codebase-memory-mcp": { "command": "/opt/bin/cmm", "args": ["--stdio"] } } }
JSON
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "registered server is resolved to a launch command" \
   "$(jq -r '.mcpServers["codebase-memory-mcp"].command' "$lm")" "/opt/bin/cmm"
eq "  args carried through"  "$(jq -r '.mcpServers["codebase-memory-mcp"].args[0]' "$lm")" "--stdio"
eq "  state ok"              "$(jq -r '.tooling.lens_mcp_state' <<<"$out")" "ok"
# --strict-mcp-config means what is absent is unreachable, so an unrelated
# account connector must not be carried into the lens.
cat > "$r/repo/.mcp.json" <<'JSON'
{ "mcpServers": { "codebase-memory-mcp": { "command": "/opt/bin/cmm" },
                  "some-account-connector": { "command": "/opt/bin/other" } } }
JSON
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "  an unrelated connector is NOT carried into the lens" \
   "$(jq -r '.mcpServers | has("some-account-connector")' "$lm")" "false"
rm -rf "$r"

# (c) registered but UNLAUNCHABLE. This is the case the two fields exist for: an
# enabledPlugins entry proves registration and carries no command, so the mandate
# would name a tool the lens cannot reach.
r=$(mkfixture "feature/x" "main")
cat > "$r/repo/.claude/settings.json" <<'JSON'
{ "enabledPlugins": { "context-mode@somewhere": true } }
JSON
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "registered-but-unlaunchable -> reported, not silently dropped" \
   "$(jq -r '.tooling.lens_mcp_state' <<<"$out")" "partial:context-mode"
eq "  ...and ctx still reads as AVAILABLE (registration is a different question)" \
   "$(jq -r '.tooling.ctx_available' <<<"$out")" "true"
eq "  ...so the config is empty and the divergence is the finding" \
   "$(jq -r '.mcpServers | length' "$lm")" "0"
eq "  ...and it warns" \
   "$(jq -r '[.warnings[]?|select(startswith("lens_mcp_unresolved"))]|length' <<<"$out")" "1"
rm -rf "$r"

# (d) a plugin-provided server: the command lives in the PLUGIN's .mcp.json,
# written against ${CLAUDE_PLUGIN_ROOT}. Passing that placeholder through
# unexpanded hands the lens subprocess a path that resolves to the wrong plugin,
# or under --strict-mcp-config to nothing.
r=$(mkfixture "feature/x" "main")
pcache="$r/home/.config/claude-code/plugins/cache/mkt/context-mode/1.0.0"
mkdir -p "$pcache/.claude-plugin"
printf '{"name":"context-mode","version":"1.0.0"}\n' > "$pcache/.claude-plugin/plugin.json"
cat > "$pcache/.mcp.json" <<'JSON'
{ "mcpServers": { "context-mode": { "command": "node",
    "args": ["${CLAUDE_PLUGIN_ROOT}/start.mjs"] } } }
JSON
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "plugin-provided server is resolved from a sibling .mcp.json" \
   "$(jq -r '.mcpServers["context-mode"].command' "$lm")" "node"
eq "  \${CLAUDE_PLUGIN_ROOT} is expanded to the plugin's own dir" \
   "$(jq -r '.mcpServers["context-mode"].args[0]' "$lm")" "$pcache/start.mjs"
rm -rf "$r"

# (e) the OTHER declaration site: `mcpServers` inline in plugin.json. Both are
# real and a plugin may use either — context-mode uses this one, so checking only
# the sibling file reported `partial:context-mode` on a machine where the server
# was perfectly launchable. Found by looking at a real install, not by reasoning.
r=$(mkfixture "feature/x" "main")
pcache="$r/home/.config/claude-code/plugins/cache/mkt/context-mode/1.0.0"
mkdir -p "$pcache/.claude-plugin"
cat > "$pcache/.claude-plugin/plugin.json" <<'JSON'
{ "name": "context-mode", "version": "1.0.0",
  "mcpServers": { "context-mode": { "command": "node",
    "args": ["${CLAUDE_PLUGIN_ROOT}/start.mjs"] } } }
JSON
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "server declared INSIDE plugin.json is resolved too" \
   "$(jq -r '.mcpServers["context-mode"].command' "$lm")" "node"
eq "  ...with the placeholder expanded" \
   "$(jq -r '.mcpServers["context-mode"].args[0]' "$lm")" "$pcache/start.mjs"
eq "  ...and the state is ok, not partial" \
   "$(jq -r '.tooling.lens_mcp_state' <<<"$out")" "ok"
rm -rf "$r"

# (f) a DIRECTORY-source marketplace. Claude Code runs such a plugin from the
# marketplace's installLocation and never from the cache, and a stale cache copy
# may still sit there from an earlier install -- the shape of a real machine,
# where only the cache was searched and every round reported partial:context-mode.
# The directory must win, because it is what actually launches.
r=$(mkfixture "feature/x" "main")
cfg="$r/home/.config/claude-code"
src="$r/ctx-src"
mkdir -p "$src/.claude-plugin" "$cfg/plugins"
printf '{"enabledPlugins": {"context-mode@ctxmkt": true}}\n' > "$cfg/settings.json"
jq -n --arg l "$src" '{ctxmkt: {source: {source: "directory", path: $l}, installLocation: $l}}' \
  > "$cfg/plugins/known_marketplaces.json"
printf '{"name":"ctxmkt","plugins":[{"name":"context-mode","source":"./"}]}\n' \
  > "$src/.claude-plugin/marketplace.json"
cat > "$src/.claude-plugin/plugin.json" <<'JSON'
{ "name": "context-mode", "mcpServers": { "context-mode": { "command": "node",
    "args": ["${CLAUDE_PLUGIN_ROOT}/start.mjs"] } } }
JSON
stale="$cfg/plugins/cache/ctxmkt/context-mode/0.9.0.backup"
mkdir -p "$stale/.claude-plugin"
cp "$src/.claude-plugin/plugin.json" "$stale/.claude-plugin/plugin.json"
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "directory-source plugin: state is ok, not partial" \
   "$(jq -r '.tooling.lens_mcp_state' <<<"$out")" "ok"
eq "  ...launched from the marketplace dir, not the stale cache copy" \
   "$(jq -r '.mcpServers["context-mode"].args[0]' "$lm")" "$src/start.mjs"
# An object source (github, git) is fetched elsewhere, so the directory search must
# pass it by and leave the cache to answer.
printf '{"name":"ctxmkt","plugins":[{"name":"context-mode","source":{"source":"github","repo":"x/y"}}]}\n' \
  > "$src/.claude-plugin/marketplace.json"
out=$(run_preflight "$r" 73 mono)
lm=$(jq -r '.tooling.lens_mcp_path' <<<"$out")
eq "  an object source defers to the cache" \
   "$(jq -r '.mcpServers["context-mode"].args[0]' "$lm")" "$stale/start.mjs"
rm -rf "$r"

# --- the schema is a wire payload as well as documentation -------------------
eq "lens-schema.json survives comment-stripping" \
   "$(jq -c 'del(.. | objects | ."$comment")' "$REPO_SRC/config/lens-schema.json" >/dev/null 2>&1 && echo ok || echo broken)" "ok"
# Every required key is one round-return.sh actually reads. A schema that stops
# requiring `schema_change_detected` silently un-arms the Step 3E schema gate.
for _k in navigation schema_change_detected findings; do
  eq "  schema requires $_k" \
     "$(jq -r --arg k "$_k" '[.required[]] | index($k) != null' "$REPO_SRC/config/lens-schema.json")" "true"
done

# ===========================================================================
# lib/gate-approve.sh — the Step 3E preconditions, as a gate that FAILS CLOSED
#
# The property under test is not "does it approve a good round" but "does it
# refuse everything it cannot see". Every case below that ends in `refuse` is one
# the prose version could have waved through, because reading a rule is not the
# same as evaluating it.
# ===========================================================================
echo "[gate-approve.sh — approval preconditions, failing closed]"

GATE_SRC="$REPO_SRC/lib/gate-approve.sh"

mkgate() {  # $1 = jq filter over the base preflight.json -> echoes root dir
  local root; root=$(mktemp -d)
  local S="$root/scratch" repo="$root/repo" bin="$root/bin" plug="$root/plugin"
  mkdir -p "$S" "$repo" "$bin" "$plug"
  cp "$GATE_SRC" "$plug/gate-approve.sh"
  # The REAL forge seam, as everywhere else in this suite: stubbing it would test
  # a copy of the logic. $PATH is what gets stubbed, one layer lower.
  cp "$REPO_SRC/lib/forge.sh" "$REPO_SRC/lib/forge-gitlab.sh" "$REPO_SRC/lib/forge-github.sh" "$plug/"
  git init -q -b main "$repo"
  git -C "$repo" config user.email t@t.t; git -C "$repo" config user.name t
  echo x > "$repo/a"; git -C "$repo" add a; git -C "$repo" commit -qm init
  git -C "$repo" remote add origin 'git@host.invalid:grp/proj.git'
  local head; head=$(git -C "$repo" rev-parse HEAD)
  jq -n --arg t "$repo" --arg h "$head" '{
      mr: 7, project: "grp/proj", remote: "origin", target_abs: $t,
      mr_author: "devuser", expected_qa_user: "qa-bot",
      qa_token_ok: true, approval_eligible: true,
      schema: { detected: false },
      qa_token_env: "GATE_TEST_TOKEN", qa_token_file: "/nonexistent"
    }' | jq "${1:-.}" > "$S/preflight.json"
  # glab stub, shaped like the ones the forge_head_ci block already uses: the
  # GitLab backend reads `.head_pipeline` off `merge_requests/<n>`, NOT a
  # /pipelines endpoint. A stub answering the wrong endpoint returns `none`, and
  # `none` is a legitimate blocking answer — so the mistake looked exactly like a
  # working gate refusing correctly, which is why it survived a whole run.
  #
  # The approvals endpoint also matches `merge_requests/<n>`, so it is matched
  # FIRST; reversing these two silently feeds pipeline JSON to the approvers
  # parser.
  cat > "$bin/glab" <<STUB
#!/usr/bin/env bash
ST="\${GATE_CI_STATUS:-success}"
SHA="\${GATE_CI_SHA:-$head}"
case "\$*" in
  *approvals*|*approval_state*)
      printf '%s\n' "\${GATE_APPROVALS:-\$(jq -nc '{approved_by:[]}')}" ;;
  *"merge_requests/7"*)
      if [ "\$ST" = "none" ]; then jq -nc --arg s "\$SHA" '{sha:\$s}'
      else jq -nc --arg t "\$ST" --arg s "\$SHA" '{head_pipeline:{status:\$t,sha:\$s},sha:\$s}'; fi ;;
  *)  echo '{}' ;;
esac
STUB
  chmod +x "$bin/glab"
  echo "$root"
}
run_gate() { local root="$1"; shift
  ( cd "$root/repo" && env PATH="$root/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
      bash "$root/plugin/gate-approve.sh" "$root/scratch" "$@" 2>/dev/null ); }

# --- the happy path, so the refusals below mean something --------------------
g=$(mkgate)
out=$(run_gate "$g" --round-blocking false); rc=$?
eq "clean round, CI green on HEAD -> approve" "$(jq -r '.decision' <<<"$out")" "approve"
eq "  ...and exit code agrees"                "$rc" "0"
eq "  ...with zero blockers"                  "$(jq -r '.blockers' <<<"$out")" "0"
rm -rf "$g"

# --- a missing input is UNEVALUABLE, never "assume clean" ---------------------
g=$(mkgate)
out=$(run_gate "$g"); rc=$?
eq "no --round-blocking -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
eq "  ...and it is unevaluable, not fail" \
   "$(jq -r '.reasons[]|select(.check=="round-clean")|.state' <<<"$out")" "unevaluable"
eq "  ...exit 1"                   "$rc" "1"
rm -rf "$g"

# --- each precondition refuses on its own ------------------------------------
gate_case() {  # $1 label, $2 preflight jq mutation, $3 env prefix, $4 expected failing check
  local g; g=$(mkgate "$2")
  local out; out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok $3 \
      bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false 2>/dev/null )
  eq "$1 -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
  # `fail`, not merely "not pass": every case here is a value the gate READ, and
  # reporting a read `false` as `unevaluable` tells the operator the input is
  # missing when it is present.
  eq "  ...blamed on $4" \
     "$(jq -r --arg c "$4" '[.reasons[]|select(.check==$c and .state=="fail")]|length' <<<"$out")" "1"
  rm -rf "$g"
}
gate_case "no QA token"              '.qa_token_ok = false'       ''  qa-token
gate_case "not approval-eligible"    '.approval_eligible = false' ''  approval-eligible
# Blocking findings take --round-blocking true, so it needs its own call rather
# than gate_case's fixed `--round-blocking false`.
g=$(mkgate)
out=$(run_gate "$g" --round-blocking true)
eq "blocking findings -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
eq "  ...blamed on round-clean" \
   "$(jq -r '[.reasons[]|select(.check=="round-clean" and .state=="fail")]|length' <<<"$out")" "1"
rm -rf "$g"
# CI: every non-success answer blocks, and they are DIFFERENT answers. Reporting an
# unrun pipeline as a failure sends someone hunting a defect that does not exist.
gate_case "CI still running"         '.' 'GATE_CI_STATUS=running'     ci
gate_case "CI failed"                '.' 'GATE_CI_STATUS=failed'      ci
gate_case "no CI at all"             '.' 'GATE_CI_STATUS=none'        ci
# `canceled` is deliberately NOT `failed`: there is no verdict to act on, so the
# operator is told to re-run rather than sent hunting a defect.
gate_case "pipeline cancelled"       '.' 'GATE_CI_STATUS=canceled'    ci

# The sha mismatch is its own case: CI PASSED, but on different code. That is
# worse than no answer, and a gate that only checks `status == success` waves it
# through — which is precisely the round that was approved while the pipeline for
# its own fix commit was still running.
g=$(mkgate)
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   GATE_CI_SHA=0000000000000000000000000000000000000000 \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false 2>/dev/null )
eq "CI green on the WRONG sha -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
eq "  ...matches_head is false"          "$(jq -r '.ci.matches_head' <<<"$out")" "false"
rm -rf "$g"

# --- schema MRs need a HUMAN approval: anyone but the QA agent ----------------
# The QA agent's own approval must never satisfy "a human approved". The MR
# author does satisfy it: the policy is a human sign-off, not a second person.
g=$(mkgate '.schema.detected = true')
out=$(run_gate "$g" --round-blocking false --schema-ack true)
eq "schema MR, no approver at all -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
rm -rf "$g"

g=$(mkgate '.schema.detected = true')
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   GATE_APPROVALS='{"approved_by":[{"user":{"username":"qa-bot"}}]}' \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false --schema-ack true 2>/dev/null )
eq "schema MR approved only by the QA agent -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
eq "  ...blamed on the human-approval check" \
   "$(jq -r '[.reasons[]|select(.check=="schema-human-approval" and .state=="fail")]|length' <<<"$out")" "1"
rm -rf "$g"

g=$(mkgate '.schema.detected = true')
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   GATE_APPROVALS='{"approved_by":[{"user":{"username":"devuser"}}]}' \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false --schema-ack true 2>/dev/null )
eq "schema MR approved by its own author -> approve" "$(jq -r '.decision' <<<"$out")" "approve"
rm -rf "$g"

g=$(mkgate '.schema.detected = true')
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   GATE_APPROVALS='{"approved_by":[{"user":{"username":"a-real-human"}}]}' \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false --schema-ack true 2>/dev/null )
eq "schema MR with a third-party approver -> approve" "$(jq -r '.decision' <<<"$out")" "approve"
rm -rf "$g"

# An unacknowledged rollout checklist blocks even with a human approval present.
g=$(mkgate '.schema.detected = true')
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   GATE_APPROVALS='{"approved_by":[{"user":{"username":"a-real-human"}}]}' \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false 2>/dev/null )
eq "schema MR without --schema-ack -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
rm -rf "$g"

# --- the deferred-findings exit rests on the NOTE, not on absence of findings --
g=$(mkgate)
out=$(run_gate "$g" --round-blocking true --deferred-exit true)
eq "deferred exit with no note URL -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
out=$(run_gate "$g" --round-blocking true --deferred-exit true --deferred-note-url "https://x.invalid/n/1")
eq "deferred exit WITH the enumerating note -> approve" "$(jq -r '.decision' <<<"$out")" "approve"
rm -rf "$g"

# --- fails closed when it cannot see at all ----------------------------------
# No forge CLI on PATH: the probe cannot run, so CI and approvers are unknown.
# "I could not ask" must never read as "the answer was yes".
# The gate still needs jq and git to run AT ALL, so remove only `glab` rather than
# emptying $PATH — an empty $PATH tests "the script cannot start", which is a
# different and much weaker claim.
g=$(mkgate)
rm -f "$g/bin/glab"
out=$( cd "$g/repo" && env PATH="$g/bin:$PATH" QA_FORGE=gitlab GATE_TEST_TOKEN=tok \
   bash "$g/plugin/gate-approve.sh" "$g/scratch" --round-blocking false 2>/dev/null )
eq "no forge CLI reachable -> refuse" "$(jq -r '.decision' <<<"$out")" "refuse"
eq "  ...and says unevaluable, not failed" \
   "$(jq -r '[.reasons[]|select(.state=="unevaluable")]|length >= 1' <<<"$out")" "true"
rm -rf "$g"

# ===========================================================================
# The SAST helper gets an ABSOLUTE target path
#
# Reported from a live cycle: on every mobile MR the SAST step came back
# `skipped:helper-failed`. Preflight passed the target's RELATIVE path
# (`apps/mobile`) and the helper resolves it against its own cwd — which is
# wherever the operator invoked /qa-cycle, since preflight never cd's globally
# (every git call is `(cd "$TARGET_ABS" && …)` in a subshell). Start a session
# inside the submodule you are working on and the helper looks for
# `<submodule>/apps/mobile`, fails its `[ -d ]` check, and the round loses its
# SAST delta entirely.
#
# This fixture reproduces the MECHANISM (cwd is not the repo root) with a plain
# subdirectory rather than a real submodule. That is the whole of the bug —
# REPO_ROOT is already superproject-aware via --show-superproject-working-tree —
# but it does mean this case would not catch a future submodule-specific defect.
# ===========================================================================
echo "[SAST helper receives a path it can actually resolve]"
r=$(mkfixture "feature/x" "main" \
    '.targets.sub = {"path":"apps/thing","base_branch":"main","remote":"origin","scope":"sub","security_stage":true}')
mkdir -p "$r/repo/apps/thing"
echo x > "$r/repo/apps/thing/f.txt"
git -C "$r/repo" add -A >/dev/null 2>&1; git -C "$r/repo" commit -qm subdir >/dev/null 2>&1
tplog="$r/target-path.log"
# cwd = the subdirectory, i.e. the "already inside the submodule" case.
out=$( cd "$r/repo/apps/thing" && env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
        HOME="$r/home" CLAUDE_CONFIG_DIR="$r/home/.config/claude-code" \
        PATH="$r/bin:$PATH" SAST_TP_LOG="$tplog" \
        bash "$r/plugin/lib/preflight.sh" 73 sub 2>/dev/null )
eq "invoked from a subdirectory, the helper's path resolves" \
   "$(sed -n 2p "$tplog" 2>/dev/null)" "resolvable"
eq "  ...because it is absolute" \
   "$(case "$(sed -n 1p "$tplog" 2>/dev/null)" in /*) echo absolute ;; *) echo RELATIVE ;; esac)" "absolute"
# basename alone was too weak to fail: `apps/thing` and the correct absolute path
# share it. Assert the whole path against the real directory.
eq "  ...and it is exactly the target dir, not a doubled path" \
   "$(sed -n 1p "$tplog" 2>/dev/null)" "$(cd "$r/repo/apps/thing" && pwd -P)"
eq "  ...so the gate is not helper-failed" \
   "$(jq -r '.sast.gate_state' <<<"$out")" "clean"
rm -rf "$r"

# --- the spine must REACH the gate, and must not restate its conditions -------
# A gate nothing calls is prose, which is the failure mode that produced
# lens-landed.sh sitting unused for a day. And a spine that still lists the
# conditions gives the model a second, drifting copy to satisfy instead.
# $SKILL_MD is defined at the top of this file. $SKILL_SRC is the TEST directory,
# not the skill directory — an easy and silent mistake: every assertion below
# passed a nonexistent path to grep, which returns 0 matches, which reads as
# "the spine does not call the gate". Wrong for the right-looking reason.
APPROVAL_MD="$REPO_SRC/skills/qa-cycle/references/approval.md"
eq "Step 3E calls gate-approve.sh" \
   "$( [ "$(grep -c 'gate-approve\.sh' "$SKILL_MD")" -ge 1 ] && echo yes || echo no )" "yes"
eq "  ...and says a refusal ends the step" \
   "$( grep -qiE 'refuse. ends Step 3E|there is no reading of' "$SKILL_MD" && echo yes || echo no )" "yes"
# The live-CI rationale must survive the move (invariant 3: a rule keeps its why).
eq "  ...and keeps the why for probing CI live" \
   "$( grep -qi 'pipeline_status. predates\|predates this round' "$SKILL_MD" && echo yes || echo no )" "yes"
eq "approval.md points at the gate rather than being the gate" \
   "$( [ "$(grep -c 'gate-approve\.sh' "$APPROVAL_MD")" -ge 1 ] && echo yes || echo no )" "yes"
# A path that does not exist greps 0 and reads as a real failure, so assert the
# files are actually there — otherwise this whole block can pass vacuously the
# moment someone moves them.
eq "  ...and both files exist to be checked" \
   "$( [ -f "$SKILL_MD" ] && [ -f "$APPROVAL_MD" ] && echo yes || echo no )" "yes"

# --- usage errors are exit 2, distinct from a refusal -------------------------
eq "no scratch dir -> exit 2" \
   "$(bash "$GATE_SRC" 2>/dev/null; echo $?)" "2"
eq "scratch dir without preflight.json -> exit 2" \
   "$(bash "$GATE_SRC" "$(mktemp -d)" 2>/dev/null; echo $?)" "2"

# ---------------------------------------------------------------------------
# lib/set-phase.sh — the status line survives a manager that writes prose
# ---------------------------------------------------------------------------
# WHY. qa-manager.md said "set phase to merging, then rendering, posting" and
# "use Bash, not the Write tool", and never said the file is nine pipe-delimited
# fields. The manager wrote the sentence it was given, on two consecutive live
# rounds, in two sessions, through two different tools:
#
#   printf 'phase=lenses round=1 lenses=0/5\n' > .../status
#
# Nothing caught it, because all three writers COPIED FIELDS 1-3 THROUGH from the
# file — so the prose was preserved into the mr field by every one of them for the
# rest of the round, and statusline-fragment.sh rendered `QA !phase=lenses round=1
# lenses=0/5  r` at the operator.
SETPHASE_SRC="$REPO_SRC/lib/set-phase.sh"

mkstatus() {   # a scratch dir with a brief, and whatever status line $1 says
  local d; d=$(mktemp -d)
  cat > "$d/manager-brief.txt" <<'BRIEF'
target_abs=/repo/apps/api
target=api
mr=42
round=3
lenses=["contract-security","regression-edges","test-quality"]
BRIEF
  [ -n "${1:-}" ] && printf '%s\n' "$1" > "$d/status"
  echo "$d"
}
f() { awk -F'|' -v n="$2" '{print $n}' "$1/status"; }

# --- the repair, which is the whole point ------------------------------------
d=$(mkstatus 'phase=lenses round=1 lenses=0/5')
bash "$SETPHASE_SRC" "$d" lenses >/dev/null
eq "prose status -> mr is REBUILT from the brief, not preserved" "$(f "$d" 1)" "42"
eq "  ...target too"                                            "$(f "$d" 2)" "api"
eq "  ...and round"                                             "$(f "$d" 3)" "3"
eq "  ...phase is what was asked for"                           "$(f "$d" 4)" "lenses"
eq "  ...total comes from the brief's lens array"               "$(f "$d" 6)" "3"
eq "  ...and the line is nine fields again" \
   "$(awk -F'|' '{print NF}' "$d/status")" "9"
rm -rf "$d"

# --- the counter is counted, never carried -----------------------------------
d=$(mkstatus '42|api|3|lenses|0|3|1700000000|/repo/apps/api|1200')
echo '{}' > "$d/lens-contract-security.json"; echo '{}' > "$d/lens-test-quality.json"
bash "$SETPHASE_SRC" "$d" merging >/dev/null
eq "done is counted from disk, not passed in" "$(f "$d" 5)" "2"
eq "  epoch_start is preserved across a transition" "$(f "$d" 7)" "1700000000"
rm -rf "$d"

# --- round-return's zeroing regression ---------------------------------------
# Round 1153 finished as `…|done|0|0|0||1200`: every `${_d:-0}` in round-return.sh
# faithfully preserved a field the manager had already destroyed, including the
# epoch start that elapsed time is measured from.
d=$(mkstatus 'phase=returning round=2 lenses=5/5')
bash "$SETPHASE_SRC" "$d" done >/dev/null
eq "a destroyed epoch_start is replaced, not preserved as 0" \
   "$( [ "$(f "$d" 7)" -gt 0 ] 2>/dev/null && echo positive || echo ZERO )" "positive"
eq "  ...and target_abs comes back" "$(f "$d" 8)" "/repo/apps/api"
rm -rf "$d"

# --- refusals: an invented phase is not a phase -------------------------------
d=$(mkstatus '42|api|3|lenses|0|3|1700000000|/repo/apps/api|1200')
eq "an unknown phase is refused (exit 2)" \
   "$(bash "$SETPHASE_SRC" "$d" 'phase=lenses round=1' >/dev/null 2>&1; echo $?)" "2"
eq "  ...and the good line is left untouched" "$(f "$d" 4)" "lenses"
eq "no phase argument -> exit 2" "$(bash "$SETPHASE_SRC" "$d" >/dev/null 2>&1; echo $?)" "2"
eq "no scratch dir -> exit 2"    "$(bash "$SETPHASE_SRC" >/dev/null 2>&1; echo $?)" "2"
rm -rf "$d"

# --- keep-phase records `unknown` rather than guessing or blanking ------------
# Invariant 2 in miniature: an empty phase field is indistinguishable from one
# nobody set, and substituting `lenses` would hand merge work the LONG stall fuse.
d=$(mkstatus 'phase=lenses round=1 lenses=0/5')
bash "$SETPHASE_SRC" "$d" - >/dev/null 2>&1
eq "unrecognisable phase + keep -> 'unknown', not empty" "$(f "$d" 4)" "unknown"
rm -rf "$d"
d=$(mkstatus '42|api|3|rendering|0|3|1700000000|/repo/apps/api|1200')
bash "$SETPHASE_SRC" "$d" - >/dev/null
eq "  ...but a real phase IS preserved by keep" "$(f "$d" 4)" "rendering"
rm -rf "$d"

# --- no brief (a scratch dir from before this landed) -------------------------
d=$(mkstatus '9|web|2|lenses|0|4|1700000000|/a/b|900'); rm -f "$d/manager-brief.txt"
bash "$SETPHASE_SRC" "$d" merging >/dev/null
eq "with no brief the existing fields are kept" "$(f "$d" 1)/$(f "$d" 2)/$(f "$d" 3)" "9/web/2"
eq "  ...including the project's own stall tolerance" "$(f "$d" 9)" "900"
rm -rf "$d"

# --- lens-landed delegates, and heals the line on the way through -------------
d=$(mkstatus 'phase=lenses round=1 lenses=0/5')
echo '{"navigation":"cmm"}' | bash "$SETPHASE_SRC" "$d" lenses >/dev/null
echo '{"navigation":"cmm"}' | bash "$REPO_SRC/lib/lens-landed.sh" "$d" contract-security >/dev/null
eq "lens-landed leaves a nine-field line" "$(awk -F'|' '{print NF}' "$d/status")" "9"
eq "  ...with the mr repaired"            "$(f "$d" 1)" "42"
eq "  ...and the counter advanced"        "$(f "$d" 5)" "1"
eq "  ...and the findings saved"          \
   "$([ -f "$d/lens-contract-security.json" ] && echo present || echo absent)" "present"
rm -rf "$d"

# --- only ONE script may write this line --------------------------------------
# The copy-through existed in three places, which is why one bad write spread.
# preflight.sh seeds it; set-phase.sh owns every change after that.
eq "exactly two files write the nine-field status line" \
   "$(grep -rl "printf '%s|%s|%s|" "$REPO_SRC/lib" | sed 's:.*/::' | sort | tr '\n' ',')" \
   "preflight.sh,set-phase.sh,"

# --- the instruction that caused it, in every place it appears (invariant 4) ---
# $MANAGER_MD and $SEQ are the ones defined for the status-format block above;
# a second pair of names for the same two files is how the two blocks drift.
QA_MANAGER_MD="$MANAGER_MD"
SEQ_MD="$SEQ"
eq "the manager is told to call set-phase.sh" \
   "$( [ "$(grep -c 'set-phase\.sh' "$QA_MANAGER_MD")" -ge 1 ] && echo yes || echo no )" "yes"
eq "  ...and told NOT to write the file itself" \
   "$( grep -qi 'never write that file yourself\|Never write .status. by hand' "$QA_MANAGER_MD" \
       && echo yes || echo no )" "yes"
eq "  ...and no longer told to rewrite it with Bash" \
   "$( grep -qi 'Rewrite it at every transition even when' "$QA_MANAGER_MD" && echo STALE || echo gone )" "gone"
eq "the sequential path calls set-phase.sh too" \
   "$( [ "$(grep -c 'set-phase\.sh' "$SEQ_MD")" -ge 1 ] && echo yes || echo no )" "yes"
eq "  ...and no longer carries a raw nine-field printf" \
   "$( grep -q "printf '%s|%s|%s|reviewing" "$SEQ_MD" && echo STALE || echo gone )" "gone"
# Both files must exist, or every grep above scores 0 and reads as a real failure.
eq "  ...and both files exist to be checked" \
   "$( [ -f "$QA_MANAGER_MD" ] && [ -f "$SEQ_MD" ] && echo yes || echo no )" "yes"

# --- Agent spawns (the manager; sequential and fix-review lenses) --------------
# An Agent subagent with no `model:` inherits the caller's, so a Haiku session
# would run the manager and every sequential lens on Haiku. The pin must be on
# the allow-list the driver enforces, or the two paths disagree about the floor.
for _agent in qa-manager qa-reviewer; do
  _pin=$(sed -n '/^---$/,/^---$/s/^model: *//p' "$REPO_SRC/agents/$_agent.md")
  eq "agents/$_agent.md pins an allowed model" \
     "$(jq -r --arg m "$_pin" '.review.allowed_models | any(. as $p | $m | ascii_downcase | contains($p))' "$REPO_SRC/config/defaults.json")" "true"
done

# --- the note is where a wrong model actually reached a human ------------------
# panel-models.json is only half the defect: round-note.md is the consumer that
# published "the ui-styling lens ran on <helper>" to an MR. Fixing the producer
# without the renderer leaves the sentence that did the damage available.
NOTE_MD="$REPO_SRC/skills/qa-cycle/references/round-note.md"
eq "round-note.md exists to be checked" \
   "$( [ -f "$NOTE_MD" ] && echo yes || echo no )" "yes"
eq "  the model line drops null entries (a dead lens is not a model)" \
   "$( grep -q 'select(\. != null)' "$NOTE_MD" && echo yes || echo no )" "yes"
eq "  ...and a downgrade is reported from model_mismatch, not inferred" \
   "$( grep -q 'model_check' "$NOTE_MD" && echo yes || echo no )" "yes"
# Run the filter EXTRACTED FROM THE DOC, not a copy of it pasted here. A copy
# would keep passing after someone edited the doc, which is the failure mode this
# suite's header is about.
_pmfix=$(mktemp -d)/pm.json
printf '{"a":{"model":"claude-opus-5"},"b":null,"c":{"model":"claude-opus-5"}}\n' > "$_pmfix"
_notejq=$(sed -n "s/.*jq -r '\(\[\.\[\][^']*\)'.*/\1/p" "$NOTE_MD")
eq "  ...and the filter is extractable from the doc" \
   "$( [ -n "$_notejq" ] && echo yes || echo no )" "yes"
eq "  ...and yields the model, not 'null'" \
   "$(jq -r "$_notejq" "$_pmfix" 2>&1)" "claude-opus-5"

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
