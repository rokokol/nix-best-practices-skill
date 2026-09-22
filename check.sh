#!/usr/bin/env bash
# A check that has never failed is a decoration, and this skill hands its checker to other
# repositories.
# Needs bash 3.2 and POSIX tools only for its own code.
# It also needs git for the vendoring check and for one fixture.
# It needs nix to run the same rules through the flake's checks output.
# Both halves take their tools from the flake's dev shell.
# What the repository ships goes to shellcheck and shfmt.
# What check-nix.sh reads goes to nixfmt, statix, deadnix, jq and nix-instantiate
set -euo pipefail

usage() {
  cat <<'EOF'
check.sh — the gate for this repository: lint what the skill ships, hold it to its own
rules, and prove that check-nix.sh can actually go red

  check.sh [lint|behaviour|all]

Two halves, because they ask different questions.
lint reads what the skill ships: its scripts, its flake and its documents.
It holds the scripts to the shell standard through check-sh.sh.
behaviour runs check-nix.sh against throwaway fixtures.
Each fixture must be rejected for its own defect.
all is both, and it is the default

  nix develop -c ./check.sh

Neither half runs without the dev shell.
check-nix.sh reads Nix with nixfmt, statix and deadnix.
This gate refuses a machine without them; it does not check less.
A bare bash can still prove that check-nix.sh parses under the 3.2 it claims.
That proof belongs to a workflow, not to this script

Environment: CHECK_NIX_NESTED=1 is set for every call after the first, so the checker's
own falsification pass runs once rather than once per call
One step reaches outside this machine: the nix flake check that builds the consumer's seam.
It substitutes from the binary cache, as any Nix build does.
Nothing fetches a source. Nothing writes outside a temporary directory
Exit 0 when everything holds, 1 on a failure or an unknown mode
EOF
}

fail() {
  printf 'check: %s\n' "$1" >&2
  exit 1
}

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

# The scripts this repository owns, as opposed to the ones it vendors.
# A vendored copy belongs to its source.
# This repository holds it to one thing: it must stay byte-equal to that source
own_scripts=(check-nix.sh check.sh drv-diff.sh tests/defects.sh)

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
  # The first call keeps check-sh.sh's own falsification pass.
  # Only one call happens here, so nothing needs to skip it.
  # The variable is still set, for the calls the behaviour half makes below
  ./check-sh.sh check-nix.sh
  CHECK_SH_NESTED=1 ./check-sh.sh check.sh
  CHECK_SH_NESTED=1 ./check-sh.sh drv-diff.sh

  echo "== the skill itself holds to the rules for a skill"
  ./check-skill.sh -n nix-best-practices .

  echo "== every document keeps the house rules a script can decide"
  # One paragraph on one physical line, no trailing full stop, plain quotes, and an
  # admonition in the shape GitHub renders as a box
  ./check-prose.sh README.md CHANGELOG.md SKILL.md references/*.md

  echo "== the changelog is dated, as a repository with no version's must be"
  # -n rather than a VERSION file: a skill is read at whatever revision is checked out,
  # so it has no version to be wrong about and `Unreleased` is a state it never leaves
  ./check-changelog.sh -n CHANGELOG.md

  echo "== the repository's own Nix holds to the standard it ships"
  ./check-nix.sh

  echo "== and holds to it the way a consumer gets it, inside the sandbox"
  # The same rules through checks.<system>.nix-lint.
  # That sandbox has no network, no store and no repository.
  # Every consumer runs this shape, so a seam that fails only there must fail here first.
  # Not --offline: that flag forbids substitution.
  # The first change to this derivation then builds the world from source, as it once did
  CHECK_NIX_NESTED=1 nix flake check --no-write-lock-file
}

check_behaviour() {
  echo "== the checker rejects a defect it has never seen"
  # The falsification inside check-nix.sh plants into fixtures the checker itself prints.
  # This half asks the other question.
  # Given a tree it did not build, does the checker still refuse?
  # A fixture written here is the one thing that pass cannot cover
  local d="$work/tree"
  mkdir -p "$d"
  ./check-nix.sh --template module >"$d/module.nix"

  CHECK_NIX_NESTED=1 ./check-nix.sh -N example -C "$d" ||
    fail "a tree of nothing but the canonical module was rejected"

  printf '{ notFormatted  =  1; }\n' >"$d/ugly.nix"
  if CHECK_NIX_NESTED=1 ./check-nix.sh -N example -C "$d" >"$work/out" 2>&1; then
    fail "a tree holding an unformatted file passed"
  fi
  grep -q 'not formatted by nixfmt' "$work/out" ||
    fail "an unformatted file was rejected for the wrong reason: $(cat "$work/out")"

  echo "== a file written but not yet staged is still checked"
  # A defect found this by breaking it on purpose.
  # With a bare `git ls-files` a new module stays invisible until someone stages it.
  # It then passes here and fails in CI, where the same file is tracked.
  # The fixture is a git repository on purpose.
  # Without one the walk uses find, which never had the blind spot
  local repo="$work/repo"
  mkdir -p "$repo"
  git -C "$repo" init -q
  ./check-nix.sh --template module >"$repo/module.nix"
  git -C "$repo" add module.nix
  printf '{  unstaged  =  1; }\n' >"$repo/unstaged.nix"
  if CHECK_NIX_NESTED=1 ./check-nix.sh -N example -C "$repo" >"$work/out" 2>&1; then
    fail "an unformatted file that was never staged passed — the walk cannot see it"
  fi
  grep -q 'unstaged.nix is not formatted' "$work/out" ||
    fail "the unstaged file was not the one named: $(cat "$work/out")"

  echo "== a copy whose PATH is pinned says which plant it could not take"
  # A wrapper pins the tools beside the script and exports PATH from inside it. The plant
  # that takes a tool away then cannot reach the nested run, so it steps aside.
  # A run that checks less must say so, and this is the sentence that says it
  local wrapped="$work/wrapped.sh"
  {
    head -n 1 check-nix.sh
    printf 'export PATH="%s"\n' "$PATH"
    tail -n +2 check-nix.sh
  } >"$wrapped"
  chmod +x "$wrapped"
  bash "$wrapped" -N example -C "$d" >"$work/out" 2>&1 || :
  grep -q 'pins its own PATH' "$work/out" ||
    fail "a copy with a pinned PATH did not say the missing-tool plant was left out: $(cat "$work/out")"
  # …and an ordinary copy does take that plant, so the sentence is not there.
  # Without this half, a guard that always steps aside reads the same as one that never does
  ./check-nix.sh -N example -C "$d" >"$work/out" 2>&1 || :
  if grep -q 'pins its own PATH' "$work/out"; then
    fail "an ordinary copy claimed its PATH was pinned, so five plants were left out for nothing"
  fi

  echo "== drv-diff answers both ways, and refuses what it cannot see"
  # Its own falsification plants a comment, which must not move anything, and a changed
  # builder, which must. So one clean run here exercises both: the self-test dies otherwise.
  # The fixture carries this repository's lock, so the probe fetches nothing
  local probe="$work/probe"
  mkdir -p "$probe"
  local sys
  sys=$(nix config show system)
  cat >"$probe/flake.nix" <<EOF
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { nixpkgs, ... }:
    {
      packages.$sys.default =
        nixpkgs.legacyPackages.$sys.runCommand "probe" { } "echo hello >\$out";
    };
}
EOF
  cp flake.lock "$probe/flake.lock"
  git -C "$probe" init -q
  git -C "$probe" add -A
  git -C "$probe" -c user.email=d@d -c user.name=d commit -qm probe
  ./drv-diff.sh -C "$probe" >"$work/out" 2>&1 ||
    fail "drv-diff called an unchanged tree changed: $(cat "$work/out")"
  grep -q 'planted changes caught' "$work/out" ||
    fail "drv-diff ran without its own falsification: $(cat "$work/out")"

  # A file the flake cannot see must stop the run. Answering "nothing moved" about an edit
  # nobody staged is the one wrong answer that reads as good news
  printf '_: { }\n' >"$probe/unstaged.nix"
  status=0
  DRV_DIFF_NESTED=1 ./drv-diff.sh -C "$probe" >"$work/out" 2>&1 || status=$?
  ((status == 2)) ||
    fail "drv-diff compared a tree holding an untracked .nix file (exit $status)"
  grep -q 'untracked' "$work/out" ||
    fail "drv-diff refused the untracked file without naming why: $(cat "$work/out")"
  rm -f "$probe/unstaged.nix"

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
