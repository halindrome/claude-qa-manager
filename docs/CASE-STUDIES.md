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

---

## §lens-contamination — why reviewers may not touch the working tree

A concurrent reviewer panel shares ONE working tree. On a live round, one lens ran
mutation testing — stub a function, run the suite, see whether a test notices, restore
the file. A second lens, reading concurrently, saw the stubbed function and filed
findings about it. Those findings described the mutation, not the merge request.

**Why the existing rule did not prevent it.** The reviewer contract already said
"strictly read-only". A lens that intends to restore a file in a moment does not read
that as modifying anything, and mutation testing is a legitimate technique in
isolation. The prohibition was true and insufficient.

**Why it went unnoticed.** Nothing compared the tree before and after. It surfaced only
because a human happened to be reading the orchestrator's narration. Had the lens died
mid-mutation, the stub would have been left in place and committed by the fix step.

**What this plugin does about it.**

1. Reviewers get no file-writing tools, and the prohibition names the transient case
   explicitly, because "I will put it back" was the loophole.
2. The manager brackets the panel: a snapshot of HEAD, branch and status before
   fan-out and after every reviewer returns. A difference is reported, never
   auto-reverted — a leftover stub and the author's own uncommitted work are
   indistinguishable, and guessing wrong destroys someone's changes.
3. HEAD is in the snapshot, not just the dirty-file list. A clean branch switch leaves
   `status --porcelain` byte-identical, so a tree-dirt check alone cannot see one.

**The deeper point.** Containment beats prohibition. Given a private checkout per
reviewer, mutation testing would be safe and useful; forbidding it outright is a
stopgap that costs a real capability. The prohibition is what fits an architecture
where reviewers share a tree.

---

## §unrun-suite — why "the tests were not run" must be said out loud

Across two consecutive rounds on one merge request, a six-reviewer panel graded
thirteen acceptance criteria without executing a single test. Every claim — including
whether a newly added test actually failed before the fix — was derived by reading
assertions and by trusting a commit message.

The panel was **right** to decline. Its detected test entry point managed service
lifecycle (it restarted the stack, ran the suite, then shut the stack down), and
several reviewers were reading the same tree concurrently. Running it would have
broken the review it was meant to support.

**What went wrong was not the decision but the silence around it.** Two things had to
be true for this to be safe, and only one was:

1. The panel said so, prominently, in the round note. A grade of PASS that is really
   "PASS by reading" is a different claim, and it was labelled as one.
2. Something else should have executed the suite. Nothing did, because the fix step —
   the one place execution belongs — never ran, and no gate noticed that a round had
   closed with zero execution evidence.

**What this plugin does about it.** Reviewers never run the suite, unconditionally, so
the decision is no longer re-derived per round by whoever is reasoning that day.
Execution happens in exactly one place, the fix step, single-threaded, after the panel
has finished. When the discovered command is unsafe to run even there, the answer is a
per-target override naming a safe invocation — and the round is required to say it
skipped, not to fall silent.

**General lesson.** Detection finds *a* test entry point, not a *safe* one: it proves a
target exists, not what the recipe does. Any gate that can decline must report
declining, or "we didn't check" becomes indistinguishable from "we checked and it was
fine" — which is the failure this entire document is about.

**A detected command may encapsulate things you cannot see.** The obvious response to
"the discovered test target has side effects" is to run the useful part of it — read
the recipe, lift out the line that actually runs the suite, skip the rest. That
reasoning is wrong, and its wrongness is silent.

A test target is an **interface**; its recipe is the implementation. On one real
project the recipe brought a container stack up, cleared message-broker volumes,
waited for the database, copied three fixture files into two locations, ran the
suite, and tore the stack down. Lifting out the suite invocation alone would have
run it on the host rather than in the container it requires, without its fixtures,
against whatever state the previous run left. It would not have errored. It would
have produced output, exited zero, and been recorded as verification.

So the rule is: **never decompose a discovered entry point.** Either use it, or name
a different entry point the project already provides — projects that wrap their
suite usually offer more than one. What you must not do is synthesise a third
command out of the first one's insides, and least of all write that synthesis into
configuration, where it becomes the permanent answer for every future round.

The same reasoning limits what an override is for. `verify.command` exists for a
project that documents no procedure — not for editorialising one that does. Where a
project's own rules describe how its suite is run, those rules are the source of
truth, and reading them is the correct behaviour; a config key that restates part of
them is a fork that drifts from the moment it is written.

## §green-first-tests — why a new test must be seen to fail before the fix exists

Across five QA cycles in one week, the fix step repeatedly authored a test, found it
broken, and spent the rest of that round — sometimes the next one — debugging it. The
cycles ran long, and the length bought very little.

**Not one of those was a wrong assertion.** Every instance was a harness or environment
defect: a constructor that `chdir`s, so a later `system()` resolved nothing; an exit
status taken off `| tail` rather than the command under test; zsh's builtin `echo`
interpreting escapes for a `#!/bin/bash` script; a `PREPARE FROM "…"` harness adding a
second SQL parsing layer the real path never performs; a guard that short-circuited
before the branch under test was reached. Two more cost a round each on scope alone — a
local run covering 5 of N suites that went red in CI, and tests written to the suite root
instead of the subsystem folder.

**The load-bearing mutation check does not catch these.** It asks whether the result flips
when the source changes. A broken harness can flip, fail both ways, or pass both ways, all
for reasons unrelated to the behaviour under test.

**What went wrong was the order, not the checks.** The rule was "write the test, confirm
it passes, then revert the source and confirm it fails". Both runs happen either way — but
green-first means a harness defect only surfaces *after* the fix, the assertions, and the
author's confidence are already stacked on top of it, so the instinct is to debug forward
rather than discard. Red-first surfaces it on run one, as *the wrong failure message*,
when the test is still free to throw away.

**The `| tail` case deserves its own note**, because it is the only defect here that does
not announce itself. A pipe replaces the exit status of the command under test with the
filter's, which is almost always `0` — so the negative control, the run whose entire
purpose is to fail, reports success. In plain `Bash` the context-mode enforcer hook blocks
that idiom. Inside a `ctx_execute` payload the rule is only advisory, and the fix step runs
suites through exactly those payloads: one measured session recorded 11 truncating payloads
against 1 truncating `Bash` call.

**What this plugin does about it.** The spine inverts the order at Step 3B.4 and requires
the failure message to name the behaviour under test, not merely to be red. `fix-mandate.md`
gained a capture section that branches on `ctx_available` exactly as it already branched on
`cmm_available` — the fix step was previously the only participant with no context-mode
guidance at all, while every lens got it via `tool-mandate.md`. Depth lives in
`skills/qa-cycle/references/test-authoring.md`.

**General lesson.** A verification step has an order as well as a content, and the order
decides what a failure costs you. Run the check that can invalidate the work *before* you
build on the work.

## §self-approval-fallback — why an approval may never degrade to the dev identity

On the **first end-to-end `/qa-cycle` run from this repo** (GitLab, a 214-line MR, two
rounds, both clean), the cycle approved the MR **as its own author**. The gate that
exists to keep author and approver distinct did not fail loudly — it produced a green
"approved" line and a correctly-worded approval comment, under the wrong identity.

**The chain, in order.**

1. `Step 3E`'s snippet in `references/approval.md` uses `$QA_TOKEN`, but nothing in the
   **main loop** ever assigns it. The token names are resolved by preflight and written
   only into the **manager brief** (`qa_token_env`, `qa_token_file`) — and the manager is
   a different context from the one Step 3E runs in. `preflight.json` itself carries
   `qa_token_ok` and `qa_auth_user`, which report that a token *resolved*, but not what to
   resolve it *from*.
2. Facing an undefined variable with no documented source, the operator did the natural
   thing and reconstructed it — using the env-var name and token path from the
   **predecessor skill this plugin was extracted from**, rather than this plugin's
   (`QA_AGENT_TOKEN`, `~/.config/claude-qa-manager/qa-agent-token`). The two differ by a
   prefix and a filename. Both reconstructions resolved **empty**. This is a predictable
   failure for any adopter migrating from a private ancestor, not a one-off slip.
3. `forge_approve` treats an empty token as "use the default identity". For
   `forge_post_note` that is a deliberate, documented degradation — losing a round note
   entirely is worse than posting it under the developer's name, and SKILL.md requires a
   `⚠ Posted with dev credentials` line when it happens. `forge_approve` inherited the
   same behaviour without inheriting the reasoning.

**Why the degradation is not equivalent.** A note under the wrong name is mislabelled
evidence. An approval under the wrong name is a **different fact**: on a self-authored MR
it converts *"QA has not approved"* into *"the author approved"* — which passes an
approvals check, appears in the audit trail as review, and is strictly worse than no
approval at all. Degrading a note preserves information; degrading an approval fabricates
it.

**Nothing in the run reported a problem.** `preflight.json` said `qa_token_ok: true` and
named the QA agent in `qa_auth_user` — correctly, because *preflight* resolved the token
fine; only the approval step's own re-derivation failed.
The seam returned success, because approving as the developer is a successful approve. The
misattribution was caught only because the operator ran `forge_approvers` afterwards and
read the name. Had they trusted the tool's own success message, an MR would carry a
self-approval that reads as an independent one.

**What this argues for.**

- **`forge_approve` / `forge_unapprove` must refuse an empty token** — non-zero, no API
  call. Approval is not a degradable action. `forge_post_note` should keep degrading:
  the asymmetry is the point, and it should be stated at both definitions so neither is
  "tidied" into consistency with the other later.
- **A step must not re-derive a credential preflight already resolved.** Publish
  `qa_token_env` / `qa_token_file` in `preflight.json` (not only in the manager brief) and
  have Step 3E read them. A re-derivation can fail *open*; a read cannot.
- **Verify the approver after approving**, against `expected_qa_user`, and fail the step if
  it does not match or if it equals the MR author. This is the check that actually caught
  the incident, and it belongs in the skill rather than in an operator's habits.

The general shape is worth naming, because it is not specific to tokens: **a fallback that
is correct for one action can be catastrophic for another, and inheriting it by proximity
is how that happens.** When two operations share a helper, the question is not "what does
this helper do on missing input" but "what does *each caller* mean by missing input".

### Addendum — it recurred on 2026-08-03, with the remedy still unimplemented

**observability-stack !14**, a two-round cycle. Same root cause, different blast radius: the
notes, not the approval.

The second bullet under *What this argues for* — publish `qa_token_env` / `qa_token_file` in
`preflight.json`, not only in the manager brief — **had not been implemented at the time of
the run.** `preflight.sh` passed all three values to `jq`, but the object body never referenced
them, and jq drops an unreferenced `--arg` without complaint. So the keys stayed brief-only,
while `skills/qa-cycle/SKILL.md`'s field table listed them as `preflight.json` fields and
instructed the main loop to *"Read these; never re-derive them from config."*

*(Now fixed: the emission landed on 2026-08-03, after this incident. The rest of this
addendum describes the pre-fix behaviour and the lessons that outlive it — items 1–3 under
"Two further lessons" below are **not** closed by that emission.)*

That combination is worse than the original gap. A session that **follows the instruction**
looks in `preflight.json`, finds the keys absent, and is left to reconstruct the path anyway —
having just been told not to. The documentation now points at a value that is not there, which
is a stronger invitation to guess than saying nothing would have been.

The guess landed on `~/.config/claude-qa-manager/qa-token`; the real file is `qa-agent-token`.
`cat` on the missing path returned empty, empty means "act as the developer", and **all three
round notes posted under the developer's account while their footers claimed the QA agent.**
On a self-authored MR that made author and reviewer the same account — the property the split
identity exists to prevent — with no visible signal: every post returned success, and the
footer is text the same session wrote.

Two further lessons this run adds:

- **`QA_TOKEN_OK` is not a guard on the caller.** It reports that *preflight* resolved a
  token. Here it was `true`, and `qa_auth_user` correctly named the QA agent, while the main
  loop held an empty string. The `⚠ Posted with dev credentials` line is gated on
  `QA_TOKEN_OK` and therefore never fired in the one situation it exists for. **A guard must
  test the value actually about to be used, not a report that some earlier step succeeded.**
- **The third bullet generalises beyond approval.** *Verify the actor after acting* was scoped
  to approvals. Notes need it too — the API returns the created note's `author.username`, so
  the check costs nothing and is the only thing that distinguishes a correctly attributed note
  from a misattributed one. A footer asserting the identity is not evidence of it.

Cost of the recurrence: the misattribution is permanent. Note authorship cannot be rewritten,
and the MR merged before anyone noticed, so the approval could not be recorded afterwards
either — `POST /merge_requests/:iid/approve` returns 401 once merged. Corrections had to be
posted as follow-up comments admitting the earlier ones were wrong.

**The meta-lesson.** This case study was already written, already correct, and already
prescribed the fix. It did not prevent the recurrence, because the prescription lived in a
document while the defect lived in code that still behaved the old way — and the skill's own
field table had drifted into actively contradicting the implementation. **A documented remedy
that is not implemented is not a remedy; the write-up can make things worse by implying the
hole is closed.** Where a fix is deferred, say so at the code, not only in the retrospective.
