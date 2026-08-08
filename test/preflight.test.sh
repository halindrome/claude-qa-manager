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

  # gh stub — the GitHub counterpart, emitting GITHUB's native shape so that
  # forge-github.sh's normalization is what the assertions actually exercise.
  # Stubbing the normalized shape here instead would re-implement the mapping in
  # the test and assert against the copy: 41/41 green while the real mapping is
  # broken. That is the failure this file's header exists to warn about.
  #   GH_STUB_USER      -> the authenticated login (ownership)
  #   GH_STUB_APPROVER  -> a login to place in the reviews list (MR_APPROVED seed)
  #   GH_STUB_NOTES     -> raw JSON array for the issue-comments endpoint
  #   GH_STUB_NOTES_EXIT-> non-zero to make the notes probe FAIL
  cat > "$bin/gh" <<SH
#!/usr/bin/env bash
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
eq "  and the spine says one per commit" "$(grep -c 'ONE LINE PER COMMIT' "$REPO_SRC/skills/qa-cycle/SKILL.md")" "1"
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

mkdir -p "$d/empty"
eq "bare directory -> none-found"    "$(dv "$d/empty" .state)" "none-found"
eq "missing directory -> none-found" "$(bash "$DETECT" "$d/nope" | jq -r .state)" "none-found"
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
rm -rf "$r"

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
# `canceled` carries no verdict: it must not read as pass OR as a fixable failure.
head_ci_case gitlab glab 'git@gitlab.com:grp/proj.git' "$(_gl canceled)" unknown cafe123
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
#
# BOTH helpers, not just the GitLab one. preflight's classifier is shared, so a
# phrase reworded on one side only silently drops that forge into
# skipped:unknown — a whole forge losing its security gate with every test still
# green. Checking one helper is what would let that ship.
for helper_forge in gitlab github; do
  HELPER="$REPO_SRC/lib/fetch-sast-${helper_forge}.sh"
  if [ -f "$HELPER" ]; then
    for phrase in "No pipeline associated with MR" "No security stage detected" \
                  "Security scans are still in progress" "## NEW SAST findings"; do
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

echo "[lens enum <-> qa-manager catalog agreement]"
# The !73 precedent: a fix added two SAST gate_states to the producer but not its
# consumer, hard-exiting a routine clean round. Same producer/consumer shape here
# — preflight's enum is the producer, the manager's catalog is the consumer.
MANAGER_MD="$REPO_SRC/agents/qa-manager.md"
if [ -f "$MANAGER_MD" ]; then
  enum=$(grep -oE '\^\(contract-security\|[a-z|-]+\)\$' "$PREFLIGHT_SRC" | head -1 \
    | sed -E 's/^\^\((.*)\)\$$/\1/' | tr '|' '\n' | sort -u)
  catalog=$(grep -oE '^- \*\*[a-z-]+\*\*' "$MANAGER_MD" | sed -E 's/^- \*\*([a-z-]+)\*\*/\1/' | sort -u)
  if [ -z "$enum" ]; then bad "lens enum extracted from preflight" "regex found nothing — update the test"
  elif [ -z "$catalog" ]; then bad "lens catalog extracted from qa-manager.md" "found nothing — update the test"
  elif [ "$enum" = "$catalog" ]; then ok "preflight lens enum == qa-manager catalog"
  else bad "preflight lens enum == qa-manager catalog" "$(diff <(echo "$enum") <(echo "$catalog") | tr '\n' ' ')"; fi
else
  bad "qa-manager.md present" "not found at $MANAGER_MD"
fi

# ---------------------------------------------------------------------------
echo "[status-line format agrees across BOTH review paths]"
# The manager owns the round on the default path; the sequential fallback owns it for
# a tiny diff or when Agent nesting is unavailable. Both now write the same status
# file, so the field list has to stay identical in both documents — preflight seeds
# 9 fields and either writer dropping one silently breaks project scoping or the
# stall threshold. Extract from the real docs; do not restate the format here.
MGR="$REPO_SRC/agents/qa-manager.md"; SEQ="$REPO_SRC/skills/qa-cycle/references/sequential-and-multimodel.md"
# Count the SEPARATORS, not the %s: each writer stamps its own phase as a literal
# (`|preflight|0|`, `|lenses|`, `|reviewing|`), so a format string is not all %s.
fields() { local fmt; fmt=$(grep -ohE "printf '[^']*\|[^']*\\\\n'" "$1" | grep '|%s' | head -1)
           echo $(( $(printf '%s' "$fmt" | tr -cd '|' | wc -c | tr -d ' ') + 1 )); }
eq "preflight seeds 9 status fields"  "$(fields "$REPO_SRC/lib/preflight.sh")" "9"
eq "  manager path writes 9"          "$(fields "$MGR")" "9"
eq "  sequential path writes 9"       "$(fields "$SEQ")" "9"
# Both must be told to preserve the preflight-resolved fields rather than re-derive.
for f in epoch_start target_abs lens_stall; do
  eq "  manager preserves $f"    "$(grep -c "$f" "$MGR")" "$( [ "$(grep -c "$f" "$MGR")" -ge 1 ] && grep -c "$f" "$MGR" || echo 0 )"
  eq "  sequential mentions $f"  "$( [ "$(grep -c "$f" "$SEQ")" -ge 1 ] && echo yes || echo no )" "yes"
done
# Both writers must CLEAR the previous round's per-lens files. The scratch dir is
# keyed to the MR, not the round, so leftovers read as this round's results —
# observed live: `ls lens-*.json` showed 6 on a round that had finished 2.
for doc in "$MGR" "$SEQ"; do
  eq "  $(basename "$doc") clears stale lens files" \
     "$( grep -c 'rm -f .*lens-\*\.json' "$doc" )" "1"
done
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

# ---------------------------------------------------------------------------
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
