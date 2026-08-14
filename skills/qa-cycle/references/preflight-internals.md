# Preflight internals

**You normally do not need this file.** `preflight.sh` performs every mechanic below and
emits the result as JSON; the spine tells you which field to read. This is the *policy*
behind those fields — read it when preflight reports something surprising, when you are
changing preflight itself, or when a value's meaning is unclear.

These sections were inline in the skill for a long time, which meant every round paid to
load a description of work a shell script had already done.

## Step 0 — Parse arguments and inspect the MR

> **Mechanics superseded by Step 0.0 preflight** — the resolution below is
> performed by `preflight.sh`; read `base_branch`, `mr_*`, `is_own_branch`,
> etc. from `preflight.json`. The prose is retained as the authoritative
> description of *what* is resolved and *why*. Still parse the reviewer flags
> (`--double`/`--triple`/`--reviewer=`) from argv yourself.

Extract `MR_NUMBER`, `TARGET`, and the optional reviewer flags from the
invocation arguments. `MR_NUMBER` is required. `TARGET` is optional and resolves
to the sole configured target when the project defines exactly one; when it
defines several, ask which one rather than guessing — the config layers merge, so
a `default` entry exists even in a monorepo and would quietly select the repo
root. Record:

- `DOUBLE=true` if `--double` **or** `--triple` appears anywhere in the argv,
  else `DOUBLE=false`. (Triple implies double — a second reviewer always runs
  when a third is requested.)
- `TRIPLE=true` if `--triple` appears anywhere in the argv, else `TRIPLE=false`.
- `REVIEWER_OVERRIDE` captures any `--reviewer=<id>` argument value. Recognized
  ids: `qwen-local` (route the second-opinion reviewer through the legacy local
  LM Studio Qwen path instead of DO). Unrecognized ids must trigger a STOP with
  a clear error.
- Accept both the `=`-joined and space-separated CLI forms — `--reviewer=qwen-local`
  and `--reviewer qwen-local` are equivalent. Reject lone `--reviewer` with no
  value as a STOP: `"--reviewer requires an id (e.g. --reviewer=qwen-local)."`

Also parse two hands-free flags (see Step 3A.1 — they control how the QA
manager's `decisions_needed` are resolved):
- `NON_INTERACTIVE=true` if `--non-interactive` (a.k.a. `--yes`) appears in argv.
  Pre-answers the *defaultable* gates without prompting (skip-contract=No,
  SAST-wait=defer, fixes=report-only, ambiguous contract=highest-confidence or
  BLOCK). A clean, non-approval round then runs fully hands-free.
- `AUTO_APPROVE=true` if `--auto-approve` appears in argv. ONLY this flag lets a
  clean approval-eligible round approve without the Step 3E AskUserQuestion
  confirm. Never implied by `--non-interactive` — approval is a safety invariant.

Documented argument surface:
`<MR_NUMBER> <TARGET> [--double | --triple] [--reviewer=qwen-local] [--non-interactive] [--auto-approve] [--help]`. All flags
are per-invocation — nothing is persisted between rounds; callers must pass the
flags again on subsequent rounds to keep multi-model QA active.

`--help` is handled at Step -1, before preflight runs. The user-facing wording of every
flag above lives in `references/usage.md`; change a flag here and change it there in the
same commit, or the skill documents behaviour it no longer has.

Load the merged config (shipped defaults → user → project, later winning) and look up `targets.<TARGET>`. Resolve `<target-path>`, `<remote>`, and `<scope>` from that entry. If the target is not present, ask the user for the path and offer to add the entry.

Then resolve `<base-branch>` with this precedence:

1. If `.branchconfig.yaml` exists at the repo root:
   a. If `<target-path>` is `.` (the monorepo itself), use the top-level `base_branch:` field of `.branchconfig.yaml`.
   b. Otherwise, look up `submodule_branches.<target-path>.base_branch`. If present, use that value.
2. If neither produced a value, fall back to `targets.<TARGET>.base_branch` from the merged config.

Implementation snippet (the resolver should behave equivalently to this):

```bash
RESOLVED_BASE=""
RESOLVED_SOURCE=""
CONFIG="$(git rev-parse --show-toplevel)/.branchconfig.yaml"
if [[ -f "$CONFIG" ]]; then
  if [[ "$TARGET_PATH" == "." ]]; then
    RESOLVED_BASE=$(awk '/^base_branch:/ { sub(/^base_branch:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[" ]/, ""); print; exit }' "$CONFIG")
  else
    RESOLVED_BASE=$(awk -v t="$TARGET_PATH" '
      /^submodule_branches:/ { in_sub = 1; next }
      in_sub && /^[^[:space:]]/ { in_sub = 0; current = "" }
      # Match any submodule key, then string-compare to t — this avoids
      # treating regex meta-chars in target paths (e.g. ".") as wildcards.
      in_sub && /^  [^[:space:]:].*:[[:space:]]*(#.*)?$/ {
        key = $0
        sub(/^  /, "", key); sub(/:[[:space:]]*(#.*)?$/, "", key)
        current = (key == t) ? t : ""
        next
      }
      in_sub && current == t && /^    base_branch:/ {
        sub(/^    base_branch:[[:space:]]*/, ""); sub(/[[:space:]]*#.*$/, ""); gsub(/[" ]/, "")
        print; exit
      }
    ' "$CONFIG")
  fi
  [[ -n "$RESOLVED_BASE" ]] && RESOLVED_SOURCE=".branchconfig.yaml"
fi
if [[ -z "$RESOLVED_BASE" ]]; then
  # $MERGED_CONFIG is the three-layer merge, written to one temp file before any
  # lookup runs; preflight.sh calls it $BB.
  RESOLVED_BASE=$(jq -r --arg t "$TARGET" '.targets[$t].base_branch' "$MERGED_CONFIG")
  RESOLVED_SOURCE="config fallback"
fi
```

Report which source was used (one line, e.g. `base_branch = main (from .branchconfig.yaml)` or `base_branch = master (from config fallback)`) so the user can confirm the skill picked up the right context.

Navigate into the target directory and fetch the MR details:

```bash
cd <target-path>
glab mr view <MR_NUMBER>
```

Capture: MR title, source branch name, target branch, list of changed files, and current status (open/draft/etc.).

**Determine branch ownership.** Extract the MR author from the `glab mr view` output. Then determine the current user:

```bash
glab auth status 2>&1 | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1
```

This `sed -nE` form is portable across BSD/macOS and GNU sed; the prior PCRE-`\K` invocation was GNU-grep-only and failed on macOS (`grep: invalid option -- P`).

Compare the MR author to the logged-in user. Set `IS_OWN_BRANCH=true` if they match, `IS_OWN_BRANCH=false` otherwise. This controls whether fixes are applied automatically (see Step 3B).

Also get the diff stat to assess scope. Use the MR's **actual target branch** (from `glab mr view`) — not necessarily the config's `base_branch` (report it to the user if they differ, since it may indicate the MR is targeting production patches while the config is set for dev trunk, or vice versa):

```bash
cd <target-path>
git fetch <remote>
git diff <remote>/<target-branch>..<remote>/<feature-branch> --stat 2>/dev/null | tail -5
```

---

## Step 0.25 — Resolve QA agent credentials

Before any QA round runs, resolve credentials for **QA-attributed GitLab actions** (posting round notes, approving the MR). Fix commits and branch syncs continue to use the user's normal `glab`/dev token — only the actions enumerated below use the QA agent token.

1. **Read the names from `preflight.json`, do not re-derive them.** Preflight already
   resolved the merged config; it publishes `qa_token_env`, `qa_token_file` and
   `expected_qa_user`. Take them from there:

   ```bash
   token_env=$(jq -r '.qa_token_env'     "$QA_SCRATCH/preflight.json")
   token_file=$(jq -r '.qa_token_file'   "$QA_SCRATCH/preflight.json")
   expected_username=$(jq -r '.expected_qa_user' "$QA_SCRATCH/preflight.json")
   ```

   Re-merging the config here — or reconstructing the names from memory — can fail
   *open*: a wrong env-var name or token path resolves EMPTY, and an empty token makes
   the forge act as the DEVELOPER. That is how this repo's first live cycle approved an
   MR as its own author (`CASE-STUDIES.md` §self-approval-fallback). A read cannot fail
   that way. The `approval` sub-block still comes from the merged config.

2. **Resolve the token.** First check the env var named by `token_env` (default `QA_AGENT_TOKEN`):

   ```bash
   # Guard against empty/unset token_env — bash ${!var:-} errors with
   # "bad substitution" when var is empty (e.g. user dropped qa_agent.token_env
   # from the merged config to disable env-var lookup).
   QA_TOKEN=""
   if [ -n "$token_env" ]; then
     QA_TOKEN="${!token_env:-}"   # e.g. ${QA_AGENT_TOKEN:-}
   fi
   ```

   If empty, read `token_file` (expand `~`). If the file does not exist or is empty, set `QA_TOKEN_OK=false` and continue:

   ```bash
   if [ -z "$QA_TOKEN" ]; then
     token_path="${token_file/#\~/$HOME}"
     if [ -s "$token_path" ]; then
       QA_TOKEN="$(tr -d '[:space:]' < "$token_path")"
       if [ -z "$QA_TOKEN" ]; then
         echo "warn: $token_path exists but contains no non-whitespace content; treating as no token available." >&2
       fi
     fi
   fi
   ```

3. **Verify the token.** If a token was found, probe identity with the QA token and extract the resolved username with the same pattern Step 0 uses for the dev token.

   The verification probe MUST use the `GITLAB_TOKEN=$QA_TOKEN` env-var-prefix form so it invokes `glab` under the QA agent identity — the same shape `qa_glab()` uses (see step 4 below). Falling back to plain `glab` here resolves the dev token and produces a silent false-negative `QA_TOKEN_OK=false` even when the QA token is valid: `glab auth status` would report the dev user, the `$QA_AUTH_USER != $expected_username` branch would fire, and the skill would then degrade approvals + QA comments to the dev identity for no real reason. The env-var-prefix invocation form is therefore a hard rule, not a stylistic preference.

   ```bash
   if [ -n "$QA_TOKEN" ]; then
     QA_AUTH_USER=$(GITLAB_TOKEN="$QA_TOKEN" glab auth status 2>&1 \
       | sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1)
     if [ -z "$QA_AUTH_USER" ]; then
       echo "warn: QA agent token did not return a username from 'glab auth status'." >&2
       QA_TOKEN_OK=false
     elif [ "$QA_AUTH_USER" != "$expected_username" ]; then
       echo "warn: QA agent token resolved to '$QA_AUTH_USER' (expected '$expected_username'). Falling back to dev token." >&2
       QA_TOKEN_OK=false
     else
       QA_TOKEN_OK=true
     fi
   else
     QA_TOKEN_OK=false
   fi
   ```

   Note: the `sed -nE 's/.*Logged in to [^ ]+ as ([^ ]+).*/\1/p' | head -1` extraction is the same form Step 0 uses for the dev token, so the two probes stay symmetric and portable across BSD/macOS and GNU userspaces. On mismatch, auth failure, or empty `QA_TOKEN`, set `QA_TOKEN_OK=false` and continue — the downstream paths in Step 3C and Step 3E both branch on `QA_TOKEN_OK`.

4. **Helper convention — the forge seam, not a `qa_glab` wrapper.** Every `forge_*`
   function takes the QA token as its LAST argument and applies it internally as an
   env-var prefix (`GITLAB_TOKEN=`/`GH_TOKEN=`), so there is no per-call wrapper to
   define and no token ever appears in a process listing:

   ```bash
   . "${CLAUDE_PLUGIN_ROOT}/lib/forge.sh"
   forge_init "$(git remote get-url "$REMOTE")" "${CLAUDE_PLUGIN_ROOT}/lib"

   forge_post_note "$PROJECT" "$MR_NUMBER" "$note_file" "$QA_TOKEN"   # QA identity
   forge_post_note "$PROJECT" "$MR_NUMBER" "$note_file" ""            # dev identity
   ```

   When `QA_TOKEN_OK=false`, pass an empty token for the comment-posting paths (that
   falls back to the CLI's own credentials) and **skip approval entirely** (Step 3E).

   The earlier design was a `qa_glab() { GITLAB_TOKEN=$QA_TOKEN glab "$@"; }` wrapper.
   It only ever worked on GitLab, and every call site that used it was a site that had
   to be found and rewritten when GitHub support landed. The seam exists so the next
   forge costs one file, not one edit per call site.

5. **Identity scope.** `IS_OWN_BRANCH` detection in Step 0 stays anchored to the **dev
   token's** logged-in user, not the QA agent — call `forge_auth_user` with NO token
   there. The QA agent is never the MR author.

---

## Step 0.4 — Scratch directory

Every `/tmp/...` path the skill writes (contract file, reviewer outputs, SAST report, posted MR notes) MUST live under a per-invocation scratch directory so two concurrent QA rounds cannot clobber each other. Two failure modes this prevents: the same MR number across different repos (e.g. !1085 on `example-org/example-repo` vs `example-org/example-workspace`), and parallel rounds on different MRs that share an output filename.

Define `QA_SCRATCH` once at this step and reference it from every downstream step:

```bash
# Resolve PROJECT here (early) so the scratch-dir hash below includes
# the project disambiguator. Step 2.5 references the same variable without
# recomputation. (Prior versions resolved this only in Step 2.5, which left
# the hash input collapsing to an empty string — defeating cross-project
# disambiguation that Step 0.4 promises.)
PROJECT=$(cd <target-path> && git remote get-url <remote> \
  | sed -E 's,^.*[/:]([^/]+/[^/]+)\.git$,\1,')

# Pick whichever sha256 tool the platform provides (macOS/BSD: shasum -a 256;
# GNU/Linux: sha256sum). Dispatch outside the pipe with literal argv so the
# block is shell-portable: bash splits unquoted parameter expansions on
# whitespace by default, but zsh does NOT (zsh sees `| $CMD |` as a single
# command name including any embedded spaces, e.g. literal "shasum -a 256",
# which fails with "command not found" and silently produces an empty hash —
# defeating the entire purpose of the scratch-dir namespacing).
QA_SCRATCH_INPUT=$(printf '%s|%s|%s' "$(pwd)" "$PROJECT" "$MR_NUMBER")
if command -v shasum >/dev/null 2>&1; then
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | shasum -a 256 | awk '{print $1}' | cut -c1-12)
else
  QA_SCRATCH_HASH=$(printf '%s' "$QA_SCRATCH_INPUT" | sha256sum     | awk '{print $1}' | cut -c1-12)
fi
QA_SCRATCH="/tmp/qa-cycle-${QA_SCRATCH_HASH}-${MR_NUMBER}"
mkdir -p "$QA_SCRATCH"
```

- `PROJECT` is resolved at the top of this block (was previously deferred to Step 2.5). Step 2.5 reuses this same variable without recomputing it.
- `QA_SCRATCH` is per-invocation. A subsequent `/qa-cycle` run on the same MR from the same `cwd` reuses the same dir — that's intentional, so the contract file and earlier round outputs are still discoverable on `--resume`-style flows.
- Treat the directory as ephemeral: nothing depends on its contents persisting beyond the invocation.

Canonical filenames inside `$QA_SCRATCH` (all literal):

| Step | Filename |
|---|---|
| 0.5 | `$QA_SCRATCH/contract.md` |
| 2.5 | `$QA_SCRATCH/sast.md` |
| 3A.2 reviewer 2 | `$QA_SCRATCH/r2-round<N>.md` |
| 3A.2 reviewer 3 | `$QA_SCRATCH/r3-round<N>.md` |
| 3C posted note | `$QA_SCRATCH/note-round<N>.md` |

---

## Step 0.7 — Seed MR_APPROVED from GitLab

`MR_APPROVED` defaults to `false` on every fresh shell, so on a re-invocation
of `/qa-cycle` after a prior round that auto-approved, the skill would otherwise
think the MR is unapproved and never trigger the dirty-reround unapprove flow
(Step 3B.6). Seed it from GitLab here so the state survives across
invocations.

When `QA_TOKEN_OK=true`, query GitLab for the current approval state under
the QA agent identity:

```bash
# URL-encode the project path for the GitLab API (e.g. example-org/example-repo
# → example-org%2Fexample-repo).
PROJECT_ENC=$(printf '%s' "$PROJECT" | sed 's,/,%2F,g')

# Pull every approver username the API surfaces under approval_state. Use
# multiple jq paths with `// empty` so we tolerate the different shapes
# GitLab returns across versions/MR rule configurations:
#   - .rules[].approved_by[].username        (per-rule approvers)
#   - .approved_by[].user.username           (top-level approvers list)
APPROVED_BY=$(qa_glab api "projects/${PROJECT_ENC}/merge_requests/${MR_NUMBER}/approval_state" 2>/dev/null \
  | jq -r '
      [ (.rules[]?.approved_by[]?.username // empty),
        (.approved_by[]?.user.username // empty) ]
      | .[]
    ' 2>/dev/null | sort -u)

if printf '%s\n' "$APPROVED_BY" | grep -qx "$QA_AUTH_USER"; then
  MR_APPROVED=true
else
  MR_APPROVED=false
fi
```

When `QA_TOKEN_OK=false`, the QA agent identity is unavailable so the
unapprove flow is disabled regardless — keep `MR_APPROVED=false` and skip the
query:

```bash
if [ "$QA_TOKEN_OK" != "true" ]; then
  MR_APPROVED=false
fi
```

This makes the dirty-reround unapprove gate in Step 3B.6 actually fire when
a prior `/qa-cycle` invocation (or even an out-of-band approval by the QA agent
via the GitLab UI) left the MR in an approved state.

---

## Step 2 — Sync the feature branch with the base branch

This is mandatory before any QA round. A branch that is behind its base produces false findings.

```bash
cd <target-path>
git fetch <remote>
git checkout <feature-branch>
git merge <remote>/<target-branch> --no-edit
git push <remote> <feature-branch>
```

After pushing, verify the resulting diff is limited to intended changes:

```bash
cd <target-path>
git diff <remote>/<target-branch>..HEAD --stat
```

Report the diff stat to the user. If the diff contains unintended deletions or reversions after syncing, warn: *"The branch may have been cut from a stale base. Consider rebuilding from the current base tip."* Ask the user to confirm before proceeding.

---
