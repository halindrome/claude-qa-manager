# Working in this repo

`claude-qa-manager` is a Claude Code plugin providing structured multi-round QA for merge
and pull requests. It was extracted from a private implementation with several hundred real
review rounds behind it, then generalised and open-sourced.

Read `docs/ROADMAP.md` first — it holds current state, what is left, and the decisions
already made (with reasons) so they are not relitigated.

## Run everything before you claim anything

```bash
bash test/preflight.test.sh          # 346 passed / 0 failed
bash test/init.test.sh               #  32 passed / 0 failed
bash test/no-private-identifiers.sh  # must print ok
claude plugin validate .
claude --plugin-dir . plugin details claude-qa-manager   # inventory + token cost
```

`--plugin-dir` loads the plugin for one session only, so you can test without installing.

**The plugin is ALSO installed at user scope, and it runs from this working tree.** The
`halindrome` marketplace is a `directory` source whose `installLocation` is this repo, so
`CLAUDE_PLUGIN_ROOT` resolves to `~/Sources/claude-qa-manager/` and every real
`/qa-cycle` sources `lib/preflight.sh`, `lib/forge.sh` and the rest from **here** —
verified across three sessions' transcripts, none of which reference the plugin cache at
all. Practical consequence: a live run picks up uncommitted edits immediately. There is no
deploy step to forget, and an experiment left half-finished in the tree is live.

**So `git checkout` is a deploy too** — it rewrites the files the next `/qa-cycle` will
source. Branching away from an unmerged fix silently reverts it in the running plugin,
which is exactly how a `lib/preflight.sh` schema-gate fix left the live plugin the moment
a feature branch was cut from `main`. Uncommitted edits going live is the documented
half; the mirror image is that *committed* work goes dead when you check out a branch
without it. Run `git branch --no-merged main` before branching, and land or cherry-pick
anything the live plugin should not lose.

Do not generalise this. It holds because the source is a `directory`. A **git**-source
marketplace copies into
`~/.config/claude-code/plugins/cache/<marketplace>/<plugin>/<version>/` at install time,
and that copy tracks neither the tree nor `git` — there, editing without bumping the
version in `.claude-plugin/plugin.json` makes `claude plugin update` no-op and report
success over a stale copy, which is invariant 2 in a different costume. A cache directory
exists here from an earlier install; it is inert, and its staleness means nothing.

When in doubt, do not reason about it — ask what actually ran:

```bash
jq -r '.plugins."claude-qa-manager@halindrome"[0] | .version, .installPath' \
   ~/.config/claude-code/plugins/installed_plugins.json
jq -r '.halindrome.installLocation' ~/.config/claude-code/plugins/known_marketplaces.json
grep -o '[^"]*lib/preflight\.sh' <the round's transcript>   # the path it really sourced
```

## Hard invariants

**1. This repo is public and its history is permanent.** It was built locally and only
pushed once clean, so no private identifier is in any commit. Keep it that way:
`test/no-private-identifiers.sh` runs in CI and fails on org names, internal ticket ids, and
secret-shaped literals. It is verified non-vacuous — it fails on a planted identifier and on
a planted token.

**2. Never let an absent check report as a pass.** The recurring theme. An unconfigured
schema gate reports `schema.state=skipped:not-configured`, not clean. Only `sast.gate_state
== clean` means a scan ran. A failed notes probe emits `round_probe_failed` rather than
silently returning round 1. If you add a gate, give it a "did not run" state.

**3. A rule keeps its rationale.** The spine states each rule *and* a one-line why, then
cites `references/` or `docs/CASE-STUDIES.md` for depth. A rule whose justification lives
only in a reference file gets deleted by someone who never opens it — that is a documented
failure mode, not a hypothetical.

**4. Reconcile every site, not just the cited one.** The single most common defect found
during this project's own QA, three rounds running: a fix hardens one place while another
still asserts the opposite. `grep` for every occurrence before declaring a fix complete.

**5. Tests drive the real thing.** Never re-implement production logic in a test and assert
against the copy. An earlier version of the suite did exactly that and was 41/41 green while
7 of 8 deliberate breaks shipped undetected. See the header of `test/preflight.test.sh`.

> **Red-first here means breaking the LIVE plugin — so break a copy instead.** This
> invariant requires proving a test fails without the fix, and the layout note above says
> this tree is what every running `/qa-cycle` sources. Those two collide: a red-first check
> on the working tree ships a deliberate bug to any round running concurrently, in another
> session or another repo. It has happened — a `GH_REPO` export was removed from
> `lib/preflight.sh` for ~2m20s while a real round was live. Do the red run in an isolated
> copy and assert the live tree is untouched in the same breath:
>
> ```bash
> ISO=$(mktemp -d)/iso; mkdir -p "$ISO"
> tar -C ~/Sources/claude-qa-manager --exclude=.git -cf - . | tar -C "$ISO" -xf -   # scrub-ok: this file documents the checkout
> cd "$ISO" && <mutate the copy> && bash test/preflight.test.sh
> ```
>
> The suite is self-contained in the copy — its fixtures take `lib/` from the tree the test
> file lives in — so the red run is faithful. Note also that `ctx_execute` **discards its
> filesystem**: a trailing `cp`-restore in a sandboxed script may never run if the call is
> backgrounded or stopped, so never rely on one to undo a mutation.

**6. Never manage review cost by downgrading the model.** A cheaper reviewer is a weaker
reviewer, which defeats the cycle. Narrow `lens_tags` or the panel width instead.

**7. Do not reintroduce DDL content scanning** for schema detection. Path checks only. See
`docs/CASE-STUDIES.md` §schema-drift for what content scanning cost.

## Traps in this codebase, all hit for real

- **The interactive shell here is zsh, which does NOT word-split unquoted `$VAR`.** A
  bash-idiom scan run under zsh collapses its file list into one bogus filename, greps
  nothing, and reports all-clean. This produced a false all-clear during the scrub.
  Run scripts with `bash` explicitly; use `set -- a b c` + `"$@"` or arrays with
  `"${arr[@]}"`; never rely on word splitting.
- **`perl -0pi -e` with double-quoted replacements interpolates `$(`, `$1`, `$plugin` as
  PERL variables.** This mangled a test file badly enough to need restoring from source.
  Use the `Edit` tool or python with literal strings for anything containing `$`.
- **Blind substitution is wrong for prose about a specific file.** Scrubbing the schema
  rules mechanically produced `apps/api/the configured schema file` and destroyed the key
  point in the passage. Rewrite such passages by hand.
- **`git rev-parse --show-toplevel` returns the SUBMODULE root inside a submodule.** Use
  `--show-superproject-working-tree` first, falling back to `--show-toplevel`. Monorepo
  target paths are relative to the superproject.
- **In a jq `gsub` replacement, `.` is the capture object, not the matched text.** Use a
  named capture: `gsub("(?<c>…)"; "\\" + .c)`. The wrong form raises a type error that a
  `|| echo ""` fallback will swallow, leaving an empty pattern and a gate that reports
  "checked" while matching nothing.
- **`bash -n` is not enough.** It catches syntax, not unbound variables. A rename left
  `$SKILL_DIR` referenced but undefined, which under `set -u` would have hard-failed the
  whole SAST path at runtime. Grep for the old name after any rename.

## Layout

    .claude-plugin/    plugin.json + marketplace.json
    skills/qa-cycle/   SKILL.md (the spine) + references/ (read on demand)
    skills/qa-init/    thin setup skill; delegates to lib/init.sh
    agents/            qa-manager (orchestrates a round), qa-reviewer (one lens)
    lib/               preflight.sh, init.sh, forge seam, second-opinion + SAST helpers
    config/            defaults.json (shipped layer)
    examples/          project-config templates users copy
    test/              two suites + the scrub guard
    docs/              CASE-STUDIES, CONFIGURING, ROADMAP

Config resolves in three layers, later winning, shallow-merged per top-level key:
shipped `config/defaults.json` → user `~/.config/claude-qa-manager/config.json` →
project `<repo>/.claude/skills/qa-cycle/config.json`.

## Watch the token cost

`skills/qa-cycle/SKILL.md` is the spine and is deliberately small. It was 41.9k tokens
on-invoke; it is now ~16.3k. Check with `plugin details` after editing it, and treat any
rise above that as a regression to justify or undo. Depth belongs in `references/`, which
costs nothing until read.

**The next addition comes out of existing spine text, not out of this number.** It has
been raised twice in one day (15.1k → 16.1k → 16.3k), each time for real new behaviour,
and each raise makes the next one easier to wave through. That is how a budget stops
being one.

The current figure is ~1k above the 15.1k it held for a long time, and that is a
*justified* rise, not drift: Step 3B.5 (the fix-diff review), the Step 3B minor-routing
table and the Step 3D minor-only bullet are new required behaviour, and roughly 2.3k of
pre-existing depth moved out to `references/preflight-internals.md` and
`references/fix-review.md` to pay for them. Per invariant 3 each of those rules kept a
one-line why in the spine; only the measurements moved.
