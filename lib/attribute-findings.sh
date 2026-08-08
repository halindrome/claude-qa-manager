#!/usr/bin/env bash
# attribute-findings.sh — mark findings that sit on code THIS QA CYCLE wrote.
#
# Usage:  attribute-findings.sh <repo-dir> <fix-commits-json> < findings.json
#           <fix-commits-json>  JSON array of SHAs, e.g. '["abc1234","def5678"]'
#           stdin               JSON array of findings, each with .area_file
#                               (the lens schema's name; .file also accepted)
#                               and .line_low (.line_high optional)
# Output: the same array on stdout, each finding gaining
#           .qa_introduced        true|false
#           .qa_introduced_commit <sha>   (only when true)
#         plus, on stderr, a count of findings whose location could not be read
#         at all — see the note above that warning. Callers read .qa_introduced,
#         and must NOT report an all-false result as clean when that count is the
#         whole batch.
#
# WHY BLAME AND NOT A LINE-RANGE COMPARISON. The obvious implementation — record
# the line ranges each fix commit touched, then check whether a later finding
# falls inside one — is WRONG. Insertions and deletions between commits shift
# every line below them, so round 3's `foo.js:120` has no relationship to line
# 120 as round 1 touched it. `git blame` is computed against the content as it
# exists at the reviewed HEAD, so git does the tracking and no arithmetic is
# needed.
#
# KNOWN LIMITS, all in the direction of UNDER-reporting, which is the right way
# for a signal whose only job is to inform a human:
#   - Blame attributes the LAST touch. If a QA round wrote a line and the author
#     later edited it, the finding is attributed to the author and goes untagged.
#   - Deleted code cannot be blamed. If a round's fix removed something and a
#     later finding is "this is missing", there is no line to attribute.
#   - A round that merely reindented an earlier round's line takes the
#     attribution. The specific round can be wrong while the aggregate — "some
#     round of this cycle wrote this" — stays right, and the aggregate is what
#     the report is about.
# -w ignores whitespace-only churn; -C follows moved code.
set -uo pipefail

REPO="${1:-}"; FIX_JSON="${2:-[]}"
FINDINGS=$(cat)

# No recorded fix commits (round 1, or a cycle predating the trailer) => nothing
# can be attributed. Return the input untouched rather than inventing a verdict.
if [ -z "$REPO" ] || [ ! -d "$REPO" ] || [ "$(jq -r 'length' <<<"$FIX_JSON" 2>/dev/null || echo 0)" = "0" ]; then
  jq -c '[.[] | .qa_introduced = false]' <<<"$FINDINGS" 2>/dev/null || printf '%s' "$FINDINGS"
  exit 0
fi

# Full SHAs for the recorded (possibly abbreviated) ones, so comparison is exact.
FULL=""
while IFS= read -r sha; do
  [ -n "$sha" ] || continue
  f=$(git -C "$REPO" rev-parse --verify "${sha}^{commit}" 2>/dev/null) || continue
  FULL="$FULL $f"
done < <(jq -r '.[]' <<<"$FIX_JSON" 2>/dev/null)
[ -n "$FULL" ] || { jq -c '[.[] | .qa_introduced = false]' <<<"$FINDINGS"; exit 0; }

blame_sha() {  # $1 = file, $2 = line -> full SHA of the commit that last touched it
  git -C "$REPO" blame -w -C -L "$2,$2" --porcelain -- "$1" 2>/dev/null \
    | head -1 | awk '{print $1}'
}

out='[]'; total=0; unresolved=0
while IFS= read -r finding; do
  total=$((total + 1))
  # BOTH names, and `area_file` FIRST: the lens findings schema
  # (agents/qa-reviewer.md, agents/qa-manager.md §3.5) calls the location
  # `area_file`, while this script's own usage header said `.file`. Reading only
  # `.file` meant that piped the DOCUMENTED way — reviewer findings straight in —
  # the guard below was never true and every finding came back
  # `qa_introduced=false`. Measured on observability-stack !14 round 2: 8 of 8
  # findings sat on code an earlier round of the same cycle wrote; this reported
  # none of them. Accepting both rather than renaming the schema keeps any caller
  # already passing `.file` working.
  file=$(jq -r '.area_file // .file // ""'       <<<"$finding")
  line=$(jq -r '.line_low // .line // "" | tostring' <<<"$finding")
  hit=""
  if [ -n "$file" ] && [ -n "$line" ] && [ "$line" != "null" ] && [ -f "$REPO/$file" ]; then
    b=$(blame_sha "$file" "$line")
    if [ -n "$b" ]; then
      for f in $FULL; do [ "$f" = "$b" ] && { hit="$b"; break; }; done
    fi
  else
    unresolved=$((unresolved + 1))
  fi
  if [ -n "$hit" ]; then
    finding=$(jq -c --arg s "$hit" '.qa_introduced = true | .qa_introduced_commit = $s' <<<"$finding")
  else
    finding=$(jq -c '.qa_introduced = false' <<<"$finding")
  fi
  out=$(jq -c --argjson f "$finding" '. + [$f]' <<<"$out")
done < <(jq -c '.[]' <<<"$FINDINGS" 2>/dev/null)

# An unblameable location and "blamed, not ours" both emit qa_introduced=false,
# so a total field-name/shape mismatch is otherwise indistinguishable from the
# good news "no finding sits on our own fixes" — which is exactly how the
# area_file bug survived a whole round. Say so on stderr; the caller reports it
# rather than reading the all-false result as verified clean.
if [ "$unresolved" -gt 0 ]; then
  echo "attribute-findings: $unresolved of $total findings had no usable <file,line> (expected .area_file or .file plus .line_low); their qa_introduced=false means NOT CHECKED, not clean." >&2
fi
printf '%s\n' "$out"
