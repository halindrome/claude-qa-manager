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
| `unapprove_before_post` | just do it — revoke, then post | Pure ordering. The findings must not land on a still-approved MR. |
| `post_after_fixes` | just do it | Also pure ordering. With `fixes` defaulted to report-only there are no trailers to append, so the note posts unchanged. |
| `approval` | **NOT defaultable** | Skipped unless `--auto-approve` was *also* passed. |

That set is what lets a clean, non-approval round run fully hands-free: the manager does
everything and `decisions_needed` resolves to a no-op.

## Not a `decisions_needed` entry: the round-continuation prompt

Step 3D's *"Ready to run QA round N+1?"* is asked by the main loop, not returned by the
manager, so it is in neither table above and was for that reason the one prompt that
stalled an otherwise hands-free run. It **is** defaultable — continuing after findings
were found and fixed is what the policy already prescribes — under the four conditions
the spine lists at Step 3D: the round is not clean, fixes were actually applied,
`round < 4`, and no `diminishing_returns`. The first failure stops the cycle and goes to
Step 4.

The `round < 4` bound is why this is mechanical rather than invented: the *After 4 rounds*
rule asks the human what to do, and this flag may never answer that. It stops instead.

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
