#!/usr/bin/env bash
# lens-tools-summary.sh — per-lens tool usage for one round, from the telemetry that
# lib/lens-tool-log.sh wrote during the panel.
#
# Usage:  lens-tools-summary.sh <scratch-dir>
# Output: {"lens_mcp_state": <from the brief>, "lenses": {<lens>: ...}}, one entry per
# lens in the brief's `lenses` array, each either
#   {"state":"not-recorded"}                         no tools-<lens>.jsonl exists
#   {"state":"recorded", "calls", "by_class":{cmm,ctx,raw,other}, "failed",
#    "no_result", "denied", "toolsearch", "tool_ms", "span_s"}
# Exit:   0 ok | 2 usage
#
# lens_mcp_state travels with the counts because a zero is uninterpretable without
# it: `ctx: 0` under `partial:context-mode` means the lens never had the tool, not
# that it declined to use it.
#
# A lens without a log is `not-recorded`, never zero calls: an absent log means the
# telemetry did not run, and reporting it as "used no tools" is an absent check
# reporting as a pass.
#
#   no_result  PreToolUse with neither Post event: blocked by a hook or permission,
#              or the lens was killed mid-call. The log cannot tell those apart.
#   denied     the run record's own permission_denials count, the subset of
#              no_result Claude Code attributes to a block. -1 when raw-<lens>.json
#              is absent or unreadable.
#   tool_ms    summed tool execution time; span_s is first to last event, so
#              span_s - tool_ms/1000 approximates time spent in the model.
set -uo pipefail

S="${1:-}"
[ -n "$S" ] && [ -f "$S/manager-brief.txt" ] || {
  echo "usage: lens-tools-summary.sh <scratch-dir with manager-brief.txt>" >&2; exit 2; }

LENSES_JSON=$(sed -n 's/^lenses=//p' "$S/manager-brief.txt" | tail -1)
MCP_STATE=$(sed -n 's/^lens_mcp_state=//p' "$S/manager-brief.txt" | tail -1)

out='{}'
for lens in $(printf '%s' "$LENSES_JSON" | jq -r '.[]' 2>/dev/null); do
  log="$S/tools-$lens.jsonl"
  if [ ! -f "$log" ]; then
    out=$(jq -c --arg l "$lens" '.[$l] = {state: "not-recorded"}' <<<"$out")
    continue
  fi
  denied=$(jq -r '.permission_denials | length' "$S/raw-$lens.json" 2>/dev/null) || denied=-1
  [ -n "$denied" ] || denied=-1
  row=$(jq -cs --argjson denied "$denied" '
    def class: if   startswith("mcp__codebase-memory-mcp__") then "cmm"
               elif test("^mcp__.*context-mode.*__")          then "ctx"
               elif IN("Read", "Grep", "Glob", "Bash")        then "raw"
               else "other" end;
    (map(select(.ev == "PreToolUse")))                          as $pre
    | (map(select(.ev != "PreToolUse")) | map(.id))             as $done
    | {state:      "recorded",
       calls:      ($pre | length),
       by_class:   ({cmm: 0, ctx: 0, raw: 0, other: 0}
                    + ($pre | group_by(.tool | class)
                            | map({key: (.[0].tool | class), value: length})
                            | from_entries)),
       failed:     (map(select(.ev == "PostToolUseFailure")) | length),
       no_result:  ($pre | map(select(.id as $i | $done | index($i) | not)) | length),
       denied:     $denied,
       toolsearch: ($pre | map(select(.tool == "ToolSearch")) | length),
       tool_ms:    (map(.ms // 0) | add // 0),
       span_s:     (if length > 0 then ((map(.ts) | max) - (map(.ts) | min)) * 10 | round / 10
                    else 0 end)}' "$log" 2>/dev/null) \
    || row='{"state":"unreadable"}'
  out=$(jq -c --arg l "$lens" --argjson r "$row" '.[$l] = $r' <<<"$out")
done

jq --arg m "${MCP_STATE:-unknown}" '{lens_mcp_state: $m, lenses: .}' <<<"$out"
