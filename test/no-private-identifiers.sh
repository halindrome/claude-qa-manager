#!/usr/bin/env bash
# no-private-identifiers.sh — fail if internal identifiers or secret-shaped literals
# appear anywhere in the tree.
#
# This repo was extracted from a private implementation. Git history is permanent, so the
# scrub has to hold on EVERY commit, not just the first one. CI runs this on each push.
#
# MUST run under bash explicitly. The default interactive shell on macOS is zsh, which does
# NOT word-split unquoted "$VAR" expansions -- a scan written for bash and run under zsh
# silently collapses its file list into one bogus filename, greps nothing, and reports
# all-clean. That exact bug produced a false all-clear while this repo was being prepared.
# Everything below therefore uses arrays with "${arr[@]}", never bare word splitting.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# Patterns that must never appear. Split into two classes so failures explain themselves.
private_identifiers=(
  'redacted-1'
  'redacted-2'
  'redacted-3'
  'redacted-4'
  'halindrome\.com'
)
secret_shapes=(
  'glpat-[A-Za-z0-9_-]{10,}'      # GitLab PAT
  'gh[pousr]_[A-Za-z0-9]{20,}'    # GitHub token
  'sk-[A-Za-z0-9]{20,}'           # OpenAI-style key
  'AKIA[0-9A-Z]{16}'              # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# This file necessarily CONTAINS the patterns it searches for, so exclude it by name.
excludes=(
  --exclude-dir=.git
  --exclude-dir=node_modules
  --exclude="no-private-identifiers.sh"
)

fail=0

scan() {
  local label="$1"; shift
  local -a patterns=("$@")
  local p hits
  for p in "${patterns[@]}"; do
    # -I skips binary files; -n gives reviewable output.
    if hits=$(grep -rniE "${excludes[@]}" -I -n -- "$p" . 2>/dev/null); then
      printf '\n[%s] pattern matched: %s\n' "$label" "$p" >&2
      printf '%s\n' "$hits" | head -20 >&2
      fail=1
    fi
  done
}

scan "private identifier" "${private_identifiers[@]}"
scan "possible secret"    "${secret_shapes[@]}"

# A hardcoded home path is not a private identifier, so every scan above ships it
# green -- but it is dead for every installer who is not the author. It reached
# agents/*.md exactly once, rewriting `docs/CASE-STUDIES.md` and
# `skills/qa-cycle/references/round-note.md` into /Users/<author>/Sources/...
# references: correct on one machine, a broken link everywhere else, and caught
# by eye rather than by this suite. That is invariant 2 -- an absent check
# reporting as a pass.
#
# Scoped to the SHIPPED surface only. CLAUDE.md documents where this particular
# checkout lives on purpose (the plugin runs from the working tree), and .claude/
# is untracked local config; neither is distributed as plugin behaviour.
shipped_surface=(agents skills lib config examples .claude-plugin)
home_paths=(
  '/Users/[A-Za-z0-9._-]+/'
  '/home/[A-Za-z0-9._-]+/'
)

# A line genuinely about the SHAPE of a home path (documenting a transform, an
# example in prose) marks itself `scrub-ok: <why>`. The exemption is deliberately
# per-line and visible in the source rather than encoded as a cleverer pattern
# here: a regex tuned to tell "illustrative" from "hardcoded" would eventually
# get one wrong silently, which is the failure this whole suite exists to stop.
for p in "${home_paths[@]}"; do
  if hits=$(grep -rnE "${excludes[@]}" -I -n -- "$p" "${shipped_surface[@]}" 2>/dev/null \
            | grep -v 'scrub-ok'); then
    printf '\n[hardcoded home path] pattern matched: %s\n' "$p" >&2
    printf '%s\n' "$hits" | head -20 >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

FAILED. This repo is public and its history is permanent.
Replace the identifier with a configurable value or an example placeholder
(see docs/CONFIGURING.md), or move the rationale to docs/CASE-STUDIES.md
in anonymised form. Do not simply delete a rule's justification --
see the note at the top of that file.

For a [hardcoded home path]: the shipped plugin must reference its own files
relatively (docs/CASE-STUDIES.md) or through ${CLAUDE_PLUGIN_ROOT}. An absolute
path under someone's home directory resolves on exactly one machine.
EOF
  exit 1
fi

echo "ok — no private identifiers or secret-shaped literals found"
