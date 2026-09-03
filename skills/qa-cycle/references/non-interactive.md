# `--non-interactive` — what may be auto-answered, and what may never be

**Read only when `--non-interactive` was passed.** The spine states the rule and the two
prompts that are never defaulted; this is the per-decision policy.

The principle: `--non-interactive` pre-answers decisions whose default is *mechanical* —
where a human adds no information. It may never **invent** a human's answer. Every entry
below is one or the other, and which one it is has a reason.

## Defaultable

| `decisions_needed` entry | Auto-answer | Why this is mechanical |
|---|---|---|
| `sast_wait` | defer the round → `skipped:pipeline-running` | Waiting is the only alternative, and the state records honestly that no security delta was certified. |
| `fixes` | report-only, leave for the author | The conservative branch of a gate that already exists for someone else's MR. |
| `contract_disambiguation` | take the highest-confidence candidate, or **BLOCK** if none | Blocking on no candidate is the point: a synthesized contract nobody confirmed is how a round grades against criteria the ticket never stated. |
| `diminishing_returns` | surface it and **stop the cycle** — but defer NOTHING and do not approve | Stopping is mechanical; deferring is a human decision (see the Step 3E deferred-findings exit). The two must not be collapsed. |
| `fix_review` findings (Step 3B.5) | fix and amend into the round's commit, as interactively | Not a `decisions_needed` entry — it is part of applying the fix, and the round's single commit is not final until it has run. |
| `unapprove_before_post` | just do it — revoke, then post | Pure ordering. The findings must not land on a still-approved MR. |
| `post_after_fixes` | just do it | Also pure ordering. With `fixes` defaulted to report-only there are no trailers to append, so the note posts unchanged. |
| `approval` | **NOT defaultable** | Skipped unless `--auto-approve` was *also* passed. |

That set is what lets a clean, non-approval round run fully hands-free: the manager does
everything and `decisions_needed` resolves to a no-op.

## Not a `decisions_needed` entry: the round-continuation prompt

Step 3D's *"Ready to run QA round N+1?"* is asked by the main loop, not returned by the
manager, so it is in neither table above and was for that reason the one prompt that
stalled an otherwise hands-free run. It **is** defaultable — continuing after findings
were found and fixed is what the policy already prescribes, so a human confirming it adds
no information. Auto-answered yes while **all four** hold; the first failure stops the
cycle and goes to Step 4:

| Condition | Why it bounds the default |
|---|---|
| the round is not clean | a clean round ends the cycle on its own, by Step 3D's first bullet |
| fixes were actually applied | report-only mode pauses instead. Re-reviewing an unchanged diff yields the same findings forever — that is a loop, not a cycle. |
| `round < 4` | the *After 4 rounds* rule asks the human what to do, and this flag may never answer that. It stops instead. |
| no `diminishing_returns` | already `stop` in the table above; continuing would contradict it. Note this now fires on a **computed** trigger — `qa_introduced_blocking >= max(2, ceil(blocking_total / 2))` — so under `--non-interactive` a cycle that has started reviewing its own fixes stops on arithmetic rather than on nobody being there to notice. That is the intended tightening: 36 of the measured rounds were a full panel spent on the previous round's own commit. |
| only minors were fixed | Step 3D's minor-only bullet **asks**, and this flag may not answer it. A minor-only round is the fix-noise shape; stop and report rather than buying another panel for it. |

Everything Step 3D requires *after* the prompt is unchanged and still mandatory — post
this round's note first (it is what makes the next derivation return N+1), then re-run
`preflight.sh` for the new `round` and a freshly rendered `proportionality.md`.

**The consequence worth stating: a `--non-interactive` run has exactly two terminal
states** — approved, or stopped with the Step 4 debrief. It never strands mid-cycle
waiting for an answer nobody is there to give, and it never approves its way past a gate:
`--auto-approve` is still required for the approval itself, and the two entries below are
still never defaulted.

## Never auto-answered

Two prompts stay unanswered no matter what, because a default here would fabricate consent:

- **The schema-change rollout ACK** (Step 3E). `SCHEMA_CHANGE_ACK` stays `false`, and the
  run does *not* strand waiting on it: record approval status `blocked: schema change
  rollout not acknowledged`, finish the round — the note still posts — and stop before
  approval. Re-run interactively to acknowledge. Treating silence as an ACK is exactly the
  schema-drift failure mode; see `docs/CASE-STUDIES.md` §schema-drift.
- **The exit-3 unexpected-deletions gate**, which asks whether a destructive-looking sync
  is intended. Do not proceed on a guess — stop the round and report `sync.reason`.

Neither flag can bypass the schema-change human-approval gate, and `--auto-approve` skips
only the Step 3E *confirm*, never a gate.
