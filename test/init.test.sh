#!/usr/bin/env bash
# init.test.sh — hermetic tests for lib/init.sh.
#
# Run:  bash test/init.test.sh      (MUST be bash; see preflight.test.sh header)
#
# Same design rule as the preflight suite: drive the REAL script and assert on
# what it does to the filesystem. Never re-implement its logic here.
#
# No network and no real credentials. The token path is exercised with a stub
# forge CLI on PATH, so a verification success and a verification FAILURE can
# both be tested without a live token.
set -uo pipefail

SUITE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_SRC="$(cd "$SUITE_DIR/.." && pwd)"
INIT="$REPO_SRC/lib/init.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ -n "${2:-}" ] && printf '        %s\n' "$2"; }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$3], got [$2]"; fi; }

strip() { sed 's/\x1b\[[0-9;]*m//g'; }

mkrepo() { # $1 remote url (optional)
  local d; d=$(mktemp -d)
  git init -q -b main "$d"
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  [ -n "${1:-}" ] && git -C "$d" remote add origin "$1"
  printf '%s' "$d"
}

echo "init.sh tests"

# ---------------------------------------------------------------------------
echo "[forge detection]"
for pair in "https://gitlab.com/o/r.git|GitLab" "git@github.com:o/r.git|GitHub"; do
  url="${pair%%|*}"; want="${pair##*|}"
  d=$(mkrepo "$url")
  got=$( cd "$d" && bash "$INIT" check 2>&1 | strip | grep -c "forge: $want" )
  eq "detects $want from remote" "$got" "1"
  rm -rf "$d"
done
d=$(mkrepo)
got=$( cd "$d" && bash "$INIT" check 2>&1 | strip | grep -c "no 'origin' remote" )
eq "no remote -> reported, not guessed" "$got" "1"
rm -rf "$d"

# ---------------------------------------------------------------------------
echo "[check is read-only]"
d=$(mkrepo "https://gitlab.com/o/r.git")
before=$( cd "$d" && find . -path ./.git -prune -o -type f -print | sort | md5 2>/dev/null || \
          ( cd "$d" && find . -path ./.git -prune -o -type f -print | sort | md5sum ) )
( cd "$d" && bash "$INIT" check >/dev/null 2>&1 )
after=$( cd "$d" && find . -path ./.git -prune -o -type f -print | sort | md5 2>/dev/null || \
         ( cd "$d" && find . -path ./.git -prune -o -type f -print | sort | md5sum ) )
eq "check writes nothing" "$before" "$after"
rm -rf "$d"

# ---------------------------------------------------------------------------
echo "[config: writes, merges, never clobbers]"
d=$(mkrepo "https://gitlab.com/o/r.git"); cfg="$d/.claude/skills/qa-cycle/config.json"
( cd "$d" && QA_INIT_SCHEMA_FILES="db/template.sql, db/extra.sql" QA_INIT_ASSUME_YES=1 \
    bash "$INIT" config </dev/null >/dev/null 2>&1 )
eq "config file created"        "$( [ -f "$cfg" ] && echo yes || echo no )" "yes"
eq "  both schema files stored" "$(jq -r '.schema.files|join(",")' "$cfg")" "db/template.sql,db/extra.sql"
eq "  whitespace trimmed"       "$(jq -r '.schema.files[1]' "$cfg")" "db/extra.sql"

# The merge promise: an unrelated key added by hand must survive a re-run.
jq '.targets = {"api":{"path":"apps/api"}}' "$cfg" > "$cfg.t" && mv "$cfg.t" "$cfg"
( cd "$d" && QA_INIT_SCHEMA_FILES="db/only.sql" QA_INIT_ASSUME_YES=1 \
    bash "$INIT" config </dev/null >/dev/null 2>&1 )
eq "  re-run preserves unrelated keys" "$(jq -c '.targets' "$cfg")" '{"api":{"path":"apps/api"}}'
eq "  re-run updates schema"           "$(jq -r '.schema.files|join(",")' "$cfg")" "db/only.sql"
eq "  result is valid JSON"            "$(jq empty "$cfg" 2>&1; echo $?)" "0"
rm -rf "$d"

# A corrupt existing config must stop, not be silently overwritten.
d=$(mkrepo "https://gitlab.com/o/r.git"); cfg="$d/.claude/skills/qa-cycle/config.json"
mkdir -p "$(dirname "$cfg")"; printf 'not json{' > "$cfg"
( cd "$d" && QA_INIT_SCHEMA_FILES="x.sql" QA_INIT_ASSUME_YES=1 bash "$INIT" config </dev/null >/dev/null 2>&1 )
rc=$?
eq "corrupt existing config -> non-zero exit" "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"
eq "  and the file is untouched"              "$(cat "$cfg")" "not json{"
rm -rf "$d"

# ---------------------------------------------------------------------------
echo "[token: verified before storage, never stored in the repo]"
# Stub forge CLI: succeeds only for the magic token, so both branches are real.
mkstub() { # $1 bindir
  mkdir -p "$1"
  cat > "$1/glab" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *"auth status"*)
    if [ "${GITLAB_TOKEN:-}" = "good-token" ]; then
      echo "Logged in to gitlab.com as qa-bot" >&2; exit 0
    fi
    echo "HTTP 401" >&2; exit 1 ;;
esac
exit 0
SH
  chmod +x "$1/glab"
}

d=$(mkrepo "https://gitlab.com/o/r.git"); bin="$d/bin"; mkstub "$bin"
cfgdir="$d/home/.config/claude-qa-manager"
( cd "$d" && HOME="$d/home" PATH="$bin:$PATH" QA_AGENT_TOKEN="good-token" \
    bash "$INIT" token </dev/null >/dev/null 2>&1 )
eq "valid token stored"        "$( [ -s "$cfgdir/qa-agent-token" ] && echo yes || echo no )" "yes"
eq "  stored content matches"  "$(cat "$cfgdir/qa-agent-token" 2>/dev/null)" "good-token"
mode=$(stat -f '%Lp' "$cfgdir/qa-agent-token" 2>/dev/null || stat -c '%a' "$cfgdir/qa-agent-token" 2>/dev/null)
eq "  mode is 600"             "$mode" "600"
eq "  expected_username recorded" "$(jq -r '.qa_agent.expected_username' "$cfgdir/config.json" 2>/dev/null)" "qa-bot"
# The whole point: nothing lands inside the repository.
# Exclude ./bin: the stub forge CLI legitimately contains the token literal in
# its own comparison, and matching it is a false positive, not a leak.
leak=$( cd "$d" && grep -rl 'good-token' . --exclude-dir=home --exclude-dir=.git --exclude-dir=bin 2>/dev/null | head -1 )
eq "  token NOT written into the repo" "${leak:-none}" "none"
rm -rf "$d"

# A token that does NOT verify must be REJECTED, not stored. A stored-but-wrong
# token is worse than none: the plugin looks configured and silently posts under
# the developer's identity instead.
d=$(mkrepo "https://gitlab.com/o/r.git"); bin="$d/bin"; mkstub "$bin"
cfgdir="$d/home/.config/claude-qa-manager"
( cd "$d" && HOME="$d/home" PATH="$bin:$PATH" QA_AGENT_TOKEN="bad-token" \
    bash "$INIT" token </dev/null >/dev/null 2>&1 )
rc=$?
eq "unverifiable token -> non-zero exit" "$( [ "$rc" -ne 0 ] && echo yes || echo no )" "yes"
eq "  and is NOT stored"                 "$( [ -e "$cfgdir/qa-agent-token" ] && echo stored || echo absent )" "absent"
rm -rf "$d"

# The user config layer is $HOME-relative and deliberately NOT XDG-aware, because
# `qa_agent.token_file` is a $HOME-relative literal that preflight expands. If
# init.sh alone honoured XDG_CONFIG_HOME the two would diverge: the token would be
# stored where preflight never looks, and preflight would report "no token" on a
# repo that was correctly initialised. Point XDG at a decoy and assert it is
# ignored, so re-introducing XDG-awareness here fails loudly rather than silently.
d=$(mkrepo "https://gitlab.com/o/r.git"); bin="$d/bin"; mkstub "$bin"
cfgdir="$d/home/.config/claude-qa-manager"
( cd "$d" && HOME="$d/home" XDG_CONFIG_HOME="$d/decoy" PATH="$bin:$PATH" \
    QA_AGENT_TOKEN="good-token" bash "$INIT" token </dev/null >/dev/null 2>&1 )
eq "XDG_CONFIG_HOME ignored: token under \$HOME" "$( [ -s "$cfgdir/qa-agent-token" ] && echo yes || echo no )" "yes"
eq "  and nothing written to the XDG decoy"      "$( [ -e "$d/decoy" ] && echo written || echo absent )" "absent"
rm -rf "$d"

# ---------------------------------------------------------------------------
# A project whose fixes cannot be run is the tail-chasing generator: the fix ships
# unverified and the NEXT round's panel pays to discover it was wrong. init is
# where that gets said, because the fix belongs in the project, not in this config.
echo "[verify entry point is reported per target]"
d=$(mkrepo "https://gitlab.com/o/r.git")
out=$( cd "$d" && bash "$INIT" check 2>&1 | strip )
eq "no test entry -> NONE FOUND"      "$(grep -c 'NONE FOUND' <<<"$out")" "1"
eq "  and is not reported as ok"      "$(grep -c '✔ tests' <<<"$out")" "0"
eq "  and points at the project"      "$(grep -c "Do NOT work around it" <<<"$out")" "1"
printf 'test:\n\techo hi\n' > "$d/Makefile"
out=$( cd "$d" && bash "$INIT" check 2>&1 | strip )
eq "detected -> reported with source" "$(grep -c 'tests: make test' <<<"$out")" "1"
rm -rf "$d"

# Every configured target is checked, not just the first: in a monorepo the whole
# point is that one submodule can have tests while its sibling has none.
d=$(mkrepo "https://gitlab.com/o/r.git")
mkdir -p "$d/apps/a" "$d/apps/b" "$d/.claude/skills/qa-cycle"
printf 'test:\n\techo hi\n' > "$d/apps/a/Makefile"
cat > "$d/.claude/skills/qa-cycle/config.json" <<'JSON'
{"targets":{"a":{"path":"apps/a"},"b":{"path":"apps/b"}}}
JSON
out=$( cd "$d" && bash "$INIT" check 2>&1 | strip )
eq "target with tests reported ok"    "$(grep -c "tests for 'a': make test" <<<"$out")" "1"
eq "sibling without tests warned"     "$(grep -c "tests for 'b': NONE FOUND" <<<"$out")" "1"
rm -rf "$d"

# ---------------------------------------------------------------------------
echo "[unconfigured schema gate is reported loudly]"
d=$(mkrepo "https://gitlab.com/o/r.git"); cfg="$d/.claude/skills/qa-cycle/config.json"
mkdir -p "$(dirname "$cfg")"; echo '{"targets":{}}' > "$cfg"
out=$( cd "$d" && bash "$INIT" check 2>&1 | strip )
eq "warns when schema.files is empty" "$(grep -c 'skipped:not-configured' <<<"$out")" "1"
eq "  and says it is not a pass"      "$(grep -c 'never ran' <<<"$out")" "1"
rm -rf "$d"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
