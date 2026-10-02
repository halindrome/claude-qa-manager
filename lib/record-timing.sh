#!/usr/bin/env bash
# record-timing.sh — append one round's observed timing to a per-project history.
#
# Usage:  record-timing.sh <scratch-dir>
#
# WHAT IT RECORDS AND WHY THAT STATISTIC. The stall detector measures ONE thing:
# how long the round has gone without writing. So the number worth learning is not
# the average lens duration, it is the MAXIMUM GAP BETWEEN WRITES — the longest
# silence that was still healthy. Measured on a real round those differ sharply:
# six lenses ran ~11.5 minutes total, but produced a single 8m55s silence from
# fan-out to the first return and then finished within a 2m18s burst. An estimator
# built on mean duration would have set a fuse that fires during normal operation.
#
# This only OBSERVES. Nothing reads the history yet, deliberately: the current
# threshold is a constant someone guessed (twice, wrongly), and the honest fix is
# to collect real distributions per project before choosing an estimator, rather
# than inventing another multiplier on one data point.
set -uo pipefail

S="${1:-}"
[ -n "$S" ] && [ -d "$S" ] || { echo "record-timing: no scratch dir" >&2; exit 0; }
[ -f "$S/status" ] || exit 0

IFS='|' read -r MR TARGET ROUND PHASE DONE TOTAL START TARGET_ABS LENS_STALL < "$S/status" || exit 0
[ -n "${MR:-}" ] || exit 0

# A round predating target_abs in the status line would otherwise file itself under
# "unknown", pooling unrelated projects into one history — the opposite of what a
# per-project estimate needs. Recover it from the round's own preflight.json.
if [ -z "${TARGET_ABS:-}" ] && [ -f "$S/preflight.json" ]; then
  TARGET_ABS=$(jq -r '.target_abs // empty' "$S/preflight.json" 2>/dev/null)
fi
[ -n "${TARGET_ABS:-}" ] || exit 0

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }

# Fan-out stamp, written by the manager when it launches the panel. Without it the
# first (and largest) gap is unmeasurable, so refuse to guess: a history row that
# silently omits the biggest silence is worse than no row.
[ -f "$S/fanout" ] || exit 0
FANOUT=$(tr -d '[:space:]' < "$S/fanout" 2>/dev/null)
case "$FANOUT" in ''|*[!0-9]*) exit 0 ;; esac

# Every write we can still see after the fact: each lens landing, then the final
# status rewrite. Sorted, because completion order is not creation order.
times=$(for f in "$S"/lens-*.json; do [ -f "$f" ] && mtime "$f"; done | sort -n)
LENS_N=$(printf '%s\n' "$times" | grep -c '[0-9]' || true)

max_gap=0; prev="$FANOUT"
for t in $times; do
  g=$(( t - prev )); [ "$g" -gt "$max_gap" ] && max_gap=$g
  prev=$t
done
end=$(mtime "$S/status")
if [ -n "${end:-}" ] && [ "$end" -gt "$prev" ]; then
  g=$(( end - prev )); [ "$g" -gt "$max_gap" ] && max_gap=$g
fi
lens_phase=$(( ${end:-$prev} - FANOUT ))
[ "$lens_phase" -lt 0 ] && lens_phase=0

# One history file per project, outside the repo so it is never committed and
# never shows up in `git status` on someone's feature branch.
HIST_DIR="$HOME/.config/claude-qa-manager/timings"
mkdir -p "$HIST_DIR" 2>/dev/null || exit 0
key=$(printf '%s' "${TARGET_ABS:-unknown}" | { shasum -a 256 2>/dev/null || sha256sum; } | awk '{print $1}' | cut -c1-16)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "${end:-$prev}" "${TARGET_ABS:-unknown}" "$MR" "$ROUND" "$LENS_N" "$max_gap" "$lens_phase" \
  >> "$HIST_DIR/$key.tsv"

printf 'recorded: %s lenses, max gap %ss, lens phase %ss -> %s\n' \
  "$LENS_N" "$max_gap" "$lens_phase" "$HIST_DIR/$key.tsv"
