#!/usr/bin/env bash
# no-private-identifiers.sh — fail if internal identifiers or secret-shaped literals
# appear anywhere this repo publishes: the files, every past version of every file,
# commit messages, and commit author/committer identities.
#
# This repo was extracted from a private implementation and its history is permanent,
# so the scrub has to hold on EVERY commit, not just the tree. A tree-only scan cannot
# see a leaked identifier in a commit message, an author email, or a file version that
# a later commit cleaned up — all three are published by `git push`.
#
# Build-time only: CI and the developer run this on THIS repo. Nothing in the plugin
# calls it, and it never inspects the repositories the plugin reviews.
#
# MUST run under bash explicitly. Under zsh an unquoted "$VAR" does not word-split, so
# a scan written for bash collapses its file list into one bogus name, greps nothing,
# and reports clean. Everything below uses arrays with "${arr[@]}".
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2

# Private words, as SHA-256 of the lowercased word. Publishing the plain list would
# publish the very names it protects. Text is split into [A-Za-z0-9] runs, so a word
# matches inside `word-123`, `Word.pm` or `user@word.com`; hyphenated runs are also
# hashed whole, for a name whose parts are too common to list alone. These are short dictionary
# words: anyone determined can brute-force the hashes. This stops casual reading of
# the guard, not a targeted attacker. When you scrub a new identifier out of the
# repo, add its hash here in the same commit, or the next slip is invisible again:
#   printf %s 'word' | shasum -a 256
private_word_hashes=(
  0bab5a465b9a5c754552028d5d7c341f634a1f98d17a909b1c645ed2acb8eb65
  a07dfbabba659e3923990d743c821ebbd6e77f0ec028990d3a3bb90cecea6400
  2a8067dbdbc8dfa86fc49430ca14f2be4800f6c047869606ad607648e8ce55b8
  b98e6b3111e0bedd2d8457e8b4f764a4cab2842a6b27d83ee7029966c271348d
  9e861941ad8bf5bcb649e5fde92d712528200a216018c2437371498e6ab7683d
  e96412e047578448bb5c587029bfa0d403798de32ec3016c7a1ef3424de2d6e0
  3d26e3080fbeb2a16514b549273d393020b8afeed9eeac3821b1095b2cc407ec
)
# Not private, but must not appear: the author's own domain, kept out of the repo.
private_patterns=('halindrome\.com')
secret_shapes=(
  'glpat-[A-Za-z0-9_-]{10,}'      # GitLab PAT
  'gh[pousr]_[A-Za-z0-9]{20,}'    # GitHub token
  'sk-[A-Za-z0-9]{20,}'           # OpenAI-style key
  'AKIA[0-9A-Z]{16}'              # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

fail=0
# report <label> <hits>: called in the MAIN shell, never on the right of a pipe — a
# pipeline stage is a subshell, and a `fail=1` set there is lost: the guard would
# print its matches and still say ok.
report() { [ -n "$2" ] || return 0; printf '\n[%s]\n' "$1" >&2; printf '%s\n' "$2" | head -20 >&2; fail=1; }

# word_scan: reads a stream where a line `@@LOC <where>` sets the location for the
# lines after it, and prints `<where>: private word (sha256 <prefix>)` for every
# hashed word found. The word itself is never printed: CI logs are public.
word_scan() {
  PRIVATE_HASHES="${private_word_hashes[*]}" perl -MDigest::SHA=sha256_hex -ne '
    BEGIN { %h = map { $_ => 1 } split / /, $ENV{PRIVATE_HASHES} }
    if (/^\@\@LOC (.*)$/) { $loc = $1; next }
    for my $w (/[A-Za-z0-9]+/g, /[A-Za-z0-9]+(?:-[A-Za-z0-9]+)+/g) {
      my $d = sha256_hex(lc $w);
      print "$loc: private word (sha256 ", substr($d, 0, 12), ")\n" if $h{$d} && !$seen{"$loc $d"}++;
    }'
}

files=()
while IFS= read -r f; do files+=("$f"); done < <(git ls-files)

# 1. The tree. Each file announces itself; binary files are skipped.
report "private word in a tracked file" "$(
  for f in "${files[@]}"; do
    [ -f "$f" ] && grep -Iq . "$f" 2>/dev/null || continue
    printf '@@LOC %s\n' "$f"; cat "$f"; echo
  done | word_scan)"

# 2. Every line any commit added or removed, on every ref.
report "private word in the history of a file" "$(
  git log --all -p --no-color --no-ext-diff --format='@@LOC commit %h' 2>/dev/null \
    | awk '/^@@LOC /{c=$0; next} /^\+\+\+ b\//{print c " " substr($0,7); next}
           /^[+-]/ && !/^(\+\+\+|---) /{print}' \
    | word_scan)"

# 3. Commit messages, and 4. author and committer identities.
report "private word in a commit message" "$(
  git log --all --format='@@LOC message of %h%n%B' 2>/dev/null | word_scan)"
report "private word in a commit identity" "$(
  git log --all --format='@@LOC author/committer of %h%n%an %ae %cn %ce' 2>/dev/null | word_scan)"

# Plain patterns and secret shapes: the tree, every line history added, and messages.
# This file defines the patterns, so it is excluded from the tree scan by name.
history_added=$(git log --all -p --no-color --no-ext-diff --format='commit %h' 2>/dev/null \
                | grep -E '^\+[^+]' || true)
messages=$(git log --all --format='%h %B' 2>/dev/null)
for p in "${private_patterns[@]}" "${secret_shapes[@]}"; do
  report "pattern in a tracked file: $p" \
    "$(git grep -nIiE -- "$p" -- . ':!test/no-private-identifiers.sh' 2>/dev/null)"
  report "pattern added somewhere in history: $p" \
    "$(printf '%s\n' "$history_added" | grep -iE -- "$p" || true)"
  report "pattern in a commit message: $p" "$(printf '%s\n' "$messages" | grep -iE -- "$p" || true)"
done

# A hardcoded home path is not a private identifier, so every scan above ships it
# green -- but it is dead for every installer who is not the author. Scoped to the
# SHIPPED surface: CLAUDE.md documents where this checkout lives on purpose. A line
# genuinely about the SHAPE of a home path marks itself `scrub-ok: <why>`, per line and
# visible, rather than trusting a cleverer regex to tell illustrative from hardcoded.
shipped_surface=(agents skills lib config examples .claude-plugin)
home_paths=('/Users/[A-Za-z0-9._-]+/' '/home/[A-Za-z0-9._-]+/')
for p in "${home_paths[@]}"; do
  report "hardcoded home path: $p" \
    "$(git grep -nIE -- "$p" -- "${shipped_surface[@]}" 2>/dev/null | grep -v 'scrub-ok')"
done

if [ "$fail" -ne 0 ]; then
  cat >&2 <<'EOF'

FAILED. This repo is public and its history is permanent.
In the tree: replace the identifier with a configurable value or a placeholder
(docs/CONFIGURING.md), or move the rationale to docs/CASE-STUDIES.md anonymised.
In history, a message or an identity: rewrite before the first push (git filter-repo
with --mailmap / --replace-message / --replace-text). After a push, it is permanent.
For a hardcoded home path: reference plugin files relatively or via ${CLAUDE_PLUGIN_ROOT}.
EOF
  exit 1
fi

echo "ok — no private identifiers or secret-shaped literals in the tree, its history, or its commits"
