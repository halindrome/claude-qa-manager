# `/qa-cycle` — usage

**Read and print verbatim when `--help`/`-h` is passed, or when no MR/PR number was
given.** Print it, then stop: no preflight, no spawn, no branch touched. Everything below
is written to be read by the operator, not paraphrased.

```
/qa-cycle <mr|pr-number> [target] [flags]

  Run a structured QA review cycle on a merge request or pull request: round 1,
  then further rounds for as long as the findings justify one, ending in an
  approval, a deferred-findings exit, or a decision to stop.

ARGUMENTS
  <mr|pr-number>   Required. The MR (GitLab) or PR (GitHub) number. The forge is
                   detected from the git remote; branches are derived from the
                   MR/PR at runtime, so a single-repo project needs no config.

  [target]         Optional. Names a configured sub-project in a monorepo.
                   Omit it where the project defines exactly one target. Where it
                   defines several the target is REQUIRED — /qa-cycle will not
                   guess, because a `default` entry exists even in a monorepo and
                   would silently review the repo root.

FLAGS                     (per invocation; the first four can be defaulted in config)
  --double                 Add one second-opinion reviewer alongside the panel:
                           the first under `second_opinion.reviewers` in config.
  --triple                 Add two (the first two configured). Implies --double.
  --reviewer=<name>        Use this configured reviewer (implies --double).
                           `--reviewer <name>` works too; a bare --reviewer, an
                           unknown name, or no reviewers configured stops with
                           a message rather than skipping silently.
  --single                 No second opinion this time, even if config defaults
                           one.

  --skip-contract-verification
                           Review without verifying the contract. The reviewer
                           prints "Contract Verification: SKIPPED at user
                           request" instead of the table -- never omits it
                           silently. Rarely what you want; the default is to
                           verify, and you are not asked.

  --non-interactive        Pre-answer the gates whose default is mechanical:
    (a.k.a. --yes)         SAST-wait=defer, fixes=report-only,
                           ambiguous contract=highest-confidence (or block when
                           there is no candidate), and continue into round N+1
                           while the round is not clean, fixes were applied,
                           round < 4, and diminishing returns was not declared.
                           It never approves and never defers a finding.
  --interactive            Ask every question this time, even if config defaults
                           --non-interactive.

  --auto-approve           Skip ONLY the final "approve?" confirm on a round that
                           already passes every approval gate. Not implied by
                           --non-interactive; approval is a safety invariant, so
                           it must be asked for by name, and config cannot
                           default it.

  --help, -h               Print this and stop.

NOTHING BYPASSES
  - The schema-change gate. A change to a configured schema file needs a human
    approval (not the author, not the QA agent) plus an acknowledged rollout
    checklist. No flag relaxes this — see docs/CASE-STUDIES.md §schema-drift.
  - The unexpected-deletions gate, which asks whether a destructive-looking sync
    is intended. Under --non-interactive the round stops rather than guessing.
  - CI. Approval probes the forge live and checks the pipeline's SHA against the
    commit being approved.

EXAMPLES
  /qa-cycle 735                     round 1 on MR/PR 735, single-target repo
  /qa-cycle 735 api                 ...against the `api` target of a monorepo
  /qa-cycle 735 --double            ...with a second-opinion reviewer
  /qa-cycle 735 --non-interactive   hands-free up to (not including) approval
  /qa-cycle 735 --non-interactive --auto-approve
                                    hands-free including approval, gates intact

FLAGS DO NOT PERSIST between rounds. Pass them again on round N+1 or multi-model
QA silently stops running -- or set the ones you always want under `flags` in
config (double, triple, reviewer, non_interactive); see docs/CONFIGURING.md.

SETUP
  /qa-init   detects the forge, checks tooling and auth, writes the optional
             project config, and walks through storing a QA agent token.
             Most projects configure nothing.
```

## Keeping this honest

This file is the **public contract for the argument surface**, so it is the one place a
flag's behaviour is stated in the words a user reads. Two consequences:

- A flag added or changed in Step 0 / `references/preflight-internals.md` and not changed
  here leaves the skill documenting behaviour it no longer has. That is worse than no
  usage text, because a user who reads it stops checking.
- The `NOTHING BYPASSES` block is not decoration. Every entry there is a gate a previous
  incident earned, and a usage message that omits them invites exactly the "just add
  `--auto-approve`" reasoning the gates exist to refuse.
