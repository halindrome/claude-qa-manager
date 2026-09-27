#!/usr/bin/env bash
# run-verify.sh — run a target's OWN test/build entry point, BOUNDED.
#
# Usage:  run-verify.sh <target-abs-dir> <command> --log <path> [--timeout-seconds N]
# Output: one JSON object on stdout:
#   {"state":"passed|failed|timeout|not-run","exit":<n>,"seconds":<n>,
#    "command":"…","log":"<path>"}
#
# Why this exists at all. `detect-verify.sh` proves a test entry point EXISTS —
# it greps manifests and never executes anything. Nothing between detection and
# execution establishes that the command is AUTONOMOUS, and until this helper
# there was nothing bounding it either: SKILL.md handed the raw command string
# to the orchestrating model to run by hand. A `scripts.test` that resolves to a
# watcher, or any suite that reads stdin, then blocks the round forever with
# nothing to kill it. An instruction to "use a timeout" is not a mechanism and
# cannot be tested; this can.
#
# This WRAPS the command, it does not rewrite it. `config/defaults.json`'s
# `verify` comment is explicit that the recipe is the project's business and
# lifting commands out of it is how you keep the appearance of a test run while
# discarding what the target guaranteed. So: stdin closed, CI exported, a bound
# on the wall clock — and not one flag appended to what the project declared.
#
# `state:timeout` is NOT a pass. A killed run produced no execution evidence,
# exactly like `none-found`, and the round note must say so.
set -uo pipefail

die_usage() { cat >&2 <<'U'
usage: run-verify.sh <target-abs-dir> [command] --log <path>
         [--from-preflight <preflight.json>]  supply command/timeout/timings/baseline
         [--timeout-seconds N] [--timings <file>] [--canonical-command <cmd>]
         [--baseline '<json>']                 explicit flags win over --from-preflight
U
exit 2; }

DIR="${1:-}"; shift || true
CMD=""
# An EMPTY command is a real value — `verify.state=none-found` gives one, and it
# must reach the `not-run` path. So test arity, not emptiness: `${1:-}` cannot
# tell "no argument" from "the empty string", and conflating them leaves the
# empty string in $@ to be rejected as an unknown flag.
if [ $# -gt 0 ]; then
  case "$1" in --*) ;; *) CMD="$1"; shift ;; esac
fi
LOG=""
LIMIT=""
TIMINGS=""
CANONICAL=""
EXPECT=""
BASE_JSON=""
PF=""
FIRED=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log)                LOG="${2:-}"; shift 2 || die_usage ;;
    --timeout-seconds)    LIMIT="${2:-}"; shift 2 || die_usage ;;
    --timings)            TIMINGS="${2:-}"; shift 2 || die_usage ;;
    --canonical-command)  CANONICAL="${2:-}"; shift 2 || die_usage ;;
    --expect)             EXPECT="${2:-}"; shift 2 || die_usage ;;
    --baseline)           BASE_JSON="${2:-}"; shift 2 || die_usage ;;
    --from-preflight)     PF="${2:-}"; shift 2 || die_usage ;;
    *) die_usage ;;
  esac
done

# Read whatever was not passed explicitly out of preflight.json. This is the
# form the orchestrator uses, and it exists to keep the COMMAND out of the
# caller's shell: a real `verify.command` contains spaces and quotes, and having
# the model re-quote it into a bash line is an error class with no upside when
# the value is already sitting in a JSON file. Explicit flags still win, so the
# suite can drive one behaviour at a time.
if [ -n "$PF" ]; then
  [ -f "$PF" ] || { echo "run-verify.sh: no such preflight file: $PF" >&2; exit 2; }
  pfget() { jq -r "$1 // \"\"" "$PF" 2>/dev/null; }
  [ -n "$CMD" ]       || CMD=$(pfget '.verify.command')
  [ -n "$LIMIT" ]     || LIMIT=$(pfget '.verify.timeout_seconds')
  [ -n "$TIMINGS" ]   || TIMINGS=$(pfget '.verify.timings_path')
  [ -n "$EXPECT" ]    || EXPECT=$(pfget '.verify.expect')
  [ -n "$BASE_JSON" ] || BASE_JSON=$(jq -c '.verify.baseline // {}' "$PF" 2>/dev/null)
  # The canonical run IS the declared command. Anything else the round chooses to
  # run through this helper — a red-first check on one test file, say — is not the
  # gate and must not be measured as if it were.
  [ -n "$CANONICAL" ] || CANONICAL=$(pfget '.verify.command')
fi

[ -n "$DIR" ] && [ -n "$LOG" ] || die_usage
[ -d "$DIR" ] || { echo "run-verify.sh: not a directory: $DIR" >&2; exit 2; }

# A missing or junk value must not become "unbounded". This helper is also
# callable directly, without preflight having resolved anything, so it cannot
# assume a sane value was passed.
case "$LIMIT" in
  ''|*[!0-9]*|0) LIMIT=900 ;;
esac

# Kill a process group and CONFIRM it is gone, rather than firing one signal and
# assuming. BOTH kills are required and neither is a fallback for the other:
#
#   - the GROUP kill reaches grandchildren (`make` -> `npm` -> a watcher);
#   - the PID kill covers the window before perl's setpgrp has made the group,
#     which a command finishing instantly (`exit 0`) can beat. Signal only the
#     group and that run leaks its watchdog — orphaned, adopted by init, and
#     still holding this script's stdout, so the NEXT caller reading our JSON
#     from a pipe blocks for the rest of the limit on a command that finished.
#
# Do not add a retry loop around them; two kills is the whole job.
reap_group() { # pgid (== the perl child's pid)
  kill -9 -- "-$1" 2>/dev/null
  kill -9    "$1"  2>/dev/null
  return 0
}

emit() { # state exit seconds
  jq -n --arg st "$1" --argjson ex "$2" --argjson se "$3" \
        --arg c "$CMD" --arg l "$LOG" \
        --argjson lim "$LIMIT" --arg lsrc "$LIMIT_SOURCE" \
        --argjson base "${BASELINE:-null}" --arg rsn "${REASON:-}" \
    '{state:$st, exit:$ex, seconds:$se, command:$c, log:$l,
      limit_used:$lim, limit_source:$lsrc, baseline_seconds:$base}
     + (if $rsn == "" then {} else {reason:$rsn} end)'
}

# --- the learned bound ------------------------------------------------------
# A fixed 900s ceiling is safe but blunt: a 20-second suite that wedges burns
# the full quarter hour before anyone looks at it. So derive the bound from what
# THIS target's suite actually costs, and keep the configured value as a ceiling
# the baseline can lower but never raise.
#
# Only TERMINATED runs are recorded. Recording a timeout would ratchet the
# baseline upward using the very number that means "this did not finish", until
# the bound is meaningless — a gate that widens itself every time it fires.
#
# Below `min_samples` there is no baseline, and the JSON says `configured`
# rather than inventing one: an absent measurement must not read as a
# measurement (the same rule as a skipped gate never reporting clean).
#
# Every constant in the derivation is CONFIG, not a literal. They were first
# chosen against one project's suite, and a generic driver must not carry one
# project's calibration as though it were a law. `min_samples: 0` disables the
# learned bound entirely and leaves the flat ceiling.
BASELINE=null
LIMIT_SOURCE=configured
REASON=""

bget() { # key default
  local v
  v=$(printf '%s' "${BASE_JSON:-{\}}" | jq -r ".$1 // empty" 2>/dev/null)
  case "$v" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$v" ;; esac
}
MIN_SAMPLES=$(bget min_samples 3)
WINDOW=$(bget window 10)
MULTIPLIER=$(bget multiplier 5)
FLOOR=$(bget floor_seconds 60)

if [ "$MIN_SAMPLES" -gt 0 ] && [ -n "$TIMINGS" ] && [ -f "$TIMINGS" ]; then
  # newline-delimited integers, oldest first; keep the analysis in one awk pass
  BASELINE=$(awk -v need="$MIN_SAMPLES" -v win="$WINDOW" '
    NF && $1 ~ /^[0-9]+$/ {v[n++]=$1}
    END{ if (n < need) { print "null"; exit }
         s=(n>win)?n-win:0; m=0; for(i=s;i<n;i++) w[m++]=v[i]
         for(i=0;i<m;i++) for(j=i+1;j<m;j++) if(w[j]<w[i]){t=w[i];w[i]=w[j];w[j]=t}
         print (m%2) ? w[int(m/2)] : int((w[m/2-1]+w[m/2])/2) }' "$TIMINGS")
  case "$BASELINE" in ''|null|*[!0-9]*) BASELINE=null ;; esac
fi

if [ "$BASELINE" != "null" ]; then
  # multiplier x the median, floored so ordinary variance in a fast suite does
  # not trip the bound, and capped by the configured ceiling so a slow-drifting
  # baseline can never quietly buy itself more time than the operator allowed.
  derived=$(( BASELINE * MULTIPLIER ))
  [ "$derived" -lt "$FLOOR" ] && derived="$FLOOR"
  if [ "$derived" -lt "$LIMIT" ]; then LIMIT="$derived"; LIMIT_SOURCE=baseline; fi
fi

mkdir -p "$(dirname "$LOG")" 2>/dev/null || true
: > "$LOG" || { echo "run-verify.sh: cannot write log: $LOG" >&2; exit 2; }

# An empty command means nothing was detected and nothing was configured. Say
# `not-run` rather than dying on usage: the caller must get a state it can put
# in the round note, and a helper that errors out is a helper the orchestrator
# is tempted to skip past — which is how "no suite ran" turns into silence.
if [ -z "$CMD" ]; then
  emit not-run 0 0
  exit 0
fi

START=$(date +%s)

# Two deliberate choices here, both load-bearing:
#
# 1. REDIRECT to a file; never pipe. A pipe would leave an orphaned grandchild
#    holding the write end open, so the read blocks and the hang simply moves
#    one level down — the timeout state would never be emitted. Redirection also
#    keeps the exit status coming from the command under test (see
#    references/test-authoring.md), which a pipeline would hand to the last stage.
#
# 2. Own PROCESS GROUP, and signal the GROUP. run-panel.sh's watchdog TERMs a
#    single `claude` pid that cleans up after itself; a test suite is an
#    arbitrary tree — `make test` -> `npm test` -> a watcher — and a TERM to the
#    outer `make` is not guaranteed to reach the grandchild. macOS has no
#    setsid(1), so start a new group with perl's setpgrp.
#
# CI=1 is the near-universal "no TTY, no watch, no colour" convention, and stdin
# is closed so a suite that prompts gets EOF instead of waiting on a human.
CI=1 perl -e 'setpgrp; exec @ARGV or exit 127' \
   /bin/sh -c "cd \"\$0\" && $CMD" "$DIR" </dev/null >>"$LOG" 2>&1 &
cpid=$!

# The child IS the group leader (setpgrp ran before exec), so the group id is
# its pid. TERM the group, grace, then KILL the group.
#
# FIRED is a sentinel file, not an exit-code range. `rc >= 128` would call a
# segfaulting suite (139) a timeout — reporting "we ran out of time" for a
# genuine crash the round needs to see. Only the watchdog knows it fired.
# The watchdog gets its OWN group for the same reason the command does, and is
# killed the same way. `kill $wpid` alone would reap only the subshell: its
# `sleep` is a separate process, so it survives as an orphan STILL HOLDING THIS
# SCRIPT'S STDOUT — and any caller reading our JSON from a pipe then blocks for
# the remainder of $LIMIT on a command that already finished. That is the same
# orphan-holds-a-descriptor failure this file redirects the suite's output to
# avoid, and it is easy to reintroduce here: run-panel.sh:314 has it, and only
# gets away with it because nothing reads that pipe.
FIRED="$LOG.timedout"
# ONE process, no child of its own. Do NOT rewrite this as
# `sh -c 'sleep N; kill ...'`: there the `sleep` is a CHILD of the shell, so
# killing the watchdog orphans it, and the orphan keeps this script's
# descriptors open. Perl sleeps and signals in the same process, so killing the
# watchdog is unambiguous.
perl -e 'setpgrp;
         my ($lim,$fired,$pg) = @ARGV;
         sleep $lim;
         open(my $f, ">", $fired) and close $f;
         kill(-15, $pg) or kill(15, $pg);
         sleep 10;
         kill(-9, $pg)  or kill(9, $pg);' \
  "$LIMIT" "$FIRED" "$cpid" </dev/null >/dev/null 2>&1 &
wpid=$!
# Drop it from the job table before we kill it, or bash prints its own
# "line N: <pid> Killed: 9 …" notice on stderr for every single verify run —
# stderr the orchestrator would then have to explain away in the round note.
disown "$wpid" 2>/dev/null || true

wait "$cpid"; rc=$?
reap_group "$wpid"
# Reap the command's group too. This matters on the NORMAL exit path as well —
# a suite that backgrounds a dev server and returns 0 would otherwise keep the
# round's shell alive — and on the timeout path it is what actually finishes the
# job: we kill the watchdog as soon as `wait` returns, so its own escalation to
# KILL never runs and this is the only thing standing behind the TERM.
reap_group "$cpid"

ELAPSED=$(( $(date +%s) - START ))

record() { # append a TERMINATED run's duration, keep the last $WINDOW
  [ -n "$TIMINGS" ] || return 0
  # ONLY the declared verify command is measured. A round legitimately runs
  # other things through this helper — a red-first check on a single test file
  # is seconds where the suite is minutes — and pooling them lets the narrow run
  # set the bound for the suite, which is then killed and reported unverified.
  # It is a one-way ratchet too: timeouts are not recorded, so the suite never
  # contributes a counter-sample and the bound only drifts down. `verify.command`
  # is what the project declared its gate to be; nothing else is the gate.
  [ -z "$CANONICAL" ] || [ "$CMD" = "$CANONICAL" ] || return 0
  # Silence the GROUP, not each command. A redirection is processed before the
  # command's own `2>/dev/null` is in effect, so `>> "$TIMINGS" 2>/dev/null` on
  # an unwritable path still prints the failure — the suppression never covers
  # the one case it was written for. Recording is best-effort by design: an
  # unwritable timings path must cost the round nothing and say nothing.
  {
    mkdir -p "$(dirname "$TIMINGS")" || return 0
    printf '%s\n' "$1" >> "$TIMINGS"  || return 0
    tail -n "$WINDOW" "$TIMINGS" > "$TIMINGS.t" && mv "$TIMINGS.t" "$TIMINGS"
  } 2>/dev/null
}

if [ -f "$FIRED" ]; then
  rm -f "$FIRED"
  # Say WHICH bound was hit. "This suite normally takes 20s and has now run 100"
  # is a wedge to investigate; "it ran past the configured ceiling" is a slow
  # suite. The round should not have to guess which one it is looking at.
  if [ "$LIMIT_SOURCE" = "baseline" ]; then REASON=exceeded_baseline
  else REASON=exceeded_configured; fi
  emit timeout "$rc" "$ELAPSED"      # deliberately NOT recorded: see the note above
elif [ "$rc" -ne 0 ]; then
  record "$ELAPSED"
  emit failed "$rc" "$ELAPSED"
#
# EXIT 0 IS NOT A PASS. A test entry point that brings up services, runs a
# harness, and tears them down again reports the status of the LAST thing it did
# — the teardown — so a harness that aborted before running a single test still
# exits 0. Trusting that status is the failure this whole step exists to prevent.
#
# A pass must therefore be POSITIVELY confirmed by a marker the project declares
# (`verify.expect`). No marker configured means we cannot tell, and cannot tell
# is reported as `unconfirmed` — never as clean. Only a confirmed pass feeds the
# baseline; timing a run that never tested anything is how the bound learns
# nonsense.
#
# `$EXPECT` is the ONLY string this script ever matches, and it comes from the
# project's config. Do not add knowledge of any harness's output format here.
elif [ -z "$EXPECT" ]; then
  REASON=no_expect_configured
  emit unconfirmed 0 "$ELAPSED"
elif grep -qE "$EXPECT" "$LOG" 2>/dev/null; then
  record "$ELAPSED"
  emit passed 0 "$ELAPSED"
else
  REASON=expect_not_met
  emit unconfirmed 0 "$ELAPSED"
fi
