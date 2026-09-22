#!/usr/bin/env bash
# Other repositories take this file through the vendoring cascade (references/bump-cascade.md
# in https://github.com/rokokol/ci-skill). Nobody edits a copy in place.
# Needs bash 3.2 and POSIX tools only for its own code, so a macOS runner runs it unchanged.
# It needs git for the second revision, nix to evaluate both, and jq to read what nix prints.
# nix-diff is optional: without it a move is still reported, and only the explanation is
# missing.
# A worktree carries the other revision, never `git stash`: a stash that an interrupted run
# leaves behind takes the user's work with it
set -euo pipefail

usage() {
  cat <<'EOF'
drv-diff.sh — does this change alter what gets built, or only how it reads

Every output of the flake is evaluated twice, here and at another revision, and the two
derivation paths are compared. A refactor that changed nothing leaves every one of them
alone. One that moved a path did something, whether or not that was the intent.
Naming one output by hand answers a narrower question than the one usually asked: what
moves is rarely the output somebody thought to name

  drv-diff.sh [-C DIR] [-r REV] [ATTR...]
  drv-diff.sh --list [-C DIR]

  -C DIR       the repository. It defaults to the git toplevel of the working directory
  -r REV       what to compare against, as git spells it (default: HEAD)
  ATTR...      compare these outputs instead of every one this finds, each as
               `nix eval` spells it after the `#`
  --list       print the outputs this would compare, and exit

The outputs it finds by itself: packages, checks and devShells for this system, the
formatter, and the toplevel of every nixosConfigurations entry

Environment: DRV_DIFF_NESTED=1 runs the comparison and skips the self-test. A gate that
calls this more than once uses it, so one copy is not proven twice
Nothing here reaches the network beyond what evaluating the flake already does
Exit 0 when every derivation is where it was, 1 when one moved, 2 on a usage error, a
missing tool, an untracked Nix file or nothing to compare
EOF
}

# There is no fail(): a moved derivation is not a message, it is the row that says MOVED and
# the count in the summary. Exit 1 carries it
die() { # the request itself is wrong
  printf 'drv-diff: %s\n' "$1" >&2
  exit 2
}

self=$0
root=""
rev="HEAD"
list_only=0
attrs=()

while (($#)); do
  case "$1" in
    -C)
      (($# >= 2)) || die "-C needs a directory"
      root="$2"
      shift 2
      ;;
    -r)
      (($# >= 2)) || die "-r needs a revision"
      rev="$2"
      shift 2
      ;;
    --list)
      list_only=1
      shift
      ;;
    -h | --help | help)
      usage
      exit 0
      ;;
    -*) die "no such flag: $1" ;;
    *)
      attrs+=("$1")
      shift
      ;;
  esac
done

for t in nix git jq; do
  command -v "$t" >/dev/null 2>&1 || die "needs $t"
done

if [[ -z "$root" ]]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null) ||
    die "not inside a git repository, and the other revision comes from git — give -C DIR"
fi
root=$(cd -- "$root" 2>/dev/null && pwd) || die "no such directory: $root"
[[ -r "$root/flake.nix" ]] || die "$root holds no flake.nix — there is nothing to evaluate"
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || die "$root is not a git repository"
git -C "$root" rev-parse --verify --quiet "$rev^{commit}" >/dev/null ||
  die "$rev is not a commit in $root"

# A flake reads the files git tracks, and an untracked one is invisible to it. So a run with
# one present would compare two trees that both lack the change, and answer "nothing moved"
# about an edit it never saw. Measured: `git add -N` is enough to make the file visible
untracked=$(git -C "$root" ls-files --others --exclude-standard -- '*.nix')
if [[ -n "$untracked" ]]; then
  printf 'drv-diff: these Nix files are untracked, so the flake cannot see them:\n' >&2
  # A herestring rather than a pipe: head would stop early and kill git with SIGPIPE, and
  # pipefail would make that the status of a line that did exactly what it meant to
  awk 'NR <= 5 { print "  " $0 } END { if (NR > 5) printf "  …and %d more\n", NR - 5 }' \
    <<<"$untracked" >&2
  die "git add -N is enough to make them visible, and it stages no content"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/drv-diff.XXXXXX")
trap 'rm -rf "$work"; git -C "$root" worktree prune >/dev/null 2>&1 || :' EXIT

system=$(nix config show system 2>/dev/null) || system=""
[[ -n "$system" ]] || die "nix could not say what system this is"

# One TSV of `attr<TAB>drvPath` for a whole tree. Each category is asked separately, so a
# flake that has none of one kind is not an error and says nothing.
# --no-write-lock-file throughout: a comparison must not change the lock it is comparing
drvs() { # drvs DIR -> attr<TAB>drvPath, one per line
  local d="$1" out=""
  local kind
  for kind in packages checks devShells; do
    out="$out$(
      nix eval --no-write-lock-file --json "$d#$kind.$system" \
        --apply 'xs: builtins.mapAttrs (_: x: x.drvPath) xs' 2>/dev/null |
        jq -r --arg k "$kind.$system" 'to_entries[] | "\($k).\(.key)\t\(.value)"' || :
    )"$'\n'
  done
  out="$out$(
    nix eval --no-write-lock-file --json "$d#nixosConfigurations" \
      --apply 'cs: builtins.mapAttrs (_: c: c.config.system.build.toplevel.drvPath) cs' 2>/dev/null |
      jq -r 'to_entries[] | "nixosConfigurations.\(.key).toplevel\t\(.value)"' || :
  )"$'\n'
  out="$out$(
    nix eval --no-write-lock-file --raw "$d#formatter.$system.drvPath" 2>/dev/null |
      sed "s|^|formatter.$system\t|" || :
  )"$'\n'
  printf '%s\n' "$out" | grep -v '^$' | LC_ALL=C sort || :
}

# The named outputs instead, in the same shape. A name that does not evaluate is a usage
# error rather than a silent gap: the user spelled it, so the user has to hear about it
named_drvs() { # named_drvs DIR ATTR... -> attr<TAB>drvPath
  local d="$1" a p
  shift
  for a in "$@"; do
    p=$(nix eval --no-write-lock-file --raw "$d#$a.drvPath" 2>/dev/null) ||
      die "$d#$a has no drvPath — name an output that is a derivation"
    printf '%s\t%s\n' "$a" "$p"
  done
}

rows_for() { # rows_for DIR
  if ((${#attrs[@]})); then
    named_drvs "$1" "${attrs[@]}"
  else
    drvs "$1"
  fi
}

rows_for "$root" >"$work/after"
[[ -s "$work/after" ]] ||
  die "no output of this flake is a derivation — there is nothing to compare"

if ((list_only)); then
  cut -f1 "$work/after"
  exit 0
fi

# The other revision in a worktree of its own. `git stash` would move the user's work into a
# stash an interrupted run then leaves behind; a worktree touches nothing they can see
before="$work/before-tree"
git -C "$root" worktree add -q --detach "$before" "$rev" ||
  die "could not check out $rev into a worktree"
rows_for "$before" >"$work/before"
git -C "$root" worktree remove --force "$before" >/dev/null 2>&1 || :

moved=0
gone=0
appeared=0
summary_rows=""
while IFS=$'\t' read -r attr path; do
  [[ -n "$attr" ]] || continue
  was=$(awk -F'\t' -v a="$attr" '$1 == a { print $2; exit }' "$work/before")
  if [[ -z "$was" ]]; then
    appeared=$((appeared + 1))
    summary_rows="$summary_rows"$'\n'"  new      $attr"
  elif [[ "$was" == "$path" ]]; then
    summary_rows="$summary_rows"$'\n'"  same     $attr"
  else
    moved=$((moved + 1))
    summary_rows="$summary_rows"$'\n'"  MOVED    $attr"
    printf '%s\t%s\t%s\n' "$attr" "$was" "$path" >>"$work/moved"
  fi
done <"$work/after"

while IFS=$'\t' read -r attr _; do
  [[ -n "$attr" ]] || continue
  awk -F'\t' -v a="$attr" '$1 == a { found = 1 } END { exit !found }' "$work/after" || {
    gone=$((gone + 1))
    summary_rows="$summary_rows"$'\n'"  gone     $attr"
  }
done <"$work/before"

printf '%s\n' "$summary_rows" | grep -v '^[[:space:]]*$' || :

# The explanation, where a tool for it is on PATH. Without one the move is still reported:
# the answer to "did anything change" does not depend on being able to say why
if [[ -s "$work/moved" ]] && command -v nix-diff >/dev/null 2>&1; then
  while IFS=$'\t' read -r attr was now; do
    printf '\n== %s\n' "$attr" >&2
    # To a file first, then the head of it: a pipe into head kills nix-diff with SIGPIPE.
    # Twelve lines, because a derivation whose source text moved makes nix-diff print that
    # text, and the whole of a script is not an explanation of anything
    nix-diff "$was" "$now" >"$work/explain" 2>&1 || :
    awk -v cmd="nix-diff $was $now" '
      NR <= 12 { print }
      END { if (NR > 12) printf "  …%d more lines: %s\n", NR - 12, cmd }
    ' "$work/explain" >&2
  done <"$work/moved"
elif [[ -s "$work/moved" ]]; then
  printf '\ndrv-diff: nix-diff is not on PATH, so only the move is reported and not its cause\n' >&2
fi

total=$(wc -l <"$work/after" | tr -d ' ')
summary="drv-diff: $total output(s) against $rev; $moved moved"
((appeared == 0)) || summary="$summary, $appeared new"
((gone == 0)) || summary="$summary, $gone gone"

# ---- falsification ----------------------------------------------------------------------
# The comparison is shown able to answer both ways on this run. A tool that only ever says
# "same" is the one shape this cannot be allowed to have: it is the answer people want
self_test() {
  local t="$work/self" planted=0
  mkdir -p "$t"
  # The system is spelled in, rather than substituted afterwards: `sed -i` takes a suffix on
  # the BSD userland and none on GNU, and this file claims POSIX tools only
  cat >"$t/flake.nix" <<FLAKE
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  outputs =
    { nixpkgs, ... }:
    {
      packages.$system.default =
        nixpkgs.legacyPackages.$system.runCommand "drv-diff-probe" { } "echo one >\$out";
    };
}
FLAKE
  # The lock this repository already holds, so the probe fetches nothing
  cp "$root/flake.lock" "$t/flake.lock" 2>/dev/null || :
  git -C "$t" init -q
  git -C "$t" add -A
  git -C "$t" -c user.email=d@d -c user.name=d commit -qm probe

  # A comment is not a derivation. This must report no move, or the tool answers "changed"
  # to every edit and stops meaning anything
  printf '# a comment, and nothing else\n' >>"$t/flake.nix"
  git -C "$t" add -A
  local out status=0
  out=$(DRV_DIFF_NESTED=1 "$BASH" "$self" -C "$t" 2>&1) || status=$?
  ((status == 0)) ||
    die "self-test: a comment was reported as a change (exit $status): $out"
  planted=$((planted + 1))

  # …and a changed builder is a move. Without this half the tool could answer "same" always
  sed 's/echo one/echo two/' "$t/flake.nix" >"$t/next" && mv "$t/next" "$t/flake.nix"
  git -C "$t" add -A
  status=0
  out=$(DRV_DIFF_NESTED=1 "$BASH" "$self" -C "$t" 2>&1) || status=$?
  ((status == 1)) ||
    die "self-test: a changed builder was not reported as a move (exit $status): $out"
  case "$out" in
    *"MOVED"*) ;;
    *) die "self-test: a moved derivation was not named as moved: $out" ;;
  esac
  planted=$((planted + 1))

  summary="$summary; $planted planted changes caught"
}

[[ -n "${DRV_DIFF_NESTED:-}" ]] || self_test

printf '%s\n' "$summary" >&2
((moved == 0)) || exit 1
exit 0
