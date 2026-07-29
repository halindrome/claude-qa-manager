# Case studies

These are the incidents the guards exist for. They are anonymised field reports from
production use; every number is real.

**Why they are in the repo at all.** Several rules in this plugin look like overcaution
until you know what happened without them. A rule whose rationale lives only in someone's
memory gets deleted in eighteen months by a maintainer who cannot see what it was buying.
Each rule in `SKILL.md` therefore states its one-line *why* inline and cites the case here.

---

## §schema-drift — why a schema change is never auto-approved

Application code shipped reading a database column that was never added to the template
database the provisioner clones from. Every tenant created from that template on that
release broke on first use.

**Why no automated check caught it.** The code changed; the schema file did not. A
file-list check sees nothing wrong, because nothing is wrong *in the diff* — the defect is
the *absence* of a corresponding change. The failure lives in the gap between two files.

**What this plugin does about it.**

1. A `schema-propagation` review lens looks specifically for changed code that reads or
   writes a column or table absent from the configured schema file — and reports it even
   when no schema file changed. This is the only mechanism that can catch the above.
2. Any MR touching a configured schema file arms a **mandatory human approval gate**. The
   QA agent may add a second approval, but never the first, and no flag relaxes this.

**What was explicitly rejected.** An earlier version also grepped the diff *content* for
DDL keywords. It matched DDL in test fixtures, code comments, and even test labels, so
changes touching zero SQL were reported as schema changes and armed the human gate over a
`printf` string. Defending it required a self-trip guard, a regex extractor, and
behavioural probes; that machinery produced five QA findings of its own and protected
nothing. **A path check cannot match a comment.** Do not reintroduce content scanning.

---

## §review-degeneration — why proportionality and the stop rule exist

A 40-line credential fix was put through repeated QA rounds:

| Round | Findings | Targeting the MR's own change | Targeting QA-added code |
|---|---|---|---|
| 1 | 6 | 6 | 0 |
| 2 | 3 | 3 | 0 |
| 3 | 10 | 9 | 1 |
| 4 | 14 | 3 | **11** |

Round 2 added a variable that round 3 removed — net zero across two rounds, verified by
diffing the trees. Round 3's fix added a 229-line test file, and round 4 produced **11 of
its 14 findings about that test file**. The diff grew 9x. The shipped behaviour had been
correct since round 2. No individual finding was wrong; the aggregate was worthless.

**Two mechanisms drive this.**

1. **Every fix is fresh unreviewed surface** that becomes the next round's input, and
   reviewers weight recently-changed lines most heavily.
2. **Mutation-gap findings never exhaust.** "This test would still pass if X also changed"
   — for any finite suite, infinitely many such mutations exist, so a clean round is
   unreachable by construction.

**What this plugin does about it.** The reviewer objective is two-sided rather than
pure-recall. Severity anchors cap test/CI code at `major` and mutation gaps at `minor`
(**a test asserting something FALSE keeps its true severity; a test merely not asserting
ENOUGH is minor**). The mandate stays light at rounds 1–2, where real defects still
surface, and escalates at round 3 where the value curve flattens. At the strict tier the
panel is asked to state outright when most of its blocking findings target code an earlier
round introduced — reported as `diminishing_returns`, a legitimate reason to end the cycle
with findings still open.

**Measured effect.** Re-running a degenerate round against byte-identical code, with only
the mandate changed, took it from 14 findings (4 major / 10 minor) to 4 (1 major / 3
minor). The surviving major was the one that should survive — production source claiming
CI enforced something it did not, a false assertion rather than a mutation gap.

**Confound, stated plainly.** That run's prompt also told the panel the test file was
QA-added. So 14→4 measures *mandate + framing*, not the mandate alone. Treat it as
encouraging, not as an effect size.

---

## §stop-rules-need-exits — why `diminishing_returns` has an approval path

The stop rule shipped first without one, and that was a bug.

`diminishing_returns` means "stop with findings still open". The approval gate demanded a
**clean round**. So following the panel's own recommendation made an MR permanently
unapprovable — an endless cycle converted into a stuck one, which is worse than the problem
being solved. It was hit in practice about an hour after the stop rule landed.

The **deferred-findings exit** resolves it: a round with open confirmed critical/major
findings is approval-eligible when both a `diminishing_returns` decision was raised *and*
every remaining such finding was explicitly deferred by a human and enumerated by id and
title in a posted note.

The cost is real and worth stating: approval then rests on an enumerated list in a note
rather than on the absence of findings. That is weaker in principle — only as good as the
operator's judgment and the note's accuracy. It was the lesser of two failures, not a free
win. A deferred finding that is not written down has not been deferred.

**General lesson, which recurred three times during this plugin's own QA:** a fix that adds
an escape hatch must be reconciled with every mechanism that already exists — the trigger
that raises it, the guard that might undo it, and every site that documents the old rule.
Hardening one site while another still asserts the opposite is the single most common
defect this cycle finds.
