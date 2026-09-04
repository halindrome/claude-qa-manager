#!/usr/bin/env bash
# round-return.sh — attribute the round's findings, derive the manager's whole
# verdict from what is on disk, do the end-of-round bookkeeping, and print the
# return JSON. The manager's final message is this script's stdout.
#
# Usage:
#   round-return.sh <scratch-dir> [flags] < merged-findings.json
#
#     --summary <text>        blocking_summary (<=2 sentences). MODEL-AUTHORED.
#     --decisions <json>      decisions_needed array. MODEL-AUTHORED.
#     --contract-all-pass <true|false>   MODEL-AUTHORED (a judgement per criterion).
#     --note <path>           the rendered round note (default: newest note-round*.md)
#     --posted <true|false>   whether YOU already posted it (default false)
#     --note-url <url>        the posted note's URL, when you posted it
#
# WHY THIS EXISTS, AND WHY IT TAKES THE FINDINGS ON STDIN RATHER THAN READING THEM.
# Everything the verdict needs already exists in the scratch dir, but the manager
# names its merged-findings file whatever it likes. Measured across 21 real rounds
# it used SEVEN different names -- merged.json, merged-findings.json,
# merged-findings-r2.json, merged-attributed.json, merged-round3.json,
# merged-findings-round2.json, merged-findings.pre-attribution.json -- and the spec
# names it nowhere. So a helper that went looking for a file by name would find it
# about a third of the time. The manager pipes findings IN; this script owns the
# canonical name on the way out. You cannot misname a file you never name.
#
# That is the same shape as lib/lens-landed.sh, and it is the only shape that has
# actually held: the bookkeeping is not a step you can forget, it is how you produce
# the thing you came for. Three separate rules stated as prose were dropped in one
# day (the per-lens status write marked MANDATORY, the run_in_background flag, and
# a counter that was never defined at all). Emphasis is not enforcement.
#
# WHAT IS COMPUTED VS ASKED FOR. Anything derivable is derived, because a number the
# model counts is a number that drifts: qa_introduced_blocking exceeded its own
# denominator in 62 of 262 measured rounds. Only two things genuinely need a mind --
# the prose summary and the human-decision list -- plus contract_all_pass, which is
# a per-criterion judgement the lenses make and no file records as a single boolean.
set -uo pipefail

S="${1:-}"; shift || true
[ -n "$S" ] && [ -d "$S" ] || { echo "round-return: no scratch dir" >&2; exit 2; }

SUMMARY=""; DECISIONS="[]"; CONTRACT_ALL_PASS="null"
NOTE=""; POSTED="false"; NOTE_URL=""
while [ $# -gt 0 ]; do
  case "$1" in
    --summary)            SUMMARY="${2:-}"; shift 2 ;;
    --decisions)          DECISIONS="${2:-[]}"; shift 2 ;;
    --contract-all-pass)  CONTRACT_ALL_PASS="${2:-null}"; shift 2 ;;
    --note)               NOTE="${2:-}"; shift 2 ;;
    --posted)             POSTED="${2:-false}"; shift 2 ;;
    --note-url)           NOTE_URL="${2:-}"; shift 2 ;;
    *) echo "round-return: unknown flag '$1'" >&2; exit 2 ;;
  esac
done
printf '%s' "$DECISIONS" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "round-return: --decisions must be a JSON array" >&2; exit 2; }

PF="$S/preflight.json"
[ -f "$PF" ] || { echo "round-return: no preflight.json in $S" >&2; exit 2; }
TARGET_ABS=$(jq -r '.target_abs // ""'        "$PF")
FIX_COMMITS=$(jq -c '.qa_fix_commits // []'   "$PF")
TEST_PAT=$(jq -r '.test_path_pattern // ""'   "$PF")
ROUND=$(jq -r '.round // 0'                   "$PF")
LENSES=$(jq -c '.lenses // []'                "$PF")
PF_SCHEMA=$(jq -r '.schema.detected // false' "$PF")

RAW=$(cat)
printf '%s' "$RAW" | jq -e 'type == "array"' >/dev/null 2>&1 \
  || { echo "round-return: stdin must be a JSON array of findings" >&2; exit 2; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Attribution runs HERE rather than being a step the manager remembers, and its
# result is written back to disk. On the round that motivated this script the
# manager did run it, used the answer in the note, and left the on-disk merged file
# un-attributed -- so nothing downstream could see which findings were self-inflicted.
ATTRIBUTED=$(printf '%s' "$RAW" \
  | bash "$HERE/attribute-findings.sh" "$TARGET_ABS" "$FIX_COMMITS" "$TEST_PAT" 2>/dev/null) \
  || ATTRIBUTED="$RAW"
printf '%s' "$ATTRIBUTED" | jq -e 'type == "array"' >/dev/null 2>&1 || ATTRIBUTED="$RAW"

# THE canonical name. Everything after this reads one file.
printf '%s\n' "$ATTRIBUTED" | jq '.' > "$S/merged-findings.json"

blocking_of() { printf '%s' "$ATTRIBUTED" | jq "[.[] | select(.severity==\"critical\" or .severity==\"major\") $1] | length"; }
CRIT=$(printf '%s' "$ATTRIBUTED" | jq '[.[]|select(.severity=="critical")]|length')
MAJ=$(printf  '%s' "$ATTRIBUTED" | jq '[.[]|select(.severity=="major")]|length')
MIN=$(printf  '%s' "$ATTRIBUTED" | jq '[.[]|select(.severity=="minor")]|length')
BLOCKING=$(( CRIT + MAJ ))
# Blocking-only, per agents/qa-manager.md. A value that can exceed critical+major is
# what made this field ungateable for so long.
QI_BLOCKING=$(blocking_of '| select(.qa_introduced==true)')
QI_TOTAL=$(printf '%s' "$ATTRIBUTED" | jq '[.[]|select(.qa_introduced==true)]|length')

OBS=$(printf '%s' "$ATTRIBUTED" | jq -c '[.[] | select(.relevance=="observation")
        | {title, severity, area_file, line_low}]')
OBS_N=$(printf '%s' "$OBS" | jq 'length')

# failed_lenses: what preflight asked for, minus what actually landed. Derived, so a
# lens that died silently cannot be omitted from the report by being forgotten.
LANDED=$(for f in "$S"/lens-*.json; do
           [ -f "$f" ] || continue
           b=$(basename "$f" .json); printf '%s\n' "${b#lens-}"
         done | jq -R . | jq -s .)
FAILED=$(jq -nc --argjson want "$LENSES" --argjson got "$LANDED" '$want - $got')

NAV=$(for f in "$S"/lens-*.json; do
        [ -f "$f" ] || continue
        b=$(basename "$f" .json)
        jq -c --arg n "${b#lens-}" '{($n): (.navigation // "unknown")}' "$f" 2>/dev/null
      done | jq -sc 'add // {}')

SCHEMA=$(for f in "$S"/lens-*.json; do
           [ -f "$f" ] || continue
           jq -r '.schema_change_detected // false' "$f" 2>/dev/null
         done | grep -qx true && echo true || echo "$PF_SCHEMA")

TREE_MUTATED=false
if [ -f "$S/tree-before.txt" ] && [ -f "$S/tree-after.txt" ]; then
  cmp -s "$S/tree-before.txt" "$S/tree-after.txt" || TREE_MUTATED=true
fi

# THIS round's note, by number. Picking the newest by mtime is wrong: the scratch
# dir is keyed to the MR and keeps every round's note, and an earlier note gets
# touched whenever a trailer or correction is appended to it — which happens
# routinely at Step 3C. Caught in the first smoke test, where a round-3 return
# named note-round1.md.
if [ -z "$NOTE" ]; then
  if [ -f "$S/note-round${ROUND}.md" ]; then
    NOTE="$S/note-round${ROUND}.md"
  else
    NOTE=$(ls -t "$S"/note-round*.md 2>/dev/null | head -1)
  fi
fi

# diminishing_returns is COMPUTED, then merged into whatever the model supplied.
# The lens-volunteered trigger it replaces is unreachable by construction --
# attribution happens after the lenses return and none of them ever sees the fix
# commits -- and it showed: 29 of 281 rounds met this criterion, 3 raised it.
HALF=$(( (BLOCKING + 1) / 2 ))
THRESH=$(( HALF > 2 ? HALF : 2 ))
if [ "$QI_BLOCKING" -ge "$THRESH" ] && [ "$QI_BLOCKING" -gt 0 ]; then
  DECISIONS=$(jq -nc --argjson d "$DECISIONS" --argjson sr "$QI_BLOCKING" --argjson bt "$BLOCKING" \
    'if ([$d[] | select(.kind=="diminishing_returns")] | length) > 0 then $d else
       $d + [{kind:"diminishing_returns",
              reason:("\($sr) of \($bt) blocking findings target code an earlier QA round introduced"),
              self_referential:$sr, blocking_total:$bt}] end')
fi

jq -n \
  --argjson round "$ROUND" \
  --argjson crit "$CRIT" --argjson maj "$MAJ" --argjson min "$MIN" \
  --argjson blocking "$BLOCKING" \
  --argjson contract "$CONTRACT_ALL_PASS" \
  --argjson schema "$SCHEMA" \
  --argjson failed "$FAILED" \
  --argjson nav "$NAV" \
  --arg note "${NOTE:-}" \
  --argjson posted "$POSTED" \
  --arg note_url "$NOTE_URL" \
  --argjson obs "$OBS" --argjson obs_n "$OBS_N" \
  --argjson qib "$QI_BLOCKING" --argjson qit "$QI_TOTAL" \
  --argjson tree "$TREE_MUTATED" \
  --arg summary "$SUMMARY" \
  --argjson decisions "$DECISIONS" \
  '{round: $round,
    counts: {critical: $crit, major: $maj, minor: $min},
    round_has_critical_or_major: ($blocking > 0),
    contract_all_pass: $contract,
    schema_change_detected: $schema,
    failed_lenses: $failed,
    lens_navigation: $nav,
    note_path: $note,
    note_posted: $posted,
    note_url: $note_url,
    observations_count: $obs_n,
    observations: $obs,
    qa_introduced_blocking: $qib,
    qa_introduced_total: $qit,
    tree_mutated: $tree,
    blocking_summary: $summary,
    decisions_needed: $decisions}'

# Bookkeeping as a SIDE EFFECT of returning, so it cannot be the step that is
# skipped. phase=done is what stops the stall detector reporting a finished round
# as wedged; record-timing.sh only observes.
if [ -f "$S/status" ]; then
  IFS='|' read -r _m _t _r _p _d _tt _st _ta _ls < "$S/status"
  printf '%s|%s|%s|done|%s|%s|%s|%s|%s\n' \
    "$_m" "$_t" "$_r" "${_d:-0}" "${_tt:-0}" "${_st:-0}" "${_ta:-}" "${_ls:-1200}" > "$S/status"
fi
bash "$HERE/record-timing.sh" "$S" >/dev/null 2>&1 || true
