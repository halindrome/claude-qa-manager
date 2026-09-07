#!/usr/bin/env bash
# set-phase.sh — the ONLY writer of $QA_SCRATCH/status.
#
# Usage:  set-phase.sh <scratch-dir> <phase>
#         set-phase.sh <scratch-dir> -        # keep the current phase, refresh the rest
#
# WHY THIS EXISTS. qa-manager.md told the manager, in prose, to "set phase to
# merging, then rendering, posting" and to "use Bash, not the Write tool". It
# never said the file is nine pipe-delimited fields, and the manager cannot be
# blamed for the result. Observed live on two consecutive rounds, in two
# different sessions, through two different tools:
#
#   printf 'phase=lenses round=1 lenses=0/5\n'    > .../status     (Bash)
#   printf 'phase=lenses round=2 lenses=0/5\n'    > .../status     (ctx_execute)
#
# It is a faithful rendering of the sentence it was given. What it destroys is
# the machine-readable line: field 1 (mr) became prose, fields 2-3 (target,
# round) became empty, and by the end of the round the counter and the epoch
# start had been zeroed too -- so statusline-fragment.sh rendered a round whose
# identity fields were a sentence, and round-return.sh copied the wreck forward.
#
# A louder instruction is the fix that already failed once here (see the header
# of lens-landed.sh). The fix is to leave the model nothing to format: a phase
# transition is now a script call, and this script owns the line's shape.
#
# It also removes the reason the corruption spread. run-panel.sh, round-return.sh
# and lens-landed.sh each carried their own copy of the nine-field printf, each
# COPYING FIELDS 1-3 THROUGH FROM THE FILE -- so one bad write by anyone was
# laundered by all three for the rest of the round. Here they are rebuilt from
# manager-brief.txt, which preflight rendered and no model edits, and the round
# heals at the next transition instead of degrading.
#
# The counter is never passed in, for the same reason lens-landed.sh counts from
# disk: a number a caller remembers is a number that can disagree with the files
# that exist.
set -uo pipefail

S="${1:-}"; PHASE="${2:-}"
[ -n "$S" ] && [ -d "$S" ] || { echo "set-phase: no scratch dir" >&2; exit 2; }
[ -n "$PHASE" ] || { echo "set-phase: no phase" >&2; exit 2; }

# A closed vocabulary, so an invented phase is a hard error rather than a value
# statusline-fragment.sh silently fails to recognise. `lenses` is the one the
# 1200s stall fuse is keyed on; the sequential path uses `reviewing` for the same
# position, which is why both are here.
case "$PHASE" in
  preflight|lenses|reviewing|merging|rendering|posting|done|-) : ;;
  *) echo "set-phase: unknown phase '$PHASE' (preflight|lenses|reviewing|merging|rendering|posting|done)" >&2
     exit 2 ;;
esac

STATUS="$S/status"
BRIEF="$S/manager-brief.txt"
brief() { [ -f "$BRIEF" ] && sed -n "s/^$1=//p" "$BRIEF" | tail -1; }

# Whatever is on disk now, which may be prose. Read for the fields nothing else
# can supply -- never trusted for the ones the brief carries.
_m=''; _t=''; _r=''; _p=''; _d=''; _tt=''; _st=''; _ta=''; _ls=''
[ -f "$STATUS" ] && IFS='|' read -r _m _t _r _p _d _tt _st _ta _ls < "$STATUS"

MR=$(brief mr);                 [ -n "$MR" ]         || MR="$_m"
TARGET=$(brief target);         [ -n "$TARGET" ]     || TARGET="$_t"
ROUND=$(brief round);           [ -n "$ROUND" ]      || ROUND="$_r"
TARGET_ABS=$(brief target_abs); [ -n "$TARGET_ABS" ] || TARGET_ABS="$_ta"

# Total from the brief's lens array; the existing field only if there is no brief.
TOTAL=$(brief lenses | jq -r 'length' 2>/dev/null)
case "${TOTAL:-}" in ''|*[!0-9]*) TOTAL="${_tt:-}" ;; esac
case "${TOTAL:-}" in ''|*[!0-9]*) TOTAL=0 ;; esac

# Ground truth, not an increment.
DONE=0
for f in "$S"/lens-*.json; do [ -f "$f" ] && DONE=$((DONE + 1)); done

# epoch_start is what elapsed time is measured from, so it is preserved across
# every transition and invented only when there is nothing to preserve. A zero
# here is what made round 1153 report a nonsense duration.
case "${_st:-}" in ''|0|*[!0-9]*) START=$(date +%s) ;; *) START="$_st" ;; esac

# lens_stall_seconds: the project's resolved stall tolerance, preserved and not
# re-derived from config here -- that resolution belongs to preflight (see its
# "Round progress" block), and a second copy of it would drift.
case "${_ls:-}" in ''|*[!0-9]*) LENS_STALL=1200 ;; *) LENS_STALL="$_ls" ;; esac

if [ "$PHASE" = '-' ]; then
  # Preserve, but only a phase from the vocabulary. A prose field 4 is not a
  # phase to keep, and substituting one would be a guess dressed as a reading --
  # so this says so rather than inventing `lenses`.
  case "${_p:-}" in
    preflight|lenses|reviewing|merging|rendering|posting|done) PHASE="$_p" ;;
    *) echo "set-phase: status carried no recognisable phase ('${_p:-}'); counter refreshed, phase recorded as unknown" >&2
       # `unknown`, not empty and not a guess. Empty is indistinguishable from a
       # phase nobody set, and substituting `lenses` would hand a merge the long
       # lens-stall fuse. This is the "did not run" state for the phase field.
       PHASE=unknown ;;
  esac
fi

printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
  "$MR" "$TARGET" "$ROUND" "$PHASE" "$DONE" "$TOTAL" "$START" "$TARGET_ABS" "$LENS_STALL" \
  > "$STATUS" || { echo "set-phase: could not write $STATUS" >&2; exit 1; }

printf 'set-phase: %s (%s/%s)\n' "$PHASE" "$DONE" "$TOTAL"
