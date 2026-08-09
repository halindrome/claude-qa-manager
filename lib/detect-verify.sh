#!/usr/bin/env bash
# detect-verify.sh — discover a project's OWN test/build entry point.
#
# Usage:  detect-verify.sh <dir>
# Output: one JSON object on stdout:
#   {"state":"detected|none-found","command":"…","source":"…","build_command":"…","build_source":"…"}
#
# WHY DISCOVERY AND NOT CONFIGURATION. Any project worth QA-ing already declares
# how it is tested — a Makefile target, an npm script, a tox env. Restating that
# in this plugin's config would duplicate it, and a duplicate drifts: the QA gate
# would keep running a command the project stopped using, and report a pass. So
# the project's own rules are the source of truth and this only finds them. A
# `verify.command` override exists for the case where detection is wrong, but it
# is empty by default and is not the intended path.
#
# TWO RULES LEARNED FROM REAL REPOS, both violated by the obvious implementation:
#
#   1. A manifest's PRESENCE proves nothing. One real submodule ships a
#      package.json whose `scripts` object is empty, while its Makefile carries
#      the real `test:` target. "package.json exists -> npm test" would emit a
#      command that always fails. Every detector below tests for the ACTUAL
#      entry, and a detector that does not find one FALLS THROUGH to the next.
#   2. Finding nothing is a result, not a blank. It returns state=none-found so
#      the caller must say so out loud. A project with no discoverable tests is
#      exactly the project whose QA fixes go unverified — silence there is how an
#      absent check gets read as a passing one.
set -uo pipefail

DIR="${1:-}"
[ -n "$DIR" ] && [ -d "$DIR" ] || { printf '{"state":"none-found","command":"","source":"","build_command":"","build_source":""}\n'; exit 0; }

CMD=""; SRC=""; BUILD=""; BUILD_SRC=""

has_make_target() {  # $1 = makefile, $2 = target
  grep -qE "^$2:" "$1" 2>/dev/null
}
json_script() {      # $1 = json file, $2 = script name -> non-empty if present
  jq -r --arg s "$2" '.scripts[$s] // "" | select(. != "")' "$1" 2>/dev/null
}
# Package manager follows the lockfile, not preference: running `npm test` in a
# pnpm workspace resolves a different tree than CI uses.
node_pm() {
  if   [ -f "$DIR/pnpm-lock.yaml" ]; then echo pnpm
  elif [ -f "$DIR/yarn.lock" ];      then echo yarn
  elif [ -f "$DIR/bun.lockb" ];      then echo bun
  else echo npm; fi
}

MK=""
for m in Makefile makefile GNUmakefile; do [ -f "$DIR/$m" ] && { MK="$DIR/$m"; break; }; done

# --- test entry point, first match wins, each verified to actually exist ------
if [ -n "$MK" ] && has_make_target "$MK" test; then
  CMD="make test"; SRC="$(basename "$MK") (test target)"
elif [ -f "$DIR/package.json" ] && [ -n "$(json_script "$DIR/package.json" test)" ]; then
  pm="$(node_pm)"; CMD="$pm test"; SRC="package.json (scripts.test)"
elif [ -f "$DIR/Taskfile.yml" ] && grep -qE '^[[:space:]]+test:' "$DIR/Taskfile.yml" 2>/dev/null; then
  CMD="task test"; SRC="Taskfile.yml"
elif [ -f "$DIR/justfile" ] && grep -qE '^test:' "$DIR/justfile" 2>/dev/null; then
  CMD="just test"; SRC="justfile"
elif [ -f "$DIR/tox.ini" ]; then
  CMD="tox"; SRC="tox.ini"
elif [ -f "$DIR/pyproject.toml" ] && grep -q '\[tool.poetry\]' "$DIR/pyproject.toml" 2>/dev/null; then
  CMD="poetry run pytest"; SRC="pyproject.toml (poetry)"
elif [ -f "$DIR/pytest.ini" ] || { [ -f "$DIR/pyproject.toml" ] && grep -q '\[tool.pytest' "$DIR/pyproject.toml" 2>/dev/null; } \
     || { [ -f "$DIR/setup.cfg" ] && grep -q '\[tool:pytest\]' "$DIR/setup.cfg" 2>/dev/null; }; then
  CMD="pytest"; SRC="pytest configuration"
elif [ -f "$DIR/Cargo.toml" ]; then
  CMD="cargo test"; SRC="Cargo.toml"
elif [ -f "$DIR/go.mod" ]; then
  CMD="go test ./..."; SRC="go.mod"
elif [ -f "$DIR/pom.xml" ]; then
  CMD="mvn -q test"; SRC="pom.xml"
elif [ -f "$DIR/build.gradle" ] || [ -f "$DIR/build.gradle.kts" ]; then
  if [ -x "$DIR/gradlew" ]; then CMD="./gradlew test"; else CMD="gradle test"; fi
  SRC="build.gradle"
elif [ -f "$DIR/composer.json" ] && [ -n "$(json_script "$DIR/composer.json" test)" ]; then
  CMD="composer test"; SRC="composer.json (scripts.test)"
elif [ -d "$DIR/molecule" ]; then
  CMD="molecule test"; SRC="molecule/"
# An Ansible repo with no molecule/ still has a real gate, and missing it is not
# harmless: one such repo reported state=none-found on EVERY round while its CI ran
# yamllint, ansible-lint, syntax-check and a playbook assert job — so Step 3B's
# "run the project's own checks" was nominally unsatisfied every time, and the
# session hand-rolled ansible-lint 516 times and yamllint 323 times instead, none
# of it recorded as verify evidence in a note.
#
# Gated on the LINT CONFIG, not on ansible.cfg. Rule 1 at the top of this file:
# presence must prove the entry point exists. Every Ansible repo has an
# ansible.cfg whether or not anything lints it, so keying on that would emit a
# command for repos that never run it. `.ansible-lint` IS the declaration.
#
# `--offline` because a QA gate must be deterministic: without it ansible-lint
# fetches galaxy dependencies, so the check's outcome depends on the network. It
# also matches what the CI of the repo this came from actually runs.
elif [ -f "$DIR/.ansible-lint" ] || [ -f "$DIR/.ansible-lint.yml" ] || [ -f "$DIR/.ansible-lint.yaml" ]; then
  CMD="ansible-lint --offline"; SRC=".ansible-lint"
fi
# NOT derived: a playbook-level test job (e.g. `ansible-playbook -i tests/inventory.ini
# tests/assert-logic.yml`). The invocation is repo-specific — inventory path, limits,
# extra vars — and rule 1 forbids emitting a command that would always fail. That case
# is what `targets.<name>.verify.command` is for.

# --- build entry point (optional; a compile error is a defect a test may miss) -
if [ -n "$MK" ] && has_make_target "$MK" build; then
  BUILD="make build"; BUILD_SRC="$(basename "$MK") (build target)"
elif [ -f "$DIR/package.json" ] && [ -n "$(json_script "$DIR/package.json" build)" ]; then
  BUILD="$(node_pm) run build"; BUILD_SRC="package.json (scripts.build)"
elif [ -f "$DIR/Cargo.toml" ]; then
  BUILD="cargo build"; BUILD_SRC="Cargo.toml"
elif [ -f "$DIR/go.mod" ]; then
  BUILD="go build ./..."; BUILD_SRC="go.mod"
# yamllint is the build-side twin of the ansible-lint gate above: a separate CI job
# in practice, catching what a lint of Ansible semantics does not (indentation, key
# duplication, truthy spellings). Keyed on its own config for the same reason.
elif [ -f "$DIR/.yamllint" ] || [ -f "$DIR/.yamllint.yml" ] || [ -f "$DIR/.yamllint.yaml" ]; then
  BUILD="yamllint ."; BUILD_SRC=".yamllint"
fi

STATE="none-found"; [ -n "$CMD" ] && STATE="detected"
jq -n --arg s "$STATE" --arg c "$CMD" --arg src "$SRC" --arg b "$BUILD" --arg bsrc "$BUILD_SRC" \
  '{state:$s, command:$c, source:$src, build_command:$b, build_source:$bsrc}'
