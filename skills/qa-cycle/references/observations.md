# Observations — the carry-forward ledger

**Read when a round produced observations, or when Step 4's Carried-forward section
needs more than the spine says.** The spine states the rule at Steps 3C.5 and 4; this is
the reasoning and the edges.

## The ledger has two inflows; only one of them is observations

Since the Step 3B minor-routing rule, `$QA_SCRATCH/observations.md` carries two kinds
of line, and they must stay distinguishable:

1. **`relevance: observation` findings** — the subject of everything below.
2. **Minor findings Step 3B declined to fix** because they were `qa_introduced` **and**
   `in_test_file`: defects in test scaffolding an earlier round of this cycle wrote.
   These carry the suffix `(QA-authored test scaffolding, not fixed)`.

The second kind is **not** an observation and must never be relabelled as one. Relevance
is a factual classification of what a finding is *about*, not a routing dial — the same
rule that forbids downgrading a regression to `observation` to unblock an MR forbids
promoting these. They share the file because the ledger is the carry-forward *mechanism*
and Step 4 reports from it, not because they are the same kind of thing.

Why they are carried at all rather than dropped: they are real defects, and a cycle that
silently discarded them would be hiding the cost of its own remediation. Why they are not
fixed: fixing one costs a commit, a post and another full panel whose subject is that
fix — 60 of 200 measured self-inflicted findings were exactly this, and the round they
buy is the fix-noise round. See `references/fix-review.md`.

## What an observation is, and what it is not

`relevance: observation` is one of three values on the relevance axis (`agents/qa-reviewer.md`,
Finding Taxonomy): a substantiated bug the lens **verified** in code outside this MR's
scope — unmodified files, or pre-existing logic adjacent to touched code. It does not
block the MR, and it is reported at its true severity: a `critical` observation is a real
critical bug that this MR simply did not cause.

Three things it is explicitly not:

- **Not a severity.** A `minor` regression still blocks; a `critical` observation still
  does not. The No Dismissals rule forbids demoting a substantiated regression to
  `observation` to unblock an MR — relevance is a factual classification, not a dial.
- **Not `hypothetical`.** That is the *status* axis, and it is orthogonal. An observation
  is confirmed by construction; if it is not confirmed, it is not an observation, it is a
  guess about code the MR did not touch.
- **Not a fix list.** Nothing in the ledger is fixed by this cycle. Fixing an observation
  means editing code the MR does not own, inside a review round, unreviewed — which is
  how a small change becomes an unreviewable one.

## Why `hypothetical` findings are NOT accumulated

The obvious symmetry — "if we carry observations forward, carry the unlikely ones too" —
is wrong, and the reason is in the reviewer contract already.

For any finite test suite, infinitely many mutation gaps and unreached conditions exist.
The class never exhausts. `qa-reviewer` is therefore told not to report findings requiring
conditions the changed code does not create, and to cap mutation gaps at `minor`. That cap
is what makes a clean round reachable at all: without it, every round can always produce
one more plausible-but-unproven finding, and the cycle cannot converge.

A durable ledger is a promotion, not a demotion. Accumulating hypotheticals across rounds
would grow the exact class the cap exists to bound, hand the human a list that is longer
every round and actionable in none of it, and re-import the noise as a permanent artifact.
If a hypothetical matters enough to survive the cycle, the lens should have confirmed it —
and a confirmed one is either a regression (blocking) or an observation (already carried).

## The ledger file

`$QA_SCRATCH/observations.md`, appended at Step 3C.5, one line per observation:

```
- [R<round>] **<severity>** <title> — <area_file>:<line_low>
```

- **Dedupe on the tag-stripped title** — the same key the Step 3A.3 merge already uses, so
  a `[claude|do:deepseek-v4-pro]` prefix does not make one finding look like two. A
  pre-existing bug is re-found by every round that runs while it survives; without the
  dedupe a five-round cycle reports the same bug five times and the reader stops reading.
- **Keep the round tag of the round that FIRST saw it.** It dates the finding. Re-finding
  it in round 4 is not news; first seeing it in round 4 means the earlier panels missed it,
  which is worth noticing.
- **The file is scratch, not the record of last resort.** It dies with `$QA_SCRATCH`. The
  durable copy is the round note already posted on the MR — the ledger exists to
  *aggregate* what those notes scattered, not to be the only place the data lives. If the
  ledger is lost mid-cycle, the notes still have every observation; rebuild from them
  rather than reporting none.

## Why aggregate at all

Each observation is recorded exactly once, in the round note that found it. A five-round
cycle therefore leaves them across five MR comments in chronological order of discovery,
interleaved with blocking findings, SAST sections and fix trailers. The round-1
observation is buried deepest and is the one that has been open longest.

Nothing was lost, and that is precisely the failure: the data is present and unreadable.
The cycle's last screen — Step 4 — is where a human decides what to do next, and until
this ledger existed it was the one screen that never mentioned the findings the cycle
chose not to act on.

## Step 4 — printing it

Print the `### Carried forward — found, not fixed by this cycle` heading **always**, with
the ledger verbatim beneath it, or the single line `none reported` when it is empty.

Never omit the heading. The two `layout`-gated lines in the same block *are* omitted when
the structure does not exist, so the contrast is deliberate and worth stating: omitting
those describes a repo shape the reader does not have, while omitting this one asserts
that nothing was found. "Nothing found" and "nothing ran" render identically as an absent
section, and an absent check must never report as a pass.

## Optional: an end-of-cycle comment

Posting the ledger to the MR as one final comment is a reasonable extension and is not
implemented. If it is added:

- It is a **separate** comment, never appended to a round note. Round derivation parses
  the posted notes to compute the next round number; adding a body to one, or posting a
  sixth note-shaped comment after round 5, is how a cycle re-runs round 5 forever.
- It must not be posted on an approval round without saying so. An approval rests on a
  clean round or an enumerated deferral; a comment listing findings, posted alongside,
  must be unmistakably labelled non-blocking or it reads as a revocation.
- The taxonomy already says observations exist "so the orchestrator (and ultimately the
  user) can decide whether to file a ticket" — that decision currently has nowhere to be
  made, which is the actual argument for the comment.
