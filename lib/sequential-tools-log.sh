#!/usr/bin/env bash
# sequential-tools-log.sh — write tools-sequential.jsonl for a round reviewed on the
# sequential path, in the same event format lib/lens-tool-log.sh writes for a panel.
#
# Usage:  sequential-tools-log.sh <scratch-dir>
# Prints: the log basenames it wrote (tools-sequential.jsonl, or tools-sequential-<n>.jsonl
#         when several reviewers ran in the round), or nothing when none could be found.
# Exit:   0 always once the usage check passes — a missing transcript is "not recorded",
#         reported by the caller, never an error that stops a summary.
#
# WHY A TRANSCRIPT, NOT A HOOK. A panel lens is a `claude -p` process, so run-panel.sh
# hands it a hook through --settings. The sequential reviewer is an Agent subagent of
# the operator's own session: the only hook that reaches it is a plugin-wide one, which
# would fire in every session of every operator. Its transcript is persisted, though,
# and holds every tool_use and tool_result.
#
# FINDING IT, without guessing. The reviewer's prompt does not name the scratch dir; the
# MAIN session's transcript does, and it holds the Agent call whose id the subagent's
# `.meta.json` records as `toolUseId`. One session runs many rounds, so only
# qa-reviewer Agent calls between this round's `fanout` stamp and its tree-after
# snapshot (or the status write) count. None found -> nothing written.
#
# FIDELITY. Same events as the hook: Pre for every tool_use; PostToolUse or
# PostToolUseFailure from the matching tool_result; NO Post for a call a hook or
# permission blocked, so `no_result` means the same thing on both paths. `ms` is the gap
# between the two transcript records, so it includes hook and queueing time — close to,
# not the same as, the duration Claude Code reports to a hook.
set -uo pipefail

S="${1:-}"
[ -n "$S" ] && [ -d "$S" ] || { echo "usage: sequential-tools-log.sh <scratch-dir>" >&2; exit 2; }
S=$(cd "$S" && pwd -P)

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null; }
# Derived data, regenerated on every call: the scratch dir is keyed to the MR, not the
# round, so a log left from an earlier round would otherwise be read as this one's.
rm -f "$S"/tools-sequential.jsonl "$S"/tools-sequential-*.jsonl
[ -f "$S/fanout" ] || exit 0
_f=$(tr -cd '0-9' < "$S/fanout" 2>/dev/null)
[ -n "$_f" ] || _f=$(mtime "$S/fanout")
T0=$(( _f - 120 ))
# The window closes at this round's tree-after snapshot -- but only if that snapshot IS
# this round's: a round that never finished leaves the previous round's file, older than
# its own fanout, and closing the window there makes it empty. Then the latest status
# write stands in.
T1=$(date +%s)
[ -f "$S/status" ] && T1=$(mtime "$S/status")
if [ -f "$S/tree-after.txt" ] && [ "$(mtime "$S/tree-after.txt")" -ge "$_f" ]; then
  T1=$(mtime "$S/tree-after.txt")
fi
T1=$(( T1 + 120 ))
TAG=$(basename "$S")

# CLAUDE_CONFIG_DIR is usually one of the defaults; scanning it twice finds every
# reviewer twice. Resolve and de-duplicate.
roots=$(for d in "${CLAUDE_CONFIG_DIR:-}" "$HOME/.config/claude-code" "$HOME/.claude"; do
          [ -n "$d" ] && [ -d "$d/projects" ] && (cd "$d/projects" && pwd -P)
        done | sort -u)

subs=()
for root in $roots; do
  # A main transcript touched since the round began and naming this round's scratch dir.
  while IFS= read -r main; do
    grep -q "$TAG" "$main" 2>/dev/null || continue
    for id in $(jq -R -r --argjson t0 "$T0" --argjson t1 "$T1" '
        fromjson? | select(.timestamp? and (.message.content? | type) == "array")
        | (.timestamp | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) as $t
        | select($t >= $t0 and $t <= $t1)
        | .message.content[]
        | select(.type == "tool_use" and .name == "Agent"
                 and .input.subagent_type == "claude-qa-manager:qa-reviewer")
        | .id' "$main" 2>/dev/null); do
      meta=$(grep -rl --include='*.meta.json' "\"toolUseId\":\"$id\"" "${main%.jsonl}/subagents" 2>/dev/null | head -1)
      [ -n "$meta" ] && [ -f "${meta%.meta.json}.jsonl" ] && subs+=("${meta%.meta.json}.jsonl")
    done
  done < <(find "$root" -maxdepth 2 -name '*.jsonl' -newer "$S/fanout" 2>/dev/null)
done

[ "${#subs[@]}" -gt 0 ] || exit 0
uniq_subs=()
while IFS= read -r s; do uniq_subs+=("$s"); done < <(printf '%s\n' "${subs[@]}" | sort -u)
subs=("${uniq_subs[@]}")
n=0
for sub in "${subs[@]}"; do
  n=$((n + 1))
  if [ "${#subs[@]}" -eq 1 ]; then name="tools-sequential.jsonl"; else name="tools-sequential-$n.jsonl"; fi
  jq -R -n -c '
    def ep: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601;
    def summ: (.file_path // .command // .query // .pattern // .name_pattern
               // .qualified_name // .code // .) | tostring | .[0:160];
    def text: if type == "string" then . else (map(select(type == "object") | .text // "") | join(" ")) end;
    [inputs | fromjson?] as $r
    | ([ $r[] | select(.type == "user" and (.message.content? | type) == "array")
         | (.timestamp | ep) as $t
         | .message.content[] | select(.type == "tool_result")
         | {key: .tool_use_id, value: {t: $t, err: (.is_error // false), txt: (.content | text)}} ]
       | from_entries) as $res
    | $r[] | select(.type == "assistant" and (.message.content? | type) == "array")
    | (.timestamp | ep) as $t
    | .message.content[] | select(.type == "tool_use")
    | . as $u | ($u.input // {} | summ) as $in | $res[$u.id] as $x
    | {ts: $t, ev: "PreToolUse", tool: $u.name, id: $u.id, ms: null, err: null, in: $in},
      ( if $x == null then empty
        elif $x.err and ($x.txt | test("^PreToolUse:.*hook error|has been denied")) then empty
        elif $x.err then {ts: $x.t, ev: "PostToolUseFailure", tool: $u.name, id: $u.id,
                          ms: ((($x.t - $t) * 1000) | floor), err: ($x.txt | .[0:200]), in: $in}
        else {ts: $x.t, ev: "PostToolUse", tool: $u.name, id: $u.id,
              ms: ((($x.t - $t) * 1000) | floor), err: null, in: $in} end )
  ' "$sub" > "$S/$name" 2>/dev/null && printf '%s\n' "$name"
done
exit 0
