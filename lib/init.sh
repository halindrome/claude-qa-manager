#!/usr/bin/env bash
# init.sh — set up a project (and this machine) to use claude-qa-manager.
#
# Subcommands:
#   check    report what is present/missing; changes NOTHING (default when piped)
#   config   write/update the project config at .claude/skills/qa-cycle/config.json
#   token    store and VERIFY a QA agent token, user-level, never in the repo
#   all      check, then config, then token   (default when interactive)
#
# Design rules, learned from the thing this was extracted from:
#   - Idempotent. Re-running must be safe. Existing config is MERGED, never
#     clobbered, and the merge is shown before it is written.
#   - Credentials never touch the repo. The token goes to the user config dir
#     with mode 600, and is VERIFIED against the expected username before this
#     script claims success. A stored-but-wrong token is worse than none: the
#     round silently posts under the developer's identity instead.
#   - An unanswered question is reported, not guessed. In particular a project
#     with no schema.files gets a loud note, because that gate is inert until
#     someone answers and silence there is the documented failure mode.
set -uo pipefail

PLUGIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/claude-qa-manager"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_yel=$'\033[33m'; c_dim=$'\033[2m'; c_rst=$'\033[0m'
ok()   { printf '  %s✔%s %s\n' "$c_grn" "$c_rst" "$1"; }
warn() { printf '  %s!%s %s\n' "$c_yel" "$c_rst" "$1"; }
bad()  { printf '  %s✗%s %s\n' "$c_red" "$c_rst" "$1"; }
info() { printf '  %s%s%s\n' "$c_dim" "$1" "$c_rst"; }
die()  { printf '%sinit: %s%s\n' "$c_red" "$1" "$c_rst" >&2; exit 1; }

# --- repo + forge detection -------------------------------------------------
# Superproject first: inside a submodule, --show-toplevel returns the submodule
# root, and every monorepo target path is relative to the superproject.
REPO_ROOT="$(git rev-parse --show-superproject-working-tree 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$REPO_ROOT" ] || die "not inside a git repository (cwd: $(pwd))"
PROJECT_CONFIG="$REPO_ROOT/.claude/skills/qa-cycle/config.json"

detect_forge() {
  local url; url="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null || true)"
  case "$url" in
    *gitlab*) echo gitlab ;;
    *github*) echo github ;;
    "")       echo none ;;
    *)        echo unknown ;;
  esac
}

cmd_check() {
  echo "claude-qa-manager — environment check"
  echo
  info "repo root: $REPO_ROOT"

  local forge; forge="$(detect_forge)"
  case "$forge" in
    gitlab) ok "forge: GitLab (from origin remote)" ;;
    github) ok "forge: GitHub (from origin remote)" ;;
    none)   warn "no 'origin' remote — the forge cannot be detected; QA needs one" ;;
    *)      warn "origin remote is neither GitLab nor GitHub; forge support is limited" ;;
  esac

  for t in git jq; do
    command -v "$t" >/dev/null 2>&1 && ok "found: $t" || bad "MISSING: $t (required)"
  done

  case "$forge" in
    gitlab)
      if command -v glab >/dev/null 2>&1; then
        ok "found: glab"
        if glab auth status >/dev/null 2>&1; then ok "glab is authenticated"
        else bad "glab is NOT authenticated — run: glab auth login"; fi
      else bad "MISSING: glab (required for GitLab)"; fi ;;
    github)
      if command -v gh >/dev/null 2>&1; then
        ok "found: gh"
        if gh auth status >/dev/null 2>&1; then ok "gh is authenticated"
        else bad "gh is NOT authenticated — run: gh auth login"; fi
      else bad "MISSING: gh (required for GitHub)"; fi ;;
  esac

  for t in unzip curl; do
    command -v "$t" >/dev/null 2>&1 && ok "found: $t (optional)" \
      || warn "missing: $t (optional — needed for security-scan / second-opinion features)"
  done

  echo
  if [ -f "$PROJECT_CONFIG" ]; then
    if jq empty "$PROJECT_CONFIG" 2>/dev/null; then
      ok "project config: $PROJECT_CONFIG"
      local nschema; nschema=$(jq -r '[.schema.files[]?] | length' "$PROJECT_CONFIG" 2>/dev/null || echo 0)
      if [ "${nschema:-0}" -gt 0 ]; then ok "schema gate: $nschema file(s) configured"
      else
        warn "schema gate: NOT configured — it will report skipped:not-configured"
        info "that is not a pass; it means the check never ran. See docs/CONFIGURING.md"
      fi
    else
      bad "project config exists but is NOT valid JSON: $PROJECT_CONFIG"
    fi
  else
    warn "no project config (fine — branches derive from the MR/PR at runtime)"
    info "run '$0 config' to create one if you need targets or the schema gate"
  fi

  if [ -f "$CONFIG_DIR/config.json" ]; then ok "user config: $CONFIG_DIR/config.json"
  else info "no user config (optional; holds credentials + policy)"; fi

  local tf="$CONFIG_DIR/qa-agent-token"
  if [ -s "$tf" ]; then
    local mode; mode=$(stat -f '%Lp' "$tf" 2>/dev/null || stat -c '%a' "$tf" 2>/dev/null || echo "?")
    if [ "$mode" = "600" ]; then ok "QA agent token present (mode $mode)"
    else warn "QA agent token present but mode is $mode — should be 600. Fix: chmod 600 $tf"; fi
  else
    info "no QA agent token — round notes will post under your own identity and"
    info "approval will be skipped entirely. Run '$0 token' to set one up."
  fi
}

# --- project config ---------------------------------------------------------
cmd_config() {
  local schema_files="${QA_INIT_SCHEMA_FILES:-}"   # comma-separated, or prompt
  local existing='{}'
  if [ -f "$PROJECT_CONFIG" ]; then
    jq empty "$PROJECT_CONFIG" 2>/dev/null || die "existing config is not valid JSON: $PROJECT_CONFIG"
    existing="$(cat "$PROJECT_CONFIG")"
    info "merging into existing config (nothing is removed)"
  fi

  if [ -z "$schema_files" ] && [ -t 0 ]; then
    echo
    echo "Schema gate: path(s) that ARE the schema — the file(s) a provisioner reads"
    echo "to create a new instance (e.g. db/template.sql). Changes to these require"
    echo "human approval. Leave blank to skip; the gate then reports that it did not run."
    printf 'schema file(s), comma-separated: '
    read -r schema_files || schema_files=""
  fi

  local addition='{}'
  if [ -n "$schema_files" ]; then
    addition=$(jq -nc --arg csv "$schema_files" \
      '{schema: {files: ($csv | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0)))}}')
  fi

  local merged
  merged=$(jq -s '.[0] * .[1]' <(printf '%s' "$existing") <(printf '%s' "$addition")) \
    || die "config merge failed"

  echo
  echo "Resulting $PROJECT_CONFIG:"
  printf '%s\n' "$merged" | sed 's/^/    /'

  if [ -t 0 ] && [ "${QA_INIT_ASSUME_YES:-}" != "1" ]; then
    printf 'write it? [y/N] '; local a; read -r a || a=n
    case "$a" in y|Y|yes) ;; *) echo "aborted; nothing written"; return 0 ;; esac
  fi

  mkdir -p "$(dirname "$PROJECT_CONFIG")"
  printf '%s\n' "$merged" > "$PROJECT_CONFIG"
  ok "wrote $PROJECT_CONFIG"
  info "this file belongs in version control — it contains no secrets"
}

# --- QA agent token ---------------------------------------------------------
cmd_token() {
  local forge; forge="$(detect_forge)"
  local tf="$CONFIG_DIR/qa-agent-token"

  echo
  echo "QA agent token (optional)"
  echo
  echo "A separate identity for QA-attributed actions — round notes and approvals."
  echo "Fix commits and pushes always use YOUR credentials, never this one."
  echo "Without it the plugin still works: notes post under your identity and"
  echo "approval is skipped."
  echo
  info "stored at $tf (mode 600). Never written into the repository."
  echo

  local token=""
  if [ -t 0 ]; then
    # -s so the token is not echoed to the terminal or captured in scrollback.
    printf 'paste the token (input hidden, blank to skip): '
    read -rs token || token=""
    echo
  else
    token="${QA_AGENT_TOKEN:-}"
  fi
  [ -n "$token" ] || { warn "no token provided — skipping"; return 0; }

  # Verify BEFORE storing. A stored-but-wrong token is worse than no token: the
  # plugin would silently fall back to the dev identity while looking configured.
  local resolved=""
  case "$forge" in
    gitlab) command -v glab >/dev/null 2>&1 && \
      resolved=$(GITLAB_TOKEN="$token" glab auth status 2>&1 | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1) ;;
    github) command -v gh >/dev/null 2>&1 && \
      resolved=$(GH_TOKEN="$token" gh api user --jq '.login' 2>/dev/null | head -1) ;;
  esac

  if [ -z "$resolved" ]; then
    bad "could not verify the token against $forge — NOT storing it"
    info "check the token's scopes and that the forge CLI is installed and reachable"
    return 1
  fi
  ok "token verifies as: $resolved"

  umask 077
  mkdir -p "$CONFIG_DIR"
  printf '%s' "$token" > "$tf"
  chmod 600 "$tf"
  ok "stored $tf (mode 600)"

  # Record the identity so preflight can detect a token that silently changes
  # owner later -- it compares the resolved user against expected_username.
  local ucfg="$CONFIG_DIR/config.json"
  local base='{}'; [ -f "$ucfg" ] && jq empty "$ucfg" 2>/dev/null && base="$(cat "$ucfg")"
  jq -s --arg u "$resolved" '.[0] * {qa_agent: {expected_username: $u}}' \
     <(printf '%s' "$base") > "$ucfg.tmp" && mv "$ucfg.tmp" "$ucfg"
  ok "recorded expected_username=$resolved in $ucfg"
}

case "${1:-}" in
  check)  cmd_check ;;
  config) cmd_config ;;
  token)  cmd_token ;;
  all|"") cmd_check; if [ -t 0 ]; then cmd_config; cmd_token; else
            echo; info "not interactive — run 'config' and 'token' from a terminal"; fi ;;
  -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) die "unknown subcommand '$1' (try: check | config | token | all)" ;;
esac
