#!/usr/bin/env bash
# A check that has never failed is a decoration, and this skill hands its checker to other
# repositories
# Needs bash 3.2 and POSIX tools only for its own code, plus git for the vendoring check
# and for the fixture that proves an unstaged file is still seen; both halves call the
# flake's dev shell for their tools — shellcheck and shfmt for what the repository ships,
# nixfmt, statix, deadnix, jq and nix-instantiate for what check-nix.sh reads
set -euo pipefail

usage() {
  cat <<'EOF'
check.sh — the gate for this repository: lint what the skill ships, hold it to its own
rules, and prove that check-nix.sh can actually go red

  check.sh [lint|behaviour|all]

Two halves, because they ask different questions. lint reads what the skill ships —
its two scripts, its flake, its documents — and holds the scripts to the shell standard
through check-sh.sh. behaviour runs check-nix.sh against throwaway fixtures and requires
it to reject each one for that fixture's own defect. all, the default, is both

  nix develop -c ./check.sh

Unlike the shell standard's gate, neither half runs without the dev shell: check-nix.sh
reads Nix with nixfmt, statix and deadnix, and a machine without them is refused rather
than checked with less. What a bare bash can still prove about this repository is that
check-nix.sh parses under the 3.2 it claims, which is a workflow's job and not this one's

Environment: CHECK_NIX_NESTED=1 is set for every call after the first, so the checker's
own falsification pass runs once rather than once per call
Nothing here touches the network, so it is safe on pull requests
Exit 0 when everything holds, 1 on a failure or an unknown mode
EOF
}

fail() {
  printf 'check: %s\n' "$1" >&2
  exit 1
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

# The scripts this repository owns, as opposed to the ones it vendors: a vendored copy is
# its source's business and is held here only to being byte-equal to it
own_scripts=(check-nix.sh check.sh)

mode="${1:-all}"
case "$mode" in
  lint | behaviour | all) ;;
  -h | --help | help)
    usage
    exit 0
    ;;
  *) fail "no such mode: '$mode' — lint, behaviour or all" ;;
esac

tools=(nixfmt statix deadnix jq nix-instantiate)
[[ "$mode" == behaviour ]] || tools+=(shellcheck shfmt)
missing=()
for tool in "${tools[@]}"; do
  command -v "$tool" >/dev/null || missing+=("$tool")
done
((${#missing[@]} == 0)) ||
  fail "missing: ${missing[*]} — they are pinned in the flake, so run this as: nix develop -c ./check.sh"

work=$(mktemp -d "${TMPDIR:-/tmp}/check.XXXXXX")
trap 'rm -rf "$work"' EXIT

check_lint() {
  echo "== the vendored copies are still their sources'"
  ./vendor-sync.sh check

  echo "== the scripts parse and lint"
  shellcheck "${own_scripts[@]}"
  shfmt -d -i 2 -ci "${own_scripts[@]}"

  echo "== the scripts hold to the shell standard"
  # The first call keeps check-sh.sh's own falsification pass; there is only one here, so
  # nothing to skip, but the variable is set for the calls behaviour makes below
  ./check-sh.sh check-nix.sh
  CHECK_SH_NESTED=1 ./check-sh.sh check.sh

  echo "== the repository's own Nix holds to the standard it ships"
  ./check-nix.sh
}

check_behaviour() {
  echo "== the checker rejects a defect it has never seen"
  # The falsification inside check-nix.sh plants into fixtures the checker itself prints.
  # This half asks the other question: given a tree it did not build, does it still refuse?
  # A fixture written here is the one thing that pass cannot cover
  local d="$work/tree"
  mkdir -p "$d"
  ./check-nix.sh --template module >"$d/module.nix"

  CHECK_NIX_NESTED=1 ./check-nix.sh -C "$d" ||
    fail "a tree of nothing but the canonical module was rejected"

  printf '{ notFormatted  =  1; }\n' >"$d/ugly.nix"
  if CHECK_NIX_NESTED=1 ./check-nix.sh -C "$d" >"$work/out" 2>&1; then
    fail "a tree holding an unformatted file passed"
  fi
  grep -q 'not formatted by nixfmt' "$work/out" ||
    fail "an unformatted file was rejected for the wrong reason: $(cat "$work/out")"

  echo "== a file written but not yet staged is still checked"
  # Found by breaking this on purpose: with a bare `git ls-files` a new module is invisible
  # until it is staged, so it passes here and fails in CI, where the same file is tracked.
  # The fixture is a git repository on purpose — without one the walk is find, which never
  # had the blind spot and would prove nothing
  local repo="$work/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  ./check-nix.sh --template module >"$repo/module.nix"
  git -C "$repo" add module.nix
  printf '{  unstaged  =  1; }\n' >"$repo/unstaged.nix"
  if CHECK_NIX_NESTED=1 ./check-nix.sh -C "$repo" >"$work/out" 2>&1; then
    fail "an unformatted file that was never staged passed — the walk cannot see it"
  fi
  grep -q 'unstaged.nix is not formatted' "$work/out" ||
    fail "the unstaged file was not the one named: $(cat "$work/out")"

  echo "== the checker refuses a directory with no Nix in it"
  local empty="$work/empty"
  mkdir -p "$empty"
  local status=0
  CHECK_NIX_NESTED=1 ./check-nix.sh -C "$empty" >"$work/out" 2>&1 || status=$?
  ((status == 2)) ||
    fail "a directory with no .nix file was not refused with exit 2 (got $status)"
}

case "$mode" in
  lint) check_lint ;;
  behaviour) check_behaviour ;;
  all)
    check_lint
    check_behaviour
    ;;
esac

echo "== all good"
