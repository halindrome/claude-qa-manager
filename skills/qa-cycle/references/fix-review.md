# Reviewing the cycle's own fixes

Depth for SKILL.md Step 3B (minor routing, no round narration) and Step 3B.5 (the
fix-diff review lens). The spine states each rule and its one-line why; the
measurements and the reasoning are here.

## The problem these rules address

Step 3B is the only unreviewed writer in the loop. Lenses are merged by the manager
and the round note is read by a human, but the fix the main loop writes is first
examined by a **full 3–6 lens panel one round later**. So catching a bad fix costs an
entire round, and the fix that round writes costs another.

Measured over 76 `/qa-cycle` sessions across 21 projects, 267 round-records:

- **88 of 157 rounds >= 2 (56%)** carry at least one finding on code an earlier round
  of the same cycle wrote. **0 of 106 round-1 records** do, by construction — no fix
  commits exist yet, which is why Step 3B.5 exempts round 1.
- **36 rounds were pure fix noise**: zero blocking findings, but a full panel spent
  reviewing the previous round's own commit.
- The rate is **flat across five weeks** of tuning (69/51/56/52/56%), while blocking
  findings fell 94 → 50 and minors did not (149 → 184). Structural, not tuning.
- 98 of 106 cycles reach round 2, so "one extra lens at round 2+" is a cost almost
  every cycle already pays a full panel for.

## What the self-inflicted findings actually are

199 unique findings, four classes needing different treatment:

| class | count | blocking | handled by |
|---|---|---|---|
| A — artifact in a **test file** the fix wrote | 58 | 3 | 3B minor routing → ledger |
| B — **round narration** in a production file | 35 | 6 | 3B no-narration rule |
| C — coverage gap on the fix itself | 15 | 3 | 3B ask (no deterministic signal) |
| D — **runtime regression** | 91 | 21 | 3B.5 fix-diff review |

A + B + C = 108 of 199 (54%) are artifacts of the remediation process rather than
defects in the product. But **D is the largest single class and holds 21 of the 33
blocking findings**, and only a reviewer catches those.

## Why minor + test-file is never offered as a fix

Class A is 58 findings, **55 of them minor**. Fixing one costs a commit, a post, and
another full panel whose main subject is that fix. The findings themselves are real
but small: assertions weaker than their labels claim, a spec pinning the wrong
contract, a coverage-gap header that under-describes the gap.

The line is **severity plus location**, never "this cycle wrote it, so skip it":

- minor + `qa_introduced` + `in_test_file` → ledger, not offered;
- minor + `qa_introduced`, production file → still ask. A minor defect in code a
  customer executes is worth a human's judgement even when this cycle introduced it.

`in_test_file` is stamped by `lib/attribute-findings.sh` from the **path only** —
never file content, for the reason `docs/CASE-STUDIES.md` §schema-drift records about
DDL scanning. The default vocabulary and the `review.test_path_pattern` override are
documented in `config/defaults.json`.

**Absent is not false.** The sequential and `--double` paths never call
`attribute-findings.sh`, so the field does not exist there. Absent means unknown and
Step 3B asks — reading a missing field as "not a test" would divert nothing while
looking exactly like a working rule.

Class C (coverage gaps on the fix) has no deterministic signal — it is a judgement
about what a test asserts, and the lens `category` axis is absent on 103 of 199
findings, so no rule can key on it. Those stay in the ordinary ask.

## Why the fix commit carries no round narration

Class B is 35 findings, 6 blocking. Every one is the previous round's own commentary
being found false by the next panel:

- "Round-1 comment overstates Try::Tiny: `last` is inert only in catch, not in try"
- "Rewritten safety comment still asserts a false isolation invariant"
- "The dangling-link refusal comment overstates what the code detects"
- "resolveRequiredTeamScope docblock names an unreachable mechanism"
- "Round-2 comments and spec titles claim the filter orthogonal is live on these columns"

The distinction is not "no comments". A comment explaining **why the code is the way
it is** is good and stays. A comment reporting **what QA did this round** is a claim
about process, it belongs in the round note, and it is a finding waiting to happen —
because the next round reads it as an assertion about the code and checks it.

## Why one lens for the fix review, not a panel

Invariant 6 forbids managing review cost by downgrading the model, so 3B.5 uses the
**same model** as the panel — the saving is width, not strength. One lens against
`<fix-commit>^..<fix-commit>` answers the two questions that catch class D:

1. does this diff do what the finding asked?
2. does it leave a **sibling site asserting the opposite**?

Question 2 is invariant 4, the single most common defect this project re-finds: a fix
hardens the cited line while another site still asserts the reverse. A finding names
one site; it does not bound the defect.

`skip_contract_verification=true` is set because the contract was already verified by
the full panel in the same round. This is a diff review, not a second round.

### The did-not-run state

`fix_review.state` is one of `clean | findings | skipped:round-1 |
skipped:no-fix-commit | skipped:spawn-refused`. A skipped review is **never** reported
as a clean one — invariant 2. If the spawn was refused, the note says the round's fix
is unreviewed, which is a fact about the round, not a detail to omit.

### Why the push moved

Step 3B commits but no longer pushes; 3B.5 pushes after the review. A fix the review
corrects is **amended into this round's own commit**, so the round still produces
exactly one. A second commit would add a second `QA-Fix-Commit` trailer, and those
trailers are what the next round reads to tell an MR defect from one this cycle
introduced — so an extra one misattributes the next round's blame.
