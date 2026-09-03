# The round note — body template and the posting recipe

**The shape of the round note, for both paths.** The manager renders it on the default
path (`agents/qa-manager.md`); main renders it on the sequential path and whenever it
resolves `post_after_fixes`. This file is the single source of truth for the format — if
you are changing it, change it here, not in a copy.

## Body template

Construct via a temp file to avoid shell quoting issues:

```bash
cat > "$QA_SCRATCH/note-round<N>.md" << 'EOF'
## QA Round <N>

<if qa_introduced_blocking >= 2, this line goes here — immediately under the
heading, before anything else, where a human cannot miss it:>
> ⚠ **<K> of <M> blocking findings are on code an earlier round of this QA cycle
> introduced.** This cycle may be fixing its own work rather than the MR's.

<K is qa_introduced_blocking and M is counts.critical + counts.major. Both are
BLOCKING-ONLY: the sentence says "blocking", so K can never exceed M. If the
numbers would read "4 of 0", the counter is wrong and the note must not be
written from it — see agents/qa-manager.md, "Counting them". A round whose
self-inflicted findings are all MINOR does not get this line; those are reported
via qa_introduced_total and routed by SKILL.md Step 3B.>

<merged-or-claude-only report body>

<from round 2 on, one line naming the fix-diff review (SKILL.md Step 3B.5):>
Fix review: <clean | findings, N addressed and amended into this round's commit
             | skipped:round-1 | skipped:no-fix-commit | skipped:spawn-refused>

<A skipped fix review is NEVER written as a clean one. `skipped:spawn-refused`
means this round's fix went in unreviewed, and the note says so — invariant 2.>

<for each reviewer that was attempted but failed (`do:deepseek-v4-pro`,
`do:openai-gpt-5.3-codex`, or `qwen`): one line, inside the report body —
⚠ <tag> second-opinion review failed: <reason>. Proceeding without it.
When TRIPLE=true and BOTH failed, the comment still posts: the Claude-only
report plus two ⚠ lines. A failed reviewer is never a zero-finding reviewer.>

<if Step 2.5 produced a $SAST_REPORT (regardless of whether it contained
findings), append a horizontal rule and then the verbatim contents of
$SAST_REPORT here so the MR comment carries both the human/agent QA report
AND the raw security delta. Keep the helper's "## NEW SAST findings" /
"## SAST review skipped" heading intact — the heading distinguishes this
section from the QA report above, and it is what tells a later reader
whether a scan ran at all.>

<if Step 2.5 was skipped because the helper itself failed and the user
opted to continue, omit the SAST block entirely (do NOT post a stale or
empty section).>

<name the pipeline and its SHA alongside any security claim. preflight ran
BEFORE this round's fix commit existed, so an unqualified "no new security
findings" can describe a commit that is no longer the head. A round once
asserted security-clean citing a pipeline two commits behind the one it
approved.>

<for EVERY commit Step 3B made this round, one trailer line each, full SHA. These
are the cycle's durable record of what IT changed, and the next round reads them
back to tell an MR defect from one a previous round of this cycle introduced. A
subject-pattern match cannot replace them: rebases, squashes and hand-edited
messages all break that, and this note survives them.

ONE LINE PER COMMIT, not one per round. A round is *supposed* to land a single
commit, but a follow-up fix is a normal thing to produce, and it happened on a real
round — the note recorded only the first, so the second's lines were invisible to
the next round's attribution and would have been reported as MR defects. Count the
commits you actually made; do not assume there was one.>
QA-Fix-Commit: <full SHA>
QA-Fix-Commit: <full SHA of any further fix commit this round>

---
<if QA_TOKEN_OK=true:>
*QA performed by <qa_auth_user from preflight.json when qa_token_ok, else the dev identity that posted> via Claude Code (<the model you are actually running as — not a literal copied from this file; a hardcoded id rots and misattributes the review. If you cannot determine it, write "Claude Code" with no parenthetical>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` where tag is the reviewer's tag, e.g. ` + do:deepseek-v4-pro` or ` + do:openai-gpt-5.3-codex` or ` + qwen3-14b (LM Studio)`>
<else (QA_TOKEN_OK=false): omit the "<username> via " prefix:>
*QA performed by Claude Code (<the model you are actually running as — see the note above>)*<for each second-opinion reviewer that succeeded: append ` + <tag>` as above>

<if QA_TOKEN_OK=false, also include this warning line inside the comment body (above the footer):>
> ⚠ Posted with dev credentials — QA agent token unavailable.
EOF
```

## Resolving the QA token, then posting

`$QA_TOKEN` **is not assigned anywhere else in the main loop.** Assign it here from the
values preflight resolved — never reconstruct the env-var name or the path from memory or
from a predecessor skill. A wrong guess resolves EMPTY, and empty means "act as the
developer".

```bash
QA_TOKEN_ENV=$(jq  -r '.qa_token_env'  "$QA_SCRATCH/preflight.json")
QA_TOKEN_FILE=$(jq -r '.qa_token_file' "$QA_SCRATCH/preflight.json")
QA_TOKEN="${!QA_TOKEN_ENV:-}"
[ -n "$QA_TOKEN" ] || QA_TOKEN=$(tr -d '[:space:]' < "${QA_TOKEN_FILE/#\~/$HOME}" 2>/dev/null)
[ -n "$QA_TOKEN" ] || echo "WARNING: QA token empty -> posting as the developer"
```

Env var FIRST, then file — a file-only lookup yields empty when the token comes purely
from the environment. (Pre-2026-08-03 builds have those keys in the manager brief only:
`grep '^qa_token_env=' "$MANAGER_BRIEF" | cut -d= -f2-`.)

**Verify before the write, because every failure here is silent.** `forge_post_note`
returning 0 does NOT mean the QA agent posted, and the `QA_TOKEN_OK` guard does not
protect you — it reports that PREFLIGHT resolved a token, not that YOU hold one. Both were
true while the main loop held an empty string and three notes posted as the developer
under a footer claiming the QA agent (`docs/CASE-STUDIES.md` §self-approval-fallback). The
created note's author is the ground truth; the footer you write is not evidence.

```bash
cd <target-path>
# All forge writes go through the seam — it dispatches to glab or gh from
# preflight.json's `forge`. Never call glab/gh directly here: a hardcoded `glab`
# posts nothing on a GitHub PR, and the round note is what the NEXT round's
# number is derived from, so a silently unposted note resets the cycle to 1.
. "${CLAUDE_PLUGIN_ROOT}/lib/forge.sh"
forge_init "$(git remote get-url "$REMOTE")" "${CLAUDE_PLUGIN_ROOT}/lib"

# Pass the QA token when it verified, an empty token to fall back to the dev
# identity. The warning line above already explains the fallback in the comment.
if forge_post_note "$PROJECT" <MR_NUMBER> "$QA_SCRATCH/note-round<N>.md" \
     "$([ "$QA_TOKEN_OK" = "true" ] && printf '%s' "$QA_TOKEN")"; then
  echo "round note posted"
else
  # A failed post is NOT a posted note. Say so and stop rather than continuing
  # to Step 3D, which would offer round N+1 that preflight cannot derive.
  echo "ERROR: round note was NOT posted; do not proceed to the next round" >&2
fi
```
