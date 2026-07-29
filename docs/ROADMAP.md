# Roadmap and current state

Written as a handoff. Everything below is verified, not assumed; where something is
unverified it says so.

---

## Where this came from

The plugin was extracted from a private, single-organisation implementation that lived as a
**copied-per-project** skill: a full copy of `SKILL.md` (1748 lines), `preflight.sh` (1027
lines), the test suite and five helper scripts, plus two agent definitions, duplicated into
every repo that used it. That duplication was the problem being solved.

A separate, older sibling (`pr-qa`, GitHub) also existed with the same shape and less
capability. Folding it in is Phase 3 below.

---

## Current state — working, local only

Five commits on `main` in `~/Sources/claude-qa-manager`. **Never pushed.** That was
deliberate: the repo is public-destined and git history is permanent, so the scrub had to be
complete *before* the first push rather than fixed in a later commit.

| Check | Result |
|---|---|
| `test/preflight.test.sh` | 151 passed / 0 failed |
| `test/init.test.sh` | 21 passed / 0 failed |
| `test/no-private-identifiers.sh` | clean (and verified non-vacuous) |
| `claude plugin validate .` | passes |
| Inventory | Skills (2) `qa-init`, `qa-round`; Agents (2) `qa-manager`, `qa-reviewer` |
| `/qa-round` on-invoke cost | ~15.1k tokens (was ~41.9k) |
| Always-on cost | ~682 tokens for the whole plugin |

### Commits

1. `d6aaeea` scaffold — Apache-2.0, manifests, case studies, config model, CI, scrub guard
2. `3fb0dac` preflight + its suite, decoupled from the host repo layout
3. `19e4272` skill + both agents; suite goes fully green
4. `50c2b8b` `init` — environment check, project config, verified token setup
5. `1f1e636` spine split — 41.9k → 15.1k on-invoke

---

## Decisions already made — do not relitigate

| Decision | Why |
|---|---|
| Ship as a **Claude Code plugin** | Verified by spike: a conventional `agents/` dir is discovered with **no manifest key**. The design depends on Agent subagents nesting two deep, `AskUserQuestion` gating human decisions, and `SubagentStart` injection — abstracting that away would gut it. Claude-specific by choice. |
| **Apache-2.0**, public, personal work | Owner's call; stated explicitly. |
| Repo name `claude-qa-manager` under `halindrome` | Chosen over `qa-rounds` / `mr-qa`. |
| **Build locally, push only when clean** | Public history is permanent. |
| **One skill with a forge adapter**, not two | The flows are identical; only the forge differs. Pays the spine cost once and lets `pr-qa` inherit preflight, the manager panel and proportionality, which it lacks. |
| **Targets are optional**; branches derive at runtime from the MR/PR | The older sibling's one genuinely better idea. A single repo needs zero config. |
| **Schema paths configurable, defaulting to empty**, gate reports `skipped:not-configured` | In the origin repo the gate was inert but *looked* like it ran. |
| Case studies **anonymised, not deleted** | Every number retained; only identifiers dropped. They are the empirical backbone of the design and make it more credible, not less. |
| Spine + `references/` split | The 42k on-invoke cost was indefensible; ~15k of it described work preflight already performs. |

---

## What is left

### Phase 3 — forge adapter and absorbing pr-qa  *(next; approved)*

The one substantial piece of work remaining.

1. **Extract a forge seam.** Everything forge-specific behind `lib/forge-gitlab.sh` /
   `lib/forge-github.sh`, selected from the git remote (`lib/init.sh` already has
   `detect_forge`; reuse it rather than writing a second detector). Surface needed:
   view MR/PR, list notes/comments, post a note, approve/unapprove, resolve auth identity.
2. **Collapse the second-opinion shims.** `lib/do-reviewer.sh` differs from the sibling's
   copy by only **18 lines** — a genuine shared core. (`fetch-sast-findings.sh` differs by
   536 lines because GitLab artifacts and GitHub code-scanning are genuinely different;
   keep two implementations behind one interface.)
3. **Port the sibling's GitHub SAST path** to `lib/fetch-sast-github.sh`.
4. **Aliases.** Keep `/mr-qa` and `/pr-qa` as thin aliases onto `qa-round` so existing
   muscle memory works.
5. The sibling still lives at `~/.config/claude-code/skills/pr-qa/` — source material for
   the GitHub paths. **It has no `preflight.sh`**; it is the older design.

### Smaller, independent items

- **`docs/INSTALL.md`** — not written. `README.md` currently carries install steps inline
  and does **not** link to it, so this is optional rather than a dangling link.
- **Trim `Step 3A.1`** in the spine. It is the largest kept block; its "why a manager
  subagent" rationale and cost caveats belong in `references/design-notes.md`. This is what
  would take 15.1k under the 15k target that was set and narrowly missed.
- **`config/schema.json`** — a JSON Schema for project config, validated on load. Planned,
  not built.
- **`lib/gemma-reviewer.sh`** was NOT migrated (present in the source tree). Decide whether
  it is still wanted.
- **The two second-opinion READMEs were not migrated** (`qwen-reviewer.README.md`,
  `gemma-reviewer.README.md` in the source tree). Nothing links to them, so there is no
  dangling reference — but `--reviewer=qwen-local` is documented in
  `references/sequential-and-multimodel.md` with no setup instructions behind it.
- **`init.sh config` only handles the schema question.** Monorepo `targets` must be written
  by hand afterwards. Extending it to prompt for targets would be welcome.
- **Consider a `hooks/` component.** The plugin manifest supports hooks and ships none.

### Before the first push

1. All three suites green + `claude plugin validate .`.
2. `bash test/no-private-identifiers.sh` clean — the gate on going public.
3. `gh repo create halindrome/claude-qa-manager --public --source . --push` (authed as
   `halindrome`, a **user** account, with `repo` + `workflow` scopes — verified).
4. Confirm CI goes green on ubuntu **and** macOS. macOS ships bash 3.2 and BSD `sed`/`grep`;
   both axes have broken this code before, which is why the matrix exists.
5. Only then `claude plugin marketplace add halindrome/claude-qa-manager`.

---

## Known gaps and honest caveats

- **The round has never been executed end-to-end from this repo.** Preflight, init and the
  manifest are tested; a full `/qa-round` against a live MR using *this* plugin has not been
  run. That is the highest-value next validation after Phase 3 — and the most likely place
  for a latent path or config bug to surface.
- **`review_mode`, lens selection and proportionality tiers are inherited unchanged** from
  an implementation tuned against one organisation's repos. The thresholds (`round >= 3`
  escalation, severity caps, 6-lens ceiling) are reasoned from a small number of real
  cycles, not tuned broadly.
- **An MR sourced from a protected branch gets no automated QA** — preflight exits 4 and the
  round does not run. This is the deliberate safe failure; supporting it properly needs a
  three-dot diff range threaded through every consumer and the fix step gated to
  report-only. Its own change, its own review.
- **The 6 tests that were permanently red in the source repo are gone, not fixed.** They
  asserted one organisation's target registry, which is now project config, so the block was
  re-aimed at what this repo ships (defaults and examples must parse and may only use known
  lens tags). If that trade reads wrong, it is worth revisiting.
- **Second-opinion reviewers are unverified here.** `do-reviewer.sh` and `qwen-reviewer.sh`
  were migrated but never invoked in this repo; they need `DO_LLM_API_KEY` / a local LM
  Studio respectively.
