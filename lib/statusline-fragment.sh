#!/usr/bin/env bash
# statusline-fragment.sh — one short fragment describing a QA round in flight.
#
# Usage:  statusline-fragment.sh            # prints a fragment, or NOTHING
#
# Compose it into an existing statusline; do NOT install it as your whole
# statusLine. Example, inside your own statusline script:
#
#   qa=$(bash "$PLUGIN/lib/statusline-fragment.sh")
#   [ -n "$qa" ] && printf ' | %s' "$qa"
#
# Output shapes:
#   QA !706 rest-api r1 ◆3/6 4m          — alive, 3 of 6 lenses returned
#   QA !706 rest-api r1 ◆3/6 ⚠stalled 12m — nothing written for over STALL_AFTER
#   (nothing)                             — no round in flight
#
# DESIGN CONSTRAINTS, all learned the hard way:
#   - SILENT WHEN IDLE. This runs on every statusline repaint in every session
#     in every repo. A fragment that prints something when no round is running
#     is a permanent tax for an occasional event.
#   - CHEAP. One glob and one small read. No git, no jq, no network, no walking
#     preflight.json -- which is why preflight/the manager write a single
#     pre-formatted line instead of leaving the rendering to this script.
#   - STALL IS A STATE, NOT AN ABSENCE. A crashed round leaves its scratch dir
#     behind forever, so "the file exists" cannot mean "a round is running".
#     Freshness comes from the file's MTIME, and a round that stops touching it
#     is reported as stalled rather than quietly shown as healthy. This is the
#     whole reason the fragment exists: a stalled panel and a working one were
#     previously indistinguishable from outside.
set -uo pipefail

SCRATCH_ROOT="${QA_CYCLE_SCRATCH_ROOT:-/tmp}"
STALL_AFTER="${QA_STATUS_STALL_SECONDS:-180}"   # seconds with no write => stalled
FORGET_AFTER="${QA_STATUS_FORGET_SECONDS:-14400}"  # 4h: an abandoned dir goes quiet

newest=""; newest_mtime=0
for f in "$SCRATCH_ROOT"/qa-cycle-*/status; do
  [ -f "$f" ] || continue
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null) || continue
  [ "$m" -gt "$newest_mtime" ] && { newest_mtime=$m; newest="$f"; }
done
[ -n "$newest" ] || exit 0

IFS='|' read -r mr target round phase done total start < "$newest" || exit 0
[ -n "${mr:-}" ] || exit 0

now=$(date +%s)
age=$(( now - newest_mtime ))
# A finished round stops updating, so without this every completed round would
# read as "stalled" until its scratch dir was cleaned up.
[ "${phase:-}" = "done" ] && exit 0
[ "$age" -gt "$FORGET_AFTER" ] && exit 0

elapsed=$(( now - ${start:-$now} ))
[ "$elapsed" -lt 0 ] && elapsed=0
if   [ "$elapsed" -lt 60 ];   then el="${elapsed}s"
elif [ "$elapsed" -lt 3600 ]; then el="$(( elapsed / 60 ))m"
else el="$(( elapsed / 3600 ))h$(( (elapsed % 3600) / 60 ))m"; fi

frag="QA !${mr} ${target} r${round}"
case "${phase:-}" in
  lenses) frag="$frag ◆${done:-0}/${total:-?}" ;;
  ""|preflight) : ;;
  *) frag="$frag ${phase}" ;;
esac

if [ "$age" -gt "$STALL_AFTER" ]; then
  printf '%s ⚠stalled %dm\n' "$frag" "$(( age / 60 ))"
else
  printf '%s %s\n' "$frag" "$el"
fi
