#!/usr/bin/env bash
# run-panel.sh — run the preflight-selected lens panel as `claude -p` subprocesses.
#
# Usage:  run-panel.sh <scratch-dir> [--skip-contract-verification]
# Exit:   0 every lens landed | 1 partial | 2 usage | 3 nothing landed | 5 internal
#
# WHY THIS EXISTS. The panel used to be fanned out by a model (agents/qa-manager.md
# §1): it resolved each lens's model, composed each prompt, named each output file,
# incremented a counter, and remembered which lenses failed. Every one of those was
# dropped at least once on a live round -- `"model": "sonnet"` invented against an
# explicit rule, SEVEN different names for one merged-findings file, a progress
# counter latched at `0/N` for the whole fan-out, a wedged lens detectable only by a
# stall heuristic. None of that is a comprehension failure that a louder instruction
# fixes; they are bookkeeping, and bookkeeping belongs in a script. So: the model is
# an ARGUMENT, the filenames belong to THIS file, the counter is written when a lens
# lands, a failed lens is a FILE ON DISK, and a wedged lens is a watchdog kill.
#
# WHY `claude -p` RATHER THAN Agent SUBAGENTS. Measured, not assumed
# (docs/ROADMAP.md "Phase 1 parity result"): on one recovered real lens prompt the
# `-p` arm produced 7 findings and 39 contract rows against the Agent arm's 3 and 24,
# actually CALLED the code-graph tools where the Agent lenses called them zero times,
# and ran in 1.39x the wall clock. It also gets three things the Agent path cannot:
# `--strict-mcp-config` makes the lens tool surface a property of this plugin instead
# of the operator's account; `--output-format json` reports the model that ACTUALLY
# ran; and a failed lens is an exit code instead of a thing to remember.
#
# THE ONE CRITERION THE PARITY GATE FAILED, AND WHAT FIXES IT. The `-p` arm returned
# a markdown round-note instead of lens JSON, because `--agent` loads
# agents/qa-reviewer.md whose `## Output Format` section prescribes markdown, and
# that SYSTEM prompt beat the USER prompt's request for JSON. The Agent path has the
# identical conflict and JSON merely happened to win -- so the format was never
# stable, it was a coin toss. `--json-schema` settles it: the schema is enforced by
# the runtime, not requested in prose. Probed against a system prompt that said
# "Never emit JSON" and the schema still won.
#
# NO RETRY. agents/qa-manager.md used to say "re-run once, then record it". A retry
# doubles the cost of the failure most likely to repeat -- a wedged lens burns the
# watchdog twice -- and it hides the failure from the round note, which is the one
# place an operator would see it. Re-running the round is a human's call. Every
# failure mode below is therefore terminal, distinguishable, and written down.
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)

die_usage()    { echo "run-panel.sh: $1" >&2; exit 2; }
die_internal() { echo "run-panel.sh: $1" >&2; exit 5; }

S="${1:-}"
[ -n "$S" ] || die_usage "usage: run-panel.sh <scratch-dir> [--skip-contract-verification]"
shift
[ -d "$S" ] || die_usage "no such scratch dir: $S"

SKIP_CONTRACT=false
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-contract-verification) SKIP_CONTRACT=true ;;
    *) die_usage "unknown flag: $1" ;;
  esac
  shift
done

BRIEF="$S/manager-brief.txt"
[ -f "$BRIEF" ] || die_usage "no manager-brief.txt in $S (run preflight first)"

# Hydrate from the brief, never from config. preflight resolves, the consumer
# displays (lib/preflight.sh, "Manager brief"). Re-resolving the three config
# layers here would put a second, drifting copy of that resolution in the wrong
# place -- and the brief is the payload rendered FOR this consumer.
brief() { sed -n "s/^$1=//p" "$BRIEF" | tail -1; }

TARGET_ABS=$(brief target_abs)
ROUND=$(brief round)
MR=$(brief mr)
LENSES_JSON=$(brief lenses)
REVIEW_MODEL=$(brief review_model)
LENS_MODELS=$(brief lens_models)
ALLOWED_MODELS=$(brief allowed_models)
DIFF_RANGE=$(brief diff_range)
FEATURE_BRANCH=$(brief feature_branch)
TARGET_BRANCH=$(brief target_branch)
CONTRACT_PATH=$(brief contract_path)
SAST_PATH=$(brief sast_path)
SCHEMA_CHANGE_PATH=$(brief schema_change_path)
MANDATE_PATH=$(brief tool_mandate_path)
PROPORTIONALITY_PATH=$(brief proportionality_path)
STATUS_FILE=$(brief status_path)
LENS_MCP=$(brief lens_mcp_path)
LENS_MCP_STATE=$(brief lens_mcp_state)

# The pinned tool surface. Preflight generates it from this machine's own
# registration -- it cannot be shipped, because --mcp-config takes launch
# commands and those are machine-local.
[ -n "$LENS_MCP" ] || LENS_MCP="$S/panel-mcp.json"
if [ ! -f "$LENS_MCP" ]; then
  # A scratch dir from before preflight generated this. An empty config is the
  # honest fallback -- --strict-mcp-config with no servers means the lens uses
  # Read/grep, which is a correct review -- but it is announced, because a silent
  # empty config looks identical to a working one right up until the mandate
  # names a tool that is not there.
  printf '{"mcpServers":{}}\n' > "$LENS_MCP"
  LENS_MCP_STATE="none:not-generated"
fi
case "${LENS_MCP_STATE:-}" in
  ok|'') : ;;
  *) echo "run-panel: lens tool surface is ${LENS_MCP_STATE} — lenses run without the tools the mandate names" >&2 ;;
esac

[ -d "$TARGET_ABS" ] || die_internal "target_abs is not a directory: $TARGET_ABS"
printf '%s' "$LENSES_JSON" | jq -e 'type == "array" and length > 0' >/dev/null 2>&1 \
  || die_internal "brief carries no usable lenses array"
LENSES=$(printf '%s' "$LENSES_JSON" | jq -r '.[]')
TOTAL=$(printf '%s' "$LENSES_JSON" | jq -r 'length')

CATALOG="$PLUGIN/config/lens-catalog.json"
SCHEMA_FILE="$PLUGIN/config/lens-schema.json"
[ -f "$CATALOG" ]     || die_internal "missing $CATALOG"
[ -f "$SCHEMA_FILE" ] || die_internal "missing $SCHEMA_FILE"

# Strip the rationale comments before handing the schema to the CLI: the schema is
# documentation AND a wire payload, and a validator is entitled to reject a keyword
# it does not know. Keeping the why in the file (invariant 3) must not cost us the
# mechanism.
SCHEMA=$(jq -c 'del(.. | objects | ."$comment")' "$SCHEMA_FILE") \
  || die_internal "config/lens-schema.json is not valid JSON"

# Field 9 of the status line is the project's own resolved stall tolerance. Reading
# it here rather than re-deriving from config is the same division of labour as
# everything else in this script -- and it is what the stall detector is tuned to,
# so a watchdog on any other number would kill lenses the fuse considers healthy.
LIMIT=1200
if [ -f "$STATUS_FILE" ]; then
  _l=$(awk -F'|' '{print $9}' "$STATUS_FILE" | tr -cd '0-9')
  [ -n "$_l" ] && LIMIT="$_l"
fi

# ---------------------------------------------------------------------------
# Round hygiene. $QA_SCRATCH is keyed to the MR, not the round, so last round's
# lens files are still sitting here. Leave them and round-return.sh derives
# `failed_lenses` against a directory that still contains a stale success --
# a lens that never ran this round reporting as landed, which is invariant 2's
# exact failure shape.
# ---------------------------------------------------------------------------
# Delete BY NAME, never by glob. `rm -f "$S"/lens-*.json` reads as obviously
# correct and is not: it also matches `lens-mcp.json`, the --mcp-config file
# preflight generates into this same directory. On the first live round it
# deleted that file microseconds before the first lens started, and all four
# lenses died instantly with "MCP config file not found" -- while preflight.json
# still reported `lens_mcp_state: ok`, because preflight HAD written it.
# That is the second time the `lens-*` namespace has claimed a file that is not
# one lens's findings. Enumerating the catalog is not more code than a glob, and
# it cannot reach a filename nobody thought about.
for _l in $(jq -r 'to_entries[] | select(.key | startswith("$") | not) | .key' "$CATALOG"); do
  rm -f "$S/lens-$_l.json" "$S/failed-$_l.json" "$S/raw-$_l.json" "$S/err-$_l.txt"
done

# fanout + tree snapshots. These were the MANAGER's bookkeeping
# (agents/qa-manager.md:202,268) and both fail SILENTLY if nobody writes them:
# record-timing.sh exits 0 with no history row when `fanout` is absent, and
# round-return.sh leaves tree_mutated=false when the tree pair is absent -- an
# absent check reporting clean. The driver owns them now because the driver is
# what brackets the panel.
date +%s > "$S/fanout"
# HEAD and the branch name are in the snapshot, NOT just the porcelain status.
# Porcelain alone catches a lens editing a file, but a clean branch switch leaves
# it byte-identical -- so a second round checking out its own branch in the same
# working tree would compare equal and report the tree unmutated. `-uall` because
# porcelain collapses an untracked DIRECTORY to one `?? dir/` line, which hides a
# lens dropping a new file inside one. Both of these are inherited from the
# manager's snap (agents/qa-manager.md), deliberately: this replaces that code,
# so it has to carry the reasons that code was written the way it was.
snap() {
  git -C "$TARGET_ABS" rev-parse HEAD 2>/dev/null
  git -C "$TARGET_ABS" rev-parse --abbrev-ref HEAD 2>/dev/null
  git -C "$TARGET_ABS" status --porcelain -uall 2>/dev/null
}
snap > "$S/tree-before.txt"

# phase=lenses. lens-landed.sh deliberately PRESERVES phase (it owns the counter,
# the caller owns what the round is doing), so if this script does not stamp it the
# status line sits at `preflight` for the whole panel and
# statusline-fragment.sh never arms the long lens-stall fuse -- every healthy round
# would then be reported as stalled at the short one.
#
# Delegated rather than printf'd here, and that is the fix for a live defect: this
# used to copy fields 1-3 through from the file, so a manager that had overwritten
# `status` with a prose line got that prose PRESERVED into the mr field for the
# whole round. set-phase.sh rebuilds them from the brief instead, which means the
# panel heals a corrupted line rather than laundering it.
bash "$HERE/set-phase.sh" "$S" lenses >/dev/null \
  || echo "run-panel: could not stamp phase=lenses; the round is unaffected but the stall fuse is on the short setting" >&2

# ---------------------------------------------------------------------------
# Prompt composition.
#
# This does NOT live in preflight, and the reason is not style: contract.md is
# written by Step 0.5, which runs AFTER preflight, and --skip-contract-verification
# is a per-invocation flag preflight never sees. A preflight-rendered prompt would
# either omit the contract or be stale.
#
# The mandates are injected as TITLED SECTIONS, never as a preamble above a
# divider. That is measured, not aesthetic: the section form drives lens tool
# adoption and a detached preamble gets ignored.
# ---------------------------------------------------------------------------
compose() {   # $1 = lens name -> writes $S/prompt-<lens>.txt
  local lens="$1" focus
  focus=$(jq -r --arg l "$lens" '.[$l].focus // empty' "$CATALOG")
  # An unknown lens name is fatal, never an invented mandate: a lens with a
  # made-up focus reviews nothing in particular while reporting as a full panel
  # member.
  [ -n "$focus" ] || return 1

  {
    printf '# QA lens: %s — round %s of MR %s\n\n' "$lens" "$ROUND" "$MR"

    if [ -s "$MANDATE_PATH" ]; then
      printf '## Code navigation\n\n'; cat "$MANDATE_PATH"; printf '\n'
    fi
    # Absent is the normal state when neither CMM nor Context-Mode is registered
    # (preflight writes the file only inside that branch), and it is NOT the same
    # as a missing proportionality file below -- this one legitimately does not
    # exist, so it gets no warning.

    if [ -s "$PROPORTIONALITY_PATH" ]; then
      printf '## Proportionality\n\n'; cat "$PROPORTIONALITY_PATH"; printf '\n'
    else
      printf '## Proportionality\n\nNOT AVAILABLE — preflight did not emit %s.\n' \
             "$PROPORTIONALITY_PATH"
      printf 'Report this in your findings: a round run without it is not\n'
      printf 'comparable to one run with it.\n\n'
    fi

    printf '## Your focus\n\n%s\n\n' "$focus"

    printf '## The change under review\n\n'
    printf -- '- Repository: `%s`\n' "$TARGET_ABS"
    printf -- '- Diff range: `%s`\n' "$DIFF_RANGE"
    printf -- '- Feature branch: `%s` → target `%s`\n' "$FEATURE_BRANCH" "$TARGET_BRANCH"
    printf -- '- Round: %s\n\n' "$ROUND"

    printf '## Evidence files (read the ones your focus needs)\n\n'
    if [ "$SKIP_CONTRACT" = "true" ]; then
      printf -- '- Contract: SKIPPED at user request. Do not verify acceptance criteria;\n'
      printf '  emit `contract_verification: []` and say so in a finding only if that\n'
      printf '  omission itself creates a risk.\n'
    else
      printf -- '- Contract / acceptance criteria: `%s`\n' "$CONTRACT_PATH"
    fi
    printf -- '- SAST report (NEW vs baseline): `%s`\n' "$SAST_PATH"
    printf -- '- Schema change evidence: `%s`\n\n' "$SCHEMA_CHANGE_PATH"

    printf '## Return\n\n'
    printf 'Your final message is validated against a JSON schema; the runtime\n'
    printf 'enforces the shape, so spend your effort on the review, not the format.\n'
    printf 'Ground every finding in an acceptance criterion or a regression this diff\n'
    printf 'introduces. Set `navigation` to what you ACTUALLY used — it is\n'
    printf 'cross-checked against the run record, and a false claim is itself a defect.\n'
  } > "$S/prompt-$lens.txt"
}

# ---------------------------------------------------------------------------
# Model resolution: lens_models[<name>] -> review_model. There is NO inherit:
# `claude -p` without --model runs whatever the operator's session defaults to,
# so a Haiku session would review on Haiku. A lens whose model is empty or not in
# allowed_models is not spawned at all (invariant 6: a cheaper reviewer is a
# weaker reviewer). Preflight refuses such a config; this is the same check
# failing closed on a brief it did not write.
# ---------------------------------------------------------------------------
resolve_model() {
  local lens="$1" m
  m=$(printf '%s' "$LENS_MODELS" | jq -r --arg l "$lens" '.[$l] // empty' 2>/dev/null)
  [ -n "$m" ] && { printf '%s' "$m"; return; }
  printf '%s' "$REVIEW_MODEL"
}

allowed() {  # $1 model id -> 0 iff it contains an allowed_models entry
  [ -n "$1" ] && [ "$1" != "null" ] && printf '%s' "$ALLOWED_MODELS" | jq -e --arg m "$1" \
    'type == "array" and length > 0
     and any(.[]; type == "string" and length > 0
                  and (. as $p | ($m | ascii_downcase) | contains($p | ascii_downcase)))' \
    >/dev/null 2>&1
}

# Which modelUsage key is the reviewer -- see the comment at the use site below.
_rank='(.value.inputTokens // 0) + (.value.cacheReadInputTokens // 0)
       + (.value.cacheCreationInputTokens // 0)'

fail_lens() {  # $1 lens, $2 state, $3 rc, $4 detail
  jq -n --arg l "$1" --arg s "$2" --arg rc "$3" --arg d "$4" \
    '{lens:$l, state:$s, rc:($rc|tonumber? // -1), detail:$d}' > "$S/failed-$1.json"
  echo "run-panel: $1 FAILED ($2) $4" >&2
}

# ---------------------------------------------------------------------------
# The panel. One subshell per lens, each owning its own watchdog, validation and
# landing: bash 3.2 has no `wait -n`, so a parent loop cannot do per-completion
# bookkeeping in completion order. Pushing the whole lifecycle into the subshell
# sidesteps that entirely -- and it is why the counter cannot latch.
# ---------------------------------------------------------------------------
for lens in $LENSES; do
  if ! compose "$lens"; then
    fail_lens "$lens" "unknown_lens" 0 "no entry in config/lens-catalog.json"
    continue
  fi
  model=$(resolve_model "$lens")
  if ! allowed "$model"; then
    fail_lens "$lens" "model_not_allowed" 0 "resolved '${model:-<none>}', allowed_models ${ALLOWED_MODELS:-<none>}"
    continue
  fi

  (
    set -- -p --model "$model"
    set -- "$@" --plugin-dir "$PLUGIN" --agent claude-qa-manager:qa-reviewer \
                --strict-mcp-config --mcp-config "$LENS_MCP" \
                --no-session-persistence \
                --output-format json --json-schema "$SCHEMA"
    # --no-session-persistence: up to six lenses run concurrently in ONE checkout,
    # so all six would persist sessions into the same per-directory project slug.
    # Nothing resumes a lens -- it is one non-interactive shot whose entire result
    # is the envelope we capture -- so the session file is write contention for a
    # thing no one reads. Phase 1 did not pass this flag, but Phase 1 ran a single
    # lens; concurrency is what makes it matter.

    cd "$TARGET_ABS" || exit 9
    claude "$@" < "$S/prompt-$lens.txt" > "$S/raw-$lens.json" 2> "$S/err-$lens.txt" &
    cpid=$!
    # macOS has no timeout(1). TERM first, then KILL: a bare KILL orphans the
    # lens's MCP server children (the code-graph server, the context-mode node
    # process), which then outlive the round and accumulate.
    #
    # The watchdog sleeps and signals in ONE process. Do NOT write it as
    # `( sleep N; kill ... ) &`: there the `sleep` is a CHILD of the subshell, so
    # killing the watchdog orphans the sleep for the rest of $LIMIT — one leak per
    # lens, six per round, adopted by init and still holding this script's
    # descriptors. Measured live at 6 orphaned `sleep 1200` per round before this.
    perl -e 'my ($lim,$pid) = @ARGV;
             sleep $lim;
             kill(15, $pid);
             sleep 10;
             kill(9, $pid);' "$LIMIT" "$cpid" </dev/null >/dev/null 2>&1 &
    wpid=$!
    disown "$wpid" 2>/dev/null || true
    wait "$cpid"; rc=$?
    kill -9 "$wpid" 2>/dev/null

    if [ "$rc" -ge 128 ]; then
      fail_lens "$lens" "watchdog_killed" "$rc" "exceeded ${LIMIT}s"
      exit 0
    fi
    if [ "$rc" -ne 0 ]; then
      fail_lens "$lens" "nonzero_exit" "$rc" "$(tail -c 400 "$S/err-$lens.txt" 2>/dev/null)"
      exit 0
    fi

    # The schema is enforced by the runtime, but "enforced" is a claim about the
    # happy path. Check it here too: an absent check that reports as a pass is the
    # failure this project is named after.
    if ! jq -e '.structured_output
                | (type == "object")
                  and has("navigation") and has("schema_change_detected")
                  and (.findings | type == "array")' \
              "$S/raw-$lens.json" >/dev/null 2>&1; then
      fail_lens "$lens" "invalid_output" 0 "no schema-shaped .structured_output"
      exit 0
    fi

    # Model actually used, from the run record rather than from the lens's word
    # for it. Every envelope carries TWO modelUsage keys -- the reviewer and
    # Claude Code's own helper traffic -- so which one is "the model" has to be
    # decided, and the first rule for deciding it was wrong.
    #
    # It ranked by outputTokens, and on a short lens that margin is noise:
    #   1153 ui-styling  opus out=3873  helper out=4043  -> reported the helper
    #   1152 ui-styling  opus out=2676  helper out=2368  -> reported the reviewer
    # Same lens, same config, 4% apart, opposite answers -- and the losing round
    # published "the ui-styling lens ran on <helper model>" to a real MR. The one
    # number this script exists to stop the manager inventing, it invented.
    #
    # INPUT is the discriminator, and it is not close: the reviewer carries the
    # cached round context (cacheRead 333k-2.6M across all 14 envelopes measured)
    # while the helper never reads cache at all (0, every time). Ranking by total
    # input picks the reviewer in 14 of 14, by better than 10x rather than 4%.
    actual=$(jq -r ".modelUsage | to_entries | max_by($_rank) | .key" \
                 "$S/raw-$lens.json" 2>/dev/null)
    # Below the floor is terminal and its findings do NOT land: a review the
    # rules do not accept is not a review, and landing it would count the lens
    # as done. An unreadable model fails the same way -- unknown is not allowed.
    if ! allowed "$actual"; then
      fail_lens "$lens" "model_below_floor" 0 "asked $model, ran ${actual:-<unknown>}; allowed_models $ALLOWED_MODELS"
      exit 0
    fi
    if [ "$actual" != "null" ]; then
      case "$actual" in
        *"$model"*) : ;;
        *) fail_lens "$lens" "model_mismatch" 0 "asked $model, ran $actual"
           # Recorded, NOT dropped: the model that ran is still on the
           # allow-list, so the review counts -- but a different model than
           # configured is written down rather than accepted silently.
           ;;
      esac
    fi

    jq '.structured_output' "$S/raw-$lens.json" \
      | bash "$HERE/lens-landed.sh" "$S" "$lens" >/dev/null \
      || fail_lens "$lens" "land_failed" $? "lens-landed.sh refused the payload"
  ) &
done
wait

snap > "$S/tree-after.txt"

# What each lens actually cost and actually ran as. This is the whole of the
# "record the model each lens ran as" problem, solved by reading the run record --
# no hook, no self-report, and available for the round note's per-lens model line.
#
# NOT `lens-models-actual.json`, and the near-miss is worth a line. `lens-*.json`
# is a LOAD-BEARING GLOB: round-return.sh:101 derives failed_lenses as
# `preflight.lenses - basename(lens-*.json)`, and lens-landed.sh counts the same
# glob for the progress denominator. A metadata file under that prefix reports as
# a landed lens called "models-actual" -- caught by the suite, which is the only
# reason it is not in the tree. Anything written here that is not one lens's
# findings must stay out of that namespace.
{
  echo "{"
  first=1
  for lens in $LENSES; do
    f="$S/raw-$lens.json"
    [ -f "$f" ] || continue
    [ "$first" = 1 ] || echo ","
    first=0
    printf '  "%s": ' "$lens"
    # `|| printf null` is NOT enough, and the first live round proved it: a lens
    # that fails before emitting anything leaves a ZERO-BYTE envelope, and jq on
    # an empty file prints nothing and exits 0 -- so the fallback never fires and
    # the object comes out as `"contract-security": ,` which is not JSON. The
    # guard has to be on the output, not on the exit code.
    # `model_check` is the floor verdict on the model that RAN: `allowed` or
    # `below_floor`. Stated per lens so the record never needs cross-reading
    # against failed-*.json to know whether a review counts.
    _mc=below_floor
    allowed "$(jq -r ".modelUsage | to_entries | max_by($_rank) | .key" "$f" 2>/dev/null)" \
      && _mc=allowed
    _pm=$(jq -c --arg mc "$_mc" \
            '{ model: (.modelUsage | to_entries
                 | max_by((.value.inputTokens // 0) + (.value.cacheReadInputTokens // 0)
                          + (.value.cacheCreationInputTokens // 0)) | .key),
             all_models: (.modelUsage | keys),
             model_check: $mc,
             cost_usd: .total_cost_usd, num_turns: .num_turns,
             duration_ms: .duration_ms,
             permission_denials: (.permission_denials | length),
             stop_reason: .stop_reason }' "$f" 2>/dev/null)
    printf '%s' "${_pm:-null}"
  done
  echo
  echo "}"
} > "$S/panel-models.json"

landed=$(ls "$S"/lens-*.json 2>/dev/null | wc -l | tr -d ' ')
failed=$(ls "$S"/failed-*.json 2>/dev/null | wc -l | tr -d ' ')
echo "run-panel: $landed/$TOTAL landed, $failed failed (round $ROUND, MR $MR)"

# The exit code IS the panel state, so nothing has to be remembered across the
# boundary. round-return.sh derives failed_lenses from the same directory.
[ "$landed" = "0" ] && exit 3
[ "$landed" = "$TOTAL" ] && exit 0
exit 1
