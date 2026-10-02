#!/usr/bin/env bash
# llm-reviewer.sh — one second-opinion review of the round's diff by any
# OpenAI-compatible chat-completions endpoint (hosted or local).
#
# Usage:  llm-reviewer.sh --scratch <dir> --reviewer <name> --output <path> [--skip-contract]
#
# The reviewer is a NAME from `second_opinion.reviewers` in config. Preflight resolves
# that list into <scratch>/second-opinion.json; this script reads its entry from there
# (endpoint, model, api_key_env, max_tokens, timeout_seconds, max_input_bytes) and
# never re-resolves config. Everything else comes from the scratch dir too: the diff
# range and target from manager-brief.txt, the criteria from contract.md.
#
# Exit:   0 findings written | 1 network/HTTP failure | 2 empty response
#         3 the endpoint returned an error body | 4 the reviewer's API key is not set
#         5 the diff alone exceeds the reviewer's input budget | 64 usage / config
# A non-zero exit is a non-blocking reviewer failure (SKILL.md Step 3A.2); the caller
# reports it. Nothing here may turn a failure into an empty "no issues" file.
#
# The model sees the diff, the changed files at HEAD, and the contract — no tools.
# Findings use the plugin's own taxonomy (severity / relevance / status), so the
# Step 3A.3 tag-merge files them exactly like a lens's.
#
# bash 3.2 compatible: no ${!var}, ${var,,}, mapfile or associative arrays.
set -uo pipefail

S="" NAME="" OUTPUT="" SKIP_CONTRACT=false
usage() { echo "usage: llm-reviewer.sh --scratch <dir> --reviewer <name> --output <path> [--skip-contract]" >&2; exit 64; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scratch)       S="${2:-}"; shift 2 ;;
    --reviewer)      NAME="${2:-}"; shift 2 ;;
    --output)        OUTPUT="${2:-}"; shift 2 ;;
    --skip-contract) SKIP_CONTRACT=true; shift ;;
    *) usage ;;
  esac
done
[ -n "$S" ] && [ -n "$NAME" ] && [ -n "$OUTPUT" ] || usage
for bin in curl jq git; do
  command -v "$bin" >/dev/null 2>&1 || { echo "[$NAME] ERROR: $bin not on PATH" >&2; exit 64; }
done

CFG="$S/second-opinion.json"
R=$(jq -c --arg n "$NAME" '.reviewers[]? | select(.name == $n)' "$CFG" 2>/dev/null | head -1)
[ -n "$R" ] || { echo "[$NAME] ERROR: no reviewer named '$NAME' in $CFG" >&2; exit 64; }
cfg() { jq -r --arg d "$2" ".$1 // \$d | tostring" <<<"$R"; }
ENDPOINT=$(cfg endpoint "");   MODEL=$(cfg model "")
KEY_ENV=$(cfg api_key_env ""); MAX_TOKENS=$(cfg max_tokens 8192)
TIMEOUT=$(cfg timeout_seconds 600); BUDGET=$(cfg max_input_bytes 400000)
[ -n "$ENDPOINT" ] && [ -n "$MODEL" ] || { echo "[$NAME] ERROR: endpoint and model are required" >&2; exit 64; }

# The key is read by NAME from the environment, never stored in config. A configured
# key variable that is empty is a named failure, not an unauthenticated request.
KEY=""
if [ -n "$KEY_ENV" ]; then
  KEY=$(printenv "$KEY_ENV" 2>/dev/null || true)
  [ -n "$KEY" ] || { echo "[$NAME] ERROR: $KEY_ENV is not set" >&2; exit 4; }
fi

brief() { sed -n "s/^$1=//p" "$S/manager-brief.txt" 2>/dev/null | tail -1; }
TARGET_ABS=$(brief target_abs); RANGE=$(brief diff_range)
[ -d "$TARGET_ABS" ] && [ -n "$RANGE" ] || { echo "[$NAME] ERROR: no target_abs/diff_range in $S/manager-brief.txt" >&2; exit 64; }
echo "[$NAME] start model=$MODEL range=$RANGE" >&2

DIFF=$(git -C "$TARGET_ABS" diff "$RANGE" 2>/dev/null) || { echo "[$NAME] ERROR: git diff $RANGE failed" >&2; exit 1; }
if [ "$SKIP_CONTRACT" = true ]; then CONTRACT="SKIP"; else CONTRACT=$(cat "$S/contract.md" 2>/dev/null || echo "(no contract.md)"); fi

# Changed files at HEAD (the working tree IS the MR head after preflight's sync). The
# diff is never truncated; file contents are added whole while they fit the budget,
# and every file left out is NAMED in the output, so a partial review cannot read as
# a complete one.
used=$(( ${#DIFF} + ${#CONTRACT} + 4096 ))
if [ "$used" -gt "$BUDGET" ]; then
  echo "[$NAME] ERROR: diff + contract is $used bytes, over this reviewer's budget of $BUDGET" >&2; exit 5
fi
FILES=""; OMITTED=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in
    *.png|*.jpg|*.jpeg|*.gif|*.ico|*.pdf|*.zip|*.tar|*.gz|*.bz2|*.xz|*.lock|*package-lock.json|*yarn.lock|*pnpm-lock.yaml) continue ;;
  esac
  body=$(git -C "$TARGET_ABS" show "HEAD:$f" 2>/dev/null) || continue   # deleted at HEAD: the diff shows it
  if [ $(( used + ${#body} + 64 )) -le "$BUDGET" ]; then
    FILES="$FILES
===== FILE: $f =====
$body"
    used=$(( used + ${#body} + 64 ))
  else
    OMITTED="$OMITTED $f"
  fi
done < <(git -C "$TARGET_ABS" diff --name-only "$RANGE" 2>/dev/null)

SYSTEM="You are a devil's-advocate reviewer of a merge request. You see only the diff, the changed files, and the contract (the acceptance criteria). You have no tools.

Report only defects you can substantiate from what you see, at the severity they carry. Saying the change is correct is a complete answer; do not pad.

Every finding uses exactly this block:

### Finding N: <title>
- **Area:** \`<file>\` (lines X-Y)
- **Severity:** critical | major | minor
- **Relevance:** contract | regression | observation
- **Category:** <short label>
- **Status:** confirmed | hypothetical
- **Description:** <what is wrong>
- **Evidence:** <the code that shows it>
- **Impact:** <what breaks, and when>

Relevance: contract = an acceptance criterion is not met; regression = the change breaks behaviour in code it touched or its callers; observation = a pre-existing bug in code the change did not touch. Severity: critical = data loss, security exposure or outage; major = a failed criterion or a defect a user will hit; minor = real but survivable.

Unless the contract is 'SKIP', first give a table with one row per acceptance criterion: | Criterion | Status (satisfied / partially-satisfied / not-satisfied / not-applicable) | Evidence |.
If there are no findings, write exactly: ### No Issues Found"

USER="Round: $(brief round)    MR: $(brief mr)    Target: $(brief target)

## Contract
$CONTRACT

## Diff
\`\`\`diff
$DIFF
\`\`\`

## Changed files at HEAD
$FILES"

PAYLOAD=$(jq -n --arg m "$MODEL" --arg s "$SYSTEM" --arg u "$USER" --argjson t "$MAX_TOKENS" \
  '{model: $m, temperature: 0.2, max_tokens: $t, messages: [{role: "system", content: $s}, {role: "user", content: $u}]}')
RESP=$(mktemp); trap 'rm -f "$RESP"' EXIT
auth=(); [ -n "$KEY" ] && auth=(-H "Authorization: Bearer $KEY")
# --http1.1: some local OpenAI-compatible servers hang on HTTP/2 negotiation.
code=$(printf '%s' "$PAYLOAD" | curl -sS --http1.1 --max-time "$TIMEOUT" -o "$RESP" -w '%{http_code}' \
         -H 'Content-Type: application/json' ${auth[@]+"${auth[@]}"} \
         -X POST "$ENDPOINT" --data-binary @- 2>/dev/null) || code=000
case "$code" in 2??) ;; *) echo "[$NAME] ERROR: HTTP $code from $ENDPOINT" >&2; exit 1 ;; esac
if jq -e '.error' "$RESP" >/dev/null 2>&1; then
  echo "[$NAME] ERROR: $(jq -r '.error.message // .error | tostring' "$RESP")" >&2; exit 3
fi

CONTENT=$(jq -r '.choices[0].message.content // empty' "$RESP" 2>/dev/null)
if [ -z "$CONTENT" ]; then
  # A reasoning model that spends max_tokens thinking returns empty content and its
  # chain of thought separately. Keep it, under a banner saying what it is.
  reasoning=$(jq -r '.choices[0].message.reasoning_content // empty' "$RESP" 2>/dev/null)
  [ -n "$reasoning" ] || { echo "[$NAME] ERROR: empty response" >&2; exit 2; }
  CONTENT="> **Reasoning-content fallback** — the model returned no final answer (finish_reason=$(jq -r '.choices[0].finish_reason // "unknown"' "$RESP")); below is its raw reasoning, not finalized findings. Consider raising max_tokens for this reviewer.

$reasoning"
fi

{
  echo "<!-- second opinion: $NAME ($MODEL) -->"
  [ -n "$OMITTED" ] && echo "[$NAME] WARNING: file contents omitted to fit the input budget (the diff was sent whole):$OMITTED"
  printf '%s\n' "$CONTENT" | sed -E "s/^### Finding ([0-9]+): /### Finding \1: [$NAME] /"
} > "$OUTPUT"
echo "[$NAME] done" >&2
exit 0
