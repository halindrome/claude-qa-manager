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

Eight commits on `main` in `~/Sources/claude-qa-manager`. **Never pushed.** That was
deliberate: the repo is public-destined and git history is permanent, so the scrub had to be
complete *before* the first push rather than fixed in a later commit.

| Check | Result |
|---|---|
| `test/preflight.test.sh` | 160 passed / 0 failed |
| `test/init.test.sh` | 21 passed / 0 failed |
| `test/no-private-identifiers.sh` | clean (and verified non-vacuous) |
| `claude plugin validate .` | passes |
| Inventory | Skills (2) `qa-init`, `qa-cycle`; Agents (2) `qa-manager`, `qa-reviewer` |
| `/qa-cycle` on-invoke cost | ~15.6k tokens (was ~41.9k; ~15.1k before the forge seam) |
| Always-on cost | ~682 tokens for the whole plugin |

### Commits

1. `d6aaeea` scaffold — Apache-2.0, manifests, case studies, config model, CI, scrub guard
2. `3fb0dac` preflight + its suite, decoupled from the host repo layout
3. `19e4272` skill + both agents; suite goes fully green
4. `50c2b8b` `init` — environment check, project config, verified token setup
5. `1f1e636` spine split — 41.9k → 15.1k on-invoke
6. `21210e6` CLAUDE.md + this file, as a session handoff
7. `3994af0` rename `qa-round` → `qa-cycle`; aliases dropped
8. the forge seam (Phase 3) — see `git log` for the hash

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
| Skill named **`qa-cycle`**, not `qa-round` | One invocation drives the whole cycle: Step 3D loops into round N+1, Step 3E approves, Step 4 prints "QA Cycle Complete". `round` is the unit *inside* the skill, not the skill. Renamed together with the project config path (`.claude/skills/qa-cycle/config.json`), the scratch prefix (`/tmp/qa-cycle-*`) and the test seam (`QA_CYCLE_SCRATCH_ROOT`). |
| **No aliases** — `/qa-cycle` only | The forge is detected from the git remote, so `/mr-qa` vs `/pr-qa` encodes nothing the plugin does not already know. `/pr-qa` would also collide with the older sibling skill still installed at `~/.config/claude-code/skills/pr-qa/`. Two extra always-on skill descriptions bought nothing. |

---

## What is left

### Phase 3 — forge adapter and absorbing pr-qa  *(DONE — code complete, unexercised)*

1. ✅ **Forge seam extracted.** `lib/forge.sh` (dispatcher + shared URL parsing) with
   `lib/forge-gitlab.sh` / `lib/forge-github.sh` behind it. Contract: `forge_cli`,
   `forge_auth_user`, `forge_project_slug`, `forge_project_enc`, `forge_view_mr`,
   `forge_approvers`, `forge_notes`, `forge_post_note`, `forge_approve`,
   `forge_unapprove`. **The normalized shape is GitLab's**, so the GitLab backend is a
   near-passthrough and GitHub carries the whole mapping.
2. ✅ **Second-opinion shims collapsed** — `--mr` and `--pr` are the same flag in both
   `do-reviewer.sh` and `qwen-reviewer.sh`. That was ~all of the sibling's 18-line delta.
3. ✅ **GitHub SAST ported** to `lib/fetch-sast-github.sh`; the GitLab one is now
   `lib/fetch-sast-gitlab.sh`. Preflight picks `lib/fetch-sast-${forge}.sh`. They share an
   interface and an **output contract** (the classifier phrases), not an implementation.
4. ~~**Aliases.**~~ Dropped — see the decisions table. `/qa-cycle` is the only entry point.
5. The sibling still lives at `~/.config/claude-code/skills/pr-qa/` — source material for
   the GitHub paths. **It has no `preflight.sh`**; it is the older design.

**Things the port changed on purpose, not by accident:**

- The sibling's GitHub SAST helper emitted its "checks still running" warning as a
  subsection **after** the `## NEW SAST findings` heading, so preflight's classifier
  scored a still-running scan as `clean` — and Step 3E writes that into a permanent
  approval comment. Every "did not run" state is now decided and exited **before** the
  findings heading.
- `forge_approvers` (GitLab) reads `/approvals` first and `/approval_state` second.
  `approval.md` had always documented that `/approval_state` lags after a human approves,
  but preflight's seeding used only the lagging endpoint.
- GitHub keeps the full review history, so `forge_approvers` reduces to each reviewer's
  **latest** state — otherwise a withdrawn approval still reads as an approval.
- New `forge` config key + `QA_FORGE` env override, because host sniffing cannot see a
  self-hosted GitLab or a GitHub Enterprise instance. Unresolvable is **exit 2**, never a
  silent default to GitLab.

**JSON keys renamed** (`gitlab_project` → `project`, `gitlab_project_enc` → `project_enc`)
and `forge` / `forge_cli` added.

### Smaller, independent items

- **Consider `effort` on the agent definitions — upward, not downward.** Subagent
  frontmatter supports `effort: low|medium|high|xhigh|max` ("Overrides the session effort
  level. Default: inherits from session"; available levels depend on the model). Nothing
  in this plugin sets it, so both agents inherit. The interesting move is *raising* it on
  `qa-reviewer`: invariant 6 says never manage review cost by downgrading the model, and
  effort is the same lever class, so the same reasoning makes a harder-thinking reviewer a
  legitimate quality lever. Unresolved before changing anything: it multiplies across up
  to six concurrent lenses; a level the session's model does not support needs a defined
  fallback rather than a silent one; and `qa-manager` is coordination rather than
  analysis, so it probably wants a different answer from the lenses. Worth an A/B on one
  MR — same target, same panel width — rather than a guess.
  Related fields on the same page that this plugin also does not use, and which may be
  worth more than effort: `skills` (preloads full skill content at subagent startup — the
  tool-mandate injection currently does that by hand), `isolation: worktree` (a private
  checkout per lens, which is the containment answer to the shared-tree problem in
  CASE-STUDIES §lens-contamination, and would make mutation testing safe rather than
  forbidden), `maxTurns`, and `background`.
  Also from that page: **extended thinking is NOT per-subagent** — it inherits from the
  session, with no per-subagent setting, and before Claude Code v2.1.198 subagents ran
  with it disabled regardless. Any measured lens behaviour predating that version was
  measured under different conditions.
- **`docs/INSTALL.md`** — not written. `README.md` currently carries install steps inline
  and does **not** link to it, so this is optional rather than a dangling link.
- **Trim `Step 3A.1`** in the spine. It is the largest kept block; its "why a manager
  subagent" rationale and cost caveats belong in `references/design-notes.md`. The forge
  seam pushed on-invoke from ~15.1k to **~15.6k** (a `forge` row in the field table, the
  seam-sourcing in the post-note block), so the ~15k target is now missed by more than it
  was. This is the identified way back under it.
- **`config/schema.json`** — a JSON Schema for project config, validated on load. Planned,
  not built.
- **`lib/gemma-reviewer.sh`** was NOT migrated (493 lines, present in the source tree) —
  and **both shipped second-opinion helpers are shims over it**, so `--reviewer=do` and
  `--reviewer=qwen-local` cannot work as shipped. They fail loudly ("gemma-reviewer.sh not
  found or not executable"), not silently, but they are documented in
  `references/sequential-and-multimodel.md` as if they work. Either migrate
  `gemma-reviewer.sh` (it holds the actual chat-completions logic both shims delegate to)
  or delete both shims and the docs that reference them. **Do not ship 0.1.0 with this
  unresolved** — it is a documented feature that is guaranteed to fail on first use.
- **The two second-opinion READMEs were not migrated** (`qwen-reviewer.README.md`,
  `gemma-reviewer.README.md` in the source tree). Nothing links to them, so there is no
  dangling reference — but `--reviewer=qwen-local` is documented in
  `references/sequential-and-multimodel.md` with no setup instructions behind it.
- **`init.sh config` only handles the schema question.** Monorepo `targets` must be written
  by hand afterwards. Extending it to prompt for targets would be welcome.
- **Consider a `hooks/` component.** The plugin manifest supports hooks and ships none.

### Field defects from the first end-to-end run (2026-08-03)

The round *has* now been executed end-to-end from this repo — GitLab, `rest-api` MR !712,
a 214-line diff, two rounds, six lenses each, both clean, ending in a QA-agent approval.
The prediction in *Known gaps* held exactly: the first live run is where the latent path
and config bugs surfaced. Four did. **D1 is a correctness defect in the approval gate and
should be fixed before anyone else runs a cycle**; the rest are ordered by severity after
it. Rationale for D1 is written up as `CASE-STUDIES.md` §self-approval-fallback.

Each item below states how it was observed, so a session can reproduce rather than trust.

1. **D1 — an approval can fall back to the developer (author) identity, silently.**
   `forge_approve()` (`lib/forge-gitlab.sh:113`) passes `${3:-}` to `_glab`, so an empty
   token means "use the default identity". On a self-authored MR that turns *no QA
   approval* into *author approved* — it passes an approvals check and reads as review.
   The empty token arose because `references/approval.md`'s Step 3E snippet uses
   `$QA_TOKEN` while **nothing in the main loop assigns it**: `qa_token_env` /
   `qa_token_file` are emitted only into the manager brief (`lib/preflight.sh:1380-1381`),
   and Step 3E does not run in the manager. `preflight.json` carries `qa_token_ok` and
   `qa_auth_user` but not the names to resolve from.
   *Observed:* approve reported success; `forge_approvers` then returned the **author's**
   username. Nothing in preflight, the seam, or the skill reported an error.
   *Fix, three parts:* (a) `forge_approve` / `forge_unapprove` **refuse an empty token**
   (non-zero, no call) on both forges — and say at the definition why `forge_post_note`
   deliberately does *not*, so the asymmetry survives future tidying; (b) publish
   `qa_token_env` / `qa_token_file` in `preflight.json` and have Step 3E read them instead
   of re-deriving; (c) after approving, assert the approver equals `expected_qa_user` and
   is not `mr_author`, failing the step otherwise.
   *Acceptance:* a preflight fixture with no token available must make the approval step
   exit non-zero with the MR unapproved — today it exits zero with the MR approved by the
   author. Worth a `test/` case, since this is the one defect that manufactures a false
   audit record.

2. **D2 — the forge seam's documented argument form disagrees with three of its four
   implementations.** `lib/forge.sh:35-39` documents `forge_approvers`, `forge_post_note`,
   `forge_approve` and `forge_unapprove` as all taking `<enc>` (the URL-encoded slug). Only
   `forge_approvers` accepts it — it re-normalizes via `forge_project_enc` at
   `lib/forge-gitlab.sh:100`. The other three pass the argument to `glab -R`, which requires
   `OWNER/REPO` and rejects `owner%2Frepo`.
   *Observed:* `forge_unapprove owner%2Frepo <n>` — the documented form — failed with
   `Expected the "[HOST/]OWNER/[NAMESPACE/]REPO" format`. SKILL.md's own
   samples pass the *unencoded* `$PROJECT`, so the code is right and the header comment is
   wrong.
   *Fix:* either normalize in all four (cheapest: call `forge_project_enc` / a matching
   `forge_project_slug` at the top of each) or correct the header to state which form each
   takes. Normalizing is better — a seam whose members disagree on their argument form is a
   trap for exactly the caller who read the docs.

3. **D3 — lens subagents cannot load the CMM / `ctx_*` tooling they are mandated to use.**
   All six lenses reported it in **both** rounds. Where those tools are *deferred* in the
   host session, they must be loaded with `ToolSearch` before first use — and inside a
   `qa-reviewer` subagent `ToolSearch` returns **"No matching deferred tools found"**. So
   the deferred-tool registry is not reachable from a subagent at all, and the mandate in
   `agents/qa-reviewer.md` (and the CMM preamble the host injects) describes tooling the
   lens cannot obtain.
   *Observed:* round 1 lenses fell back to `Read` + standalone `perl` probes; round 2
   explicitly instructed each lens to call `ToolSearch` first, and that mitigation **failed
   the same way** — so this is not fixable by prompt wording.
   *Impact:* reviews still executed real experiments and produced grounded findings, so
   this degrades quality rather than breaking it. But the mandate currently *claims* a
   navigation regime the lens does not have, which is its own kind of false record.

   **RE-VERIFIED DIRECTLY, 2026-08-03 — fixed.** The field report was confirmed from
   inside a live `qa-reviewer`, after restarting the context-mode MCP server so a server
   fault could be ruled out. From the subagent: calling `search_graph` directly returns
   `No such tool available`; `ToolSearch(select:…)` for four CMM/ctx tools returns
   `No matching deferred tools found`; no `mcp__*` tool is present at startup despite
   `tools: [… mcp__*]` in the frontmatter. It is a platform limit, not a wording problem.

   Two things the original note did not have, both from that run:
   - **The root cause is in `preflight.sh`, not the agent prompt.** `_probe_registered`
     answers *"is this MCP server installed"*, and the mandate turned that into *"the
     tools below ARE available in your session"*. Those are different claims, and the
     second is false for a subagent. That is invariant #2 — an absent capability
     reporting as present — aimed at the lens. It also explains why the round-2
     mitigation could never work: the `ToolSearch` instruction was added for an earlier,
     genuinely different failure (main-loop reviewers that never fetched deferred tools),
     where it is correct.
   - **Reachability depends on `review_mode`, which preflight already knows.** A lens on
     the *manager* path is a subagent and cannot reach them; a reviewer on the
     *sequential* path runs in the main loop and can. Same probe, opposite truth — so the
     mandate is now rendered after `REVIEW_MODE` is set and states the truth for the path
     it is going into. Both paths now require a closing
     `Navigation: <regime>` disclosure line, and the manager records it as
     `lens_navigation` (a missing line is `unknown`, never assumed good) and reports any
     degraded lens in `blocking_summary`. Pinned by tests asserting the manager mandate
     does **not** claim availability and does **not** order a `ToolSearch`, while the
     sequential one keeps both.

   *Still open:* a lens on the manager path has no graph tooling at all, so this is
   mitigated and disclosed, not solved. Recovering it needs one of: the host resolving
   queries and passing results in, or the `skills:` frontmatter preload (untested). Do
   that only if a real round produces a finding a graph query would have caught.

   **Two further platform facts from the same run, both contradicting things this
   project's notes assert.** Neither is fixed; both are worth knowing before trusting a
   subagent's environment:
   - **`PreToolUse` hooks DO fire inside a subagent.** `.claude/rules/cmm-rules.md` and
     `cmm-agent-preamble.md` both state they do not, citing Claude Code issue #34692. In
     the test, `ctx-execute-enforcer.sh` blocked the lens's `grep -c …` `Bash` call with
     its full message, and allowed `git status --short` — i.e. it fired, selectively, via
     its exemption list. The combination is worse than either fact alone: a hook can
     order a lens to route through `ctx_execute` while the lens is unable to load
     `ctx_execute`. That is a deadlock, not a degradation. (This hook is local to this
     repo and unshipped, but any adopter installing context-mode the same way inherits
     the shape.) The remedy belongs in the hook, not here: it should **fail open** when
     `ctx_execute` is unreachable, since a reviewer with no `ctx_execute` and no `Bash`
     is left with `Read` alone.

     Note the clause that is false is *only* the subagent one. `agent-cmm-gate.sh`
     (`PreToolUse:Agent`) behaved exactly as documented on a main-thread `Agent` call,
     blocking a probe that omitted the preamble.
   - **A wildcard in a `tools:` grant can match nothing.** The lens had
     `tools: [Read, Grep, Glob, Bash, ToolSearch, mcp__*]` and came up with no `mcp__*`
     tool at all. `Grep`/`Glob` were also absent, but that is **not** attributable to the
     grant — they are absent from the host session too, so the lens inherited their
     absence. `ToolSearch` DID survive the grant and was callable; it simply returned
     `No matching deferred tools found`. Working hypothesis, not yet isolated: a grant
     resolves against *concretely loaded* tools, so `mcp__*` matches nothing while the
     MCP tools are deferred, where a bare `*` (or no `tools:` key at all) would not
     narrow anything and so cannot drop them.

     This is why `qa-manager` and `pr-qa-reviewer` never hit it: neither declares
     `tools:`, so both get the full set — the breakage was specific to the one agent type
     carrying a restrictive list, not to subagents in general.

     **Fixed by deleting the `tools:` line from `agents/qa-reviewer.md`.** The grant was
     not buying read-only enforcement either: it left `Bash` in place, so the tree was
     always writable. Read-only is now stated as a rule in the prompt and enforced by the
     manager's before/after tree check (§1.4), which was always the real guard. Both
     files that described the old grant were corrected — do not re-add it.

4. **D4 — on the manager path, the round note cannot carry its own `QA-Fix-Commit`
   trailers.** SKILL.md Step 3C requires one trailer per fix commit, and the next round's
   attribution reads them back (`qa_fix_commits`). But Step 3B (fixes) precedes Step 3C
   (post) only on the *sequential* path. With `post_note=true` the manager posts at panel
   completion — before the operator has triaged findings, so before any fix commit exists.
   *Observed:* both rounds posted a clean note with no trailers; the operator had to post a
   separate addendum carrying `QA-Fix-Commit:` so round 2's `qa_fix_commits` would populate.
   It did populate, which confirms the read-back works — but only because of a manual step
   the skill never asks for.
   *Fix:* either have the manager return `note_path` unposted when the round produced
   actionable findings (let main post after 3B), or define an addendum step so the trailer
   requirement is satisfied by something the skill actually prescribes. A cycle whose
   attribution depends on an undocumented operator habit will lose it.

**One thing that worked and is worth keeping:** round derivation from posted notes survived
a fresh process across four separate invocations, and `qa_fix_commits` correctly recovered
the round-1 commit from its trailer. The round-2 panel then used it to attribute findings to
QA-introduced code rather than to the MR — the mechanism did what it was designed for.

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

- ~~**The round has never been executed end-to-end from this repo.**~~ **Done, 2026-08-03**
  — GitLab, `rest-api` MR !712: `init.sh check`/`config`, two full rounds (six lenses each,
  both clean), fix commits, SAST wait-gate, and a QA-agent approval. The prediction here was
  right: the first live run was where the latent bugs surfaced, and it produced four —
  including one that **approved an MR as its own author**. See *Field defects from the first
  end-to-end run* above; D1 should be fixed before the next cycle. Still unexercised on this
  path: the deferred-findings exit, the dirty-re-round revocation (`Step 3B.6`), the
  sequential/tiny-MR route, `--double`/`--triple`, and any schema-change MR (the gate ran and
  correctly reported *no* change, so the armed branch is still untested).
- **The GitHub path has never touched a real GitHub PR.** `forge-github.sh` and
  `fetch-sast-github.sh` are exercised only against the suite's `gh` stub, which emits
  GitHub's native shape so the normalization is genuinely under test — but a stub cannot
  catch an endpoint that moved, a scope a token lacks, or a field GitHub renamed. Treat
  every GitHub-specific claim in this file as **code-complete, not verified**. The GitLab
  path at least inherits several hundred real review rounds; the GitHub path inherits the
  sibling's mileage only where the logic was ported unchanged, and several pieces were
  deliberately not (see Phase 3's "changed on purpose").
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
