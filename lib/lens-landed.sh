#!/usr/bin/env bash
# lens-landed.sh — record one lens's return: persist its findings AND refresh the
# progress counter, in a single call that cannot do one without the other.
#
# Usage:  lens-landed.sh <scratch-dir> <lens-name> < findings.json
#
# WHY THIS EXISTS. qa-manager.md §1.5 asked the manager to do two Bash writes per
# lens return: save `lens-<name>.json`, then rewrite the one-line status file
# copying six fields through verbatim and incrementing `done` itself. Marked
# MANDATORY, and it did not happen. Observed on a live round: four lens files
# landed across a 100-second window while `status` sat at `0/4`, last written
# 6m41s before the FIRST lens arrived; the round then jumped straight to
# `4/4 done`. The counter is never anything but 0/N or N/N, so it is not a
# progress signal at all -- it is a two-state latch that reads "nothing has
# happened" for the whole 11-28 minutes (p90 22m) anyone would want to watch.
#
# What that costs, measured over the 281 recorded rounds that fanned out:
#   - statusline/watch-round show 0/N for the entire fan-out. An operator watching
#     a healthy round sees a frozen counter and concludes it is wedged. That is
#     not hypothetical; it happened, to the person who wrote the tool.
#   - The stall fuse in statusline-fragment.sh measures `now - <status mtime>`
#     against 1200s, and config/defaults.json states the premise it was tuned on:
#     "the status file is rewritten when a lens RETURNS, so the legitimate silence
#     between writes is however long your slowest lens takes". With no rewrite the
#     silence is the WHOLE fan-out instead -- median 688s vs 399s, p90 1317s vs
#     771s -- so 21 of 281 rounds (7%) would be called stalled while perfectly
#     healthy, and p90 already exceeds the default fuse.
#
# So the fix is not a louder instruction and NOT a bigger threshold, which would
# only hide a signal that is missing rather than restore it. Two properties do it:
#
#   1. One call, not two. There is no longer a second step to omit -- saving the
#      findings and refreshing the counter are the same action.
#   2. `done` is COUNTED FROM DISK, never passed in. The manager cannot report a
#      number that disagrees with the files that exist, which is the failure the
#      hand-incremented counter invites across a long context.
#
# Every other field is copied through from the existing status line by this
# script rather than by the caller: epoch_start is what elapsed time is measured
# from, target_abs scopes the round to its project (drop it and two concurrent
# cycles display each other's progress), and lens_stall_seconds is the project's
# resolved tolerance. Re-deriving any of them here would put a second, drifting
# copy of that resolution in the wrong place.
set -uo pipefail

S="${1:-}"; NAME="${2:-}"
[ -n "$S" ] && [ -d "$S" ] || { echo "lens-landed: no scratch dir" >&2; exit 2; }
[ -n "$NAME" ] || { echo "lens-landed: no lens name" >&2; exit 2; }
case "$NAME" in */*|..|.) echo "lens-landed: bad lens name '$NAME'" >&2; exit 2 ;; esac

# The findings land first and unconditionally. They are the round's actual work
# and this script's recovery point: if a later lens dies, five completed reviews
# must not die with it. A status file that cannot be refreshed is a reporting
# problem; losing a lens's output is a re-run of the whole panel.
cat > "$S/lens-$NAME.json" || { echo "lens-landed: could not write lens-$NAME.json" >&2; exit 1; }

if [ ! -f "$S/status" ]; then
  echo "lens-landed: no status file in $S; findings saved, progress NOT refreshed" >&2
  exit 0
fi

IFS='|' read -r MR TARGET ROUND PHASE DONE TOTAL START TARGET_ABS LENS_STALL < "$S/status" || {
  echo "lens-landed: unreadable status line; findings saved, progress NOT refreshed" >&2
  exit 0
}
[ -n "${MR:-}" ] || { echo "lens-landed: empty status line; findings saved, progress NOT refreshed" >&2; exit 0; }

# Ground truth, not an increment. `ls | wc -l` over the round's own files cannot
# drift from reality the way a remembered counter does.
DONE_NOW=0
for f in "$S"/lens-*.json; do [ -f "$f" ] && DONE_NOW=$((DONE_NOW + 1)); done

printf '%s|%s|%s|lenses|%s|%s|%s|%s|%s\n' \
  "$MR" "$TARGET" "$ROUND" "$DONE_NOW" "$TOTAL" "$START" "$TARGET_ABS" "$LENS_STALL" \
  > "$S/status"

printf 'lens-landed: %s (%s/%s)\n' "$NAME" "$DONE_NOW" "$TOTAL"
