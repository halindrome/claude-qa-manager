#!/usr/bin/env bash
# watch-round.sh — live view of any QA round in flight. Run it in a spare terminal.
#
# Usage:  watch-round.sh [interval-seconds]   (default 5)
#
# WHY THIS EXISTS SEPARATELY FROM THE STATUSLINE. A statusline only repaints on
# main-thread activity, and during a round the main thread is blocked waiting on a
# backgrounded manager — so the one moment you want progress is exactly when the
# statusline stops updating. Observed on a real round: the fragment reported
# `rendering 14m` correctly when invoked, while the on-screen statusline still
# showed the value from 11 minutes earlier. This polls on its own clock instead.
set -uo pipefail

INTERVAL="${1:-5}"
SCRATCH_ROOT="${QA_CYCLE_SCRATCH_ROOT:-/tmp}"

hms() {  # seconds -> compact
  local s=$1
  if   [ "$s" -lt 60 ];   then printf '%ds' "$s"
  elif [ "$s" -lt 3600 ]; then printf '%dm%02ds' $(( s / 60 )) $(( s % 60 ))
  else printf '%dh%02dm' $(( s / 3600 )) $(( (s % 3600) / 60 )); fi
}

while :; do
  now=$(date +%s)
  printf '\033[H\033[2J'                      # home + clear
  printf 'QA rounds — %s   (refresh %ss, ctrl-c to stop)\n\n' "$(date '+%H:%M:%S')" "$INTERVAL"
  found=0
  for d in "$SCRATCH_ROOT"/qa-cycle-*/; do
    [ -f "$d/status" ] || continue
    found=1
    IFS='|' read -r mr target round phase done total start target_abs lens_stall < "$d/status"
    age=$(( now - $(stat -f %m "$d/status" 2>/dev/null || stat -c %Y "$d/status" 2>/dev/null) ))
    printf '  !%s  %s  round %s  [%s]  %s/%s lenses  elapsed %s  quiet %s\n' \
      "$mr" "${target:-?}" "${round:-?}" "${phase:-?}" "${done:-0}" "${total:-?}" \
      "$(hms $(( now - ${start:-$now} )))" "$(hms "$age")"
    [ -n "${target_abs:-}" ] && printf '        %s\n' "$target_abs"
    # Only count files written AFTER this round fanned out. The scratch dir is
    # keyed to the MR, not the round, so round N-1's results sit right here and
    # would otherwise show as six done on a round that has finished two. The round
    # is supposed to clear them; this does not depend on it having done so.
    fo=0; [ -f "$d/fanout" ] && fo=$(tr -cd '0-9' < "$d/fanout")
    for f in "$d"/lens-*.json; do
      [ -f "$f" ] || continue
      m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
      [ "${fo:-0}" -gt 0 ] && [ "$m" -lt "$fo" ] && continue
      n=$(basename "$f"); n=${n#lens-}; n=${n%.json}
      printf '        ✓ %s\n' "$n"
    done
    # The panel is invisible between fan-out and the first return; say so rather
    # than leaving a blank that reads as "nothing is happening".
    if [ "${phase:-}" = "lenses" ] && [ "${done:-0}" = "0" ]; then
      printf '        (lenses running — no output until the first one returns)\n'
    fi
    printf '\n'
  done
  [ "$found" = "1" ] || printf '  no round in flight\n'
  sleep "$INTERVAL"
done
