# Authoring a test in Step 3B

Read when a fix needs a new or changed test. The spine states the rules; this is the
evidence and the trap list.

## Why this file exists

Across five measured QA cycles, the fix step's tests went wrong repeatedly — and the
cycles ran long not because the defects were hard but because each one was discovered by
*running* and then debugged forward. Every single instance was a **harness or environment
defect, not a wrong assertion**:

| Defect | What it looked like |
|---|---|
| A constructor `chdir`s | `App->new($path)` changed the cwd, so a later `system()` pointed at a script that no longer resolved. Read as a missing file. |
| Exit status from the wrong process | `cmd \| tail` — `$?` came from `tail`. The **negative control passed**, so the guard under test was never exercised. |
| Shell mismatch | zsh's builtin `echo` interprets backslash escapes; the script under test is `#!/bin/bash`, which does not. The escaping assertion tested the harness. |
| An extra parsing layer | `PREPARE FROM "…"` adds a second round of SQL string parsing the real code path never performs. Produced a phantom `1064`. |
| Precondition not reached | Language detection short-circuited before the fallback cascade under test. The test exercised the wrong branch and looked green. |

Two more that cost a round each, both scope rather than logic:

- **A local run covering 5 of N suites** went green; CI went red on the QA fix commit. The
  next round paid a full panel to find it.
- **Tests written to the suite root** instead of the subsystem folder, breaking the
  convention that lets subsets be run.

The load-bearing mutation check catches none of the first five. It asks "does the result
flip when the source changes" — a broken harness can flip, or fail both ways, or pass both
ways, for reasons that have nothing to do with the behaviour under test.

## The order is the fix

The cheap correction is not another check. It is running the two checks you already run in
the other order.

**Green-first (what produces the rathole):** write the test with the fix applied → it
passes → revert the source → it fails → declare it load-bearing. By the time a harness
defect surfaces you have already built the fix, the assertions, and your confidence on top
of it, so the instinct is to debug forward.

**Red-first:** write the test against the *unfixed* source → run it → **read the failure
message**. A harness defect shows up here, on run one, before anything rests on it, and it
shows up as *the wrong failure* rather than as a mystery. `No such file` where you expected
`assertion failed` is a cwd bug, and it is free to discard a test you have not built on.
Then apply the fix and confirm it passes.

Same two runs. Same total cost. The difference is which run you are holding when the
harness lies to you.

## The two cases red-first does not cover

Both were measured on a single MR, one per round.

### A coverage-only test has no fix to revert

Round 1 added `TranslateWorker.t` for a module the MR did not change. On the negative
control it passed — correctly, and the round said so: *"passes (pure coverage, as
expected)"*. Round 2 then filed two defects against that exact file, one of them **an
assertion that cannot fail by construction**, the other a harness bug (it bootstrapped
against the repo-root config instead of the test config).

The red-first rule says a test *for a fix* must be seen to fail. A coverage test is exempt
by construction, so it gets no falsification check at all — and that is precisely where the
residue landed. Three of the four defects round 2 attributed to round 1 were in new test
files; none were in the production fixes.

**So: when there is no fix to revert, mutate the code under test.** Break the behaviour the
assertion names, watch the test go red, restore. An assertion you have never observed
failing is a claim, not a check.

### A partial read of the precedent you are cloning

Round 1 copied an existing test's `buildParams` setup, reading it with `offset:30,
limit:75` — which stops at line 104. The precedent's list continued past 104 with two more
fields, one annotated **"NOT NULL column in observations schema"**. The resulting test
failed against committed code, and ~25 turns went into diagnosing it. The fix, once found,
was to re-read the same file from line 104.

A partial read is indistinguishable from a complete one. Nothing marks the boundary, and
what you missed does not announce itself — the same property that makes `| tail` dangerous,
one level up. **Open the precedent in full before adapting it.**

## Reading the failure, not the exit code

A test that fails is not yet evidence. The failure has to **name the behaviour under
test**. Check three things on the red run:

1. The failing assertion is the one you wrote, not a setup error earlier in the file.
2. The message describes the behaviour, not the environment — `expected 3, got 0` is
   evidence; `cannot connect`, `no such file`, `permission denied` are harness defects
   wearing a test's clothes.
3. The test actually **reached** the code path. A guard that short-circuits upstream means
   you proved something about a branch you were not testing.

## Capture

`fix-mandate.md`, rendered by preflight for this session, carries the binding rule and
branches on whether Context Mode is registered. Read it — do not assume which regime you
are in.

The invariant under both branches: **the exit status must come from the command under
test.** `cmd | tail` reports `tail`'s status, which is almost always `0`. That converts a
negative control — the run whose whole purpose is to fail — into a silent pass. It is the
worst defect in the catalogue above because it does not look like a defect at all.

Under Context Mode this compounds: the anti-pattern is blocked in plain `Bash` by the
enforcer hook, but is only *advisory* inside a `ctx_execute` payload, and the fix step runs
suites through exactly those payloads. One session recorded 11 truncating payloads against
1 truncating `Bash` call. Filter after capture, in code — never in the pipeline.

`lib/run-verify.sh` is now the payload the fix step runs the suite through, and it holds
the invariant for you: it redirects the suite's output to `--log` rather than piping it, so
the status it reports is the command's own. That is also why it redirects — a pipe leaves
an orphaned grandchild holding the write end, and the read blocks. Read the log afterwards
with `ctx_execute_file` and an `intent=`; do not reintroduce a pipeline around the run to
shorten it.

## Scope and placement

- **State the command you ran, verbatim, in the round note.** `verify.command` may be
  narrower than CI. A subset that passes locally and goes red in CI does not just cost the
  fix — it costs a whole round, because the next panel finds it.
- **A new test goes where that subsystem's siblings live.** A suite organised by folder is
  organised that way so subsets can be run; a file at the root breaks that for everyone.
- If `verify.state` is `none-found`, the round's fixes are unverified. Say so in the note.
  That is a finding about the project, not a passing gate.
