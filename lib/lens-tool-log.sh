#!/usr/bin/env bash
# lens-tool-log.sh — tool-call telemetry for one lens: a PreToolUse / PostToolUse /
# PostToolUseFailure hook that appends one JSON line per event to $QA_LENS_LOG.
#
# Registered ONLY by lib/run-panel.sh, per lens, through `claude -p --settings
# panel-hooks.json`, so it fires inside lenses and in no other session. Lenses run
# with --no-session-persistence and leave no transcript; without this log, whether a
# lens used the tools its mandate names is unanswerable.
#
# Reading the log (lib/lens-tools-summary.sh does this):
#   Pre + PostToolUse          the call ran and succeeded
#   Pre + PostToolUseFailure   the call ran and failed (`err` holds the reason)
#   Pre alone                  the call never ran: a hook or permission blocked it, or
#                              the lens was killed mid-call
# `ms` is Claude Code's own measurement of the call, present on the Post events only.
#
# Never fails a lens: every path exits 0, and nothing is written to stdout, which a
# PreToolUse hook's caller may parse as a decision.
[ -n "${QA_LENS_LOG:-}" ] || exit 0
# Before any redirection: a failed `>>` (log dir gone) is reported by the shell on
# ITS stderr, which a trailing 2>/dev/null on the command does not cover.
exec 2>/dev/null

jq -c '{
  ts:   now,
  ev:   .hook_event_name,
  tool: .tool_name,
  id:   .tool_use_id,
  ms:   .duration_ms,
  err:  (if .error then (.error | tostring | .[0:200]) else null end),
  in:   ((.tool_input // {})
         | (.file_path // .command // .query // .pattern // .name_pattern
            // .qualified_name // .code // .)
         | tostring | .[0:160])
}' >> "$QA_LENS_LOG"

exit 0
