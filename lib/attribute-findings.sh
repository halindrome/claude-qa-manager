#!/usr/bin/env bash
# attribute-findings.sh — mark findings that sit on code THIS QA CYCLE wrote.
#
# Usage:  attribute-findings.sh <repo-dir> <fix-commits-json> < findings.json
#           <fix-commits-json>  JSON array of SHAs, e.g. '["abc1234","def5678"]'
#           stdin               JSON array of findings, each with .file and
#                               .line_low (.line_high optional)
# Output: the same array on stdout, each finding gaining
#           .qa_introduced        true|false
#           .qa_introduced_commit <sha>   (only when true)
#         plus, on stderr, nothing. Callers read .qa_introduced.
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

out='[]'
while IFS= read -r finding; do
  file=$(jq -r '.file // ""'                     <<<"$finding")
  line=$(jq -r '.line_low // .line // "" | tostring' <<<"$finding")
  hit=""
  if [ -n "$file" ] && [ -n "$line" ] && [ "$line" != "null" ] && [ -f "$REPO/$file" ]; then
    b=$(blame_sha "$file" "$line")
    if [ -n "$b" ]; then
      for f in $FULL; do [ "$f" = "$b" ] && { hit="$b"; break; }; done
    fi
  fi
  if [ -n "$hit" ]; then
    finding=$(jq -c --arg s "$hit" '.qa_introduced = true | .qa_introduced_commit = $s' <<<"$finding")
  else
    finding=$(jq -c '.qa_introduced = false' <<<"$finding")
  fi
  out=$(jq -c --argjson f "$finding" '. + [$f]' <<<"$out")
done < <(jq -c '.[]' <<<"$FINDINGS" 2>/dev/null)

printf '%s\n' "$out"
