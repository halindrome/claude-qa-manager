#!/usr/bin/env bash
# statusline-fragment.sh — one short fragment describing a QA round in flight.
#
# Usage:  statusline-fragment.sh [cwd]      # prints a fragment, or NOTHING
#         cwd defaults to $PWD. Pass the SESSION's directory when calling from a
#         statusline, because a statusline renderer's $PWD is not reliably the
#         directory the session is working in.
#
# Compose it into an existing statusline; do NOT install it as your whole
# statusLine. Example, inside your own statusline script:
#
#   qa=$(bash "$PLUGIN/lib/statusline-fragment.sh")
#   [ -n "$qa" ] && printf ' | %s' "$qa"
#
# Output shapes:
#   QA !706 rest-api r1            — a round is in flight in this project
#   QA !706 rest-api r1 ⚠stalled   — it has stopped writing; go look
#   (nothing)                      — no round in flight
#
# DELIBERATELY NO ELAPSED TIME AND NO LENS COUNT. A statusline repaints on
# main-thread activity, and for the whole duration of a round the main thread is
# blocked waiting on a backgrounded manager — so the one period you would want a
# progress readout is exactly the period this surface cannot refresh. Observed:
# the fragment returned `rendering 14m` when invoked directly while the on-screen
# line still showed a value from 11 minutes earlier. A number that looks live and
# is not is worse than no number: it invites you to conclude the round is stuck
# from a reading taken before it started working.
#
# So this reports IDENTITY, which does not go stale — which MR, which target,
# which round — plus a stall marker, without a duration for the same reason. For
# live progress use lib/watch-round.sh, which polls on its own clock.
#
# DESIGN CONSTRAINTS, all learned the hard way:
#   - SILENT WHEN IDLE. This runs on every statusline repaint in every session
#     in every repo. A fragment that prints something when no round is running
#     is a permanent tax for an occasional event.
#   - CHEAP. One glob and one small read. No git, no jq, no network, no walking
#     preflight.json -- which is why preflight/the manager write a single
#     pre-formatted line instead of leaving the rendering to this script.
#   - SCOPED TO THIS PROJECT. The scratch root is shared by every repo on the
#     machine, so "the most recently written round" is the wrong selector: two
#     concurrent cycles then each render the other's progress, alternating as
#     they write. Candidates are filtered by the target_abs recorded in the
#     status line, and only then does newest win.
#   - STALL IS A STATE, NOT AN ABSENCE. A crashed round leaves its scratch dir
#     behind forever, so "the file exists" cannot mean "a round is running".
#     Freshness comes from the file's MTIME, and a round that stops touching it
#     is reported as stalled rather than quietly shown as healthy. This is the
#     whole reason the fragment exists: a stalled panel and a working one were
#     previously indistinguishable from outside.
set -uo pipefail

SCRATCH_ROOT="${QA_CYCLE_SCRATCH_ROOT:-/tmp}"
# Stall thresholds are PHASE-AWARE, and that is not a nicety. The status file is
# rewritten when a lens RETURNS, and a lens legitimately runs for 5-15 minutes, so
# a single short threshold reports a perfectly healthy fan-out as stalled. Measured
# on a real round: six lenses, first return well past three minutes. A warning that
# fires during normal operation is worse than none -- it trains you to ignore it.
# The fan-out tolerance is a property of the PROJECT, not of this tool: a lens on a
# large monorepo diff ran 8-20 minutes, while a small service may finish in seconds
# and there a 20-minute fuse hides a wedge for 20 minutes. preflight resolves it
# from config and puts it in field 9 of the status line, because this script cannot
# merge config layers on every repaint. Precedence: env > the round's own value >
# built-in default.
STALL_AFTER="${QA_STATUS_STALL_SECONDS:-180}"   # merge/render/post: bounded work
LENS_STALL_DEFAULT=1200
FORGET_AFTER="${QA_STATUS_FORGET_SECONDS:-14400}"  # 4h: an abandoned dir goes quiet

CWD="${1:-$PWD}"
CWD="${CWD%/}"

# Does a round whose target is $1 belong to the session sitting in $CWD? True when
# they are the same directory, when the target is BELOW the session (a monorepo
# session reviewing a submodule), or when the session is below the target (a
# session opened inside the submodule being reviewed).
belongs_here() {
  local ta="${1%/}"
  [ -n "$ta" ] || return 1
  [ "$ta" = "$CWD" ] && return 0
  case "$ta" in "$CWD"/*) return 0 ;; esac
  case "$CWD" in "$ta"/*) return 0 ;; esac
  return 1
}

newest=""; newest_mtime=0
for f in "$SCRATCH_ROOT"/qa-cycle-*/status; do
  [ -f "$f" ] || continue
  # NINE fields, not eight. With IFS='|' the LAST variable absorbs every remaining
  # field, so reading 8 from a 9-field line silently makes _ta "<target_abs>|<stall>"
  # — which never equals any directory, so belongs_here rejected EVERY round and the
  # fragment rendered nothing at all, for every project, from the moment
  # lens_stall_seconds became the 9th field. Observed live. The producers are locked
  # at 9 by preflight.test.sh; this consumer was not, which is why only the writers
  # were kept honest.
  IFS='|' read -r _mr _tg _rd _ph _dn _tt _st _ta _ls < "$f" || continue
  [ -n "${_mr:-}" ] || continue
  # A line written before target_abs was carried in-band: recover it from the
  # round's own preflight.json rather than dropping the round off the display.
  # Only legacy lines pay this, so the common path stays jq-free.
  if [ -z "${_ta:-}" ]; then
    _ta=$(jq -r '.target_abs // empty' "$(dirname "$f")/preflight.json" 2>/dev/null)
  fi
  belongs_here "${_ta:-}" || continue
  m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null) || continue
  [ "$m" -gt "$newest_mtime" ] && { newest_mtime=$m; newest="$f"; }
done
[ -n "$newest" ] || exit 0

IFS='|' read -r mr target round phase done total start target_abs lens_stall < "$newest" || exit 0
[ -n "${mr:-}" ] || exit 0

case "${lens_stall:-}" in ''|*[!0-9]*) lens_stall="$LENS_STALL_DEFAULT" ;; esac
LENS_STALL_AFTER="${QA_STATUS_LENS_STALL_SECONDS:-$lens_stall}"

now=$(date +%s)
age=$(( now - newest_mtime ))
# A finished round stops updating, so without this every completed round would
# read as "stalled" until its scratch dir was cleaned up.
[ "${phase:-}" = "done" ] && exit 0
[ "$age" -gt "$FORGET_AFTER" ] && exit 0

frag="QA !${mr} ${target} r${round}"

stall_limit="$STALL_AFTER"
[ "${phase:-}" = "lenses" ] && stall_limit="$LENS_STALL_AFTER"
if [ "$age" -gt "$stall_limit" ]; then
  printf '%s ⚠stalled\n' "$frag"
else
  printf '%s\n' "$frag"
fi
