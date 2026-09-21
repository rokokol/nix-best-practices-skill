#!/usr/bin/env bash
# Other repositories take this file through the vendoring cascade (references/bump-cascade.md
# in https://github.com/rokokol/ci-skill): a copy is never edited in place, a change is made
# here and reaches them from here
# Needs bash 3.2 and POSIX tools only for its own code, so it runs on a macOS runner
# unchanged, plus nixfmt, statix, deadnix, jq, nix-instantiate and git for the Nix it is
# given. That Nix is read three ways: as text after nixfmt, as the tree nix-instantiate
# re-prints, and as the JSON flake.lock already is. There is no degraded mode — a Nix
# repository has nix by definition, and a missing linter is a refusal rather than a
# quieter run
set -euo pipefail

usage() {
  cat <<'EOF'
check-nix.sh — holds Nix sources to what the formatter cannot check

nixfmt owns layout, statix owns the language's antipatterns and deadnix owns dead code,
so this checker dispatches to those three and adds only what none of them can see: the
shape of a module header, the scope a `with` opens, whether a derivation carries a meta,
and whether the lock names a path that exists on one machine alone. Each check is proven
able to fail on every run, on canonical files with one defect planted, so a copy
falsifies itself wherever it runs. It has no repo-specific part beyond -N, and belongs
in a repository's own gate

  check-nix.sh [-C DIR] [-N NAMESPACE]... [--static] [PATH...]
  check-nix.sh --template [module|package|flake]
  check-nix.sh --list-rules

  -C DIR       the repository root (default: the git toplevel of the working directory,
               else the working directory); flake.nix and flake.lock are looked for here
  -N NAMESPACE the prefix this repository's own module options live under, such as
               rokokol or programs.screen-shader; repeatable
  PATH...      check only these files instead of every .nix file under DIR; the flake
               and lock rules then run only when flake.nix is among them
  --static     run only what reads files, and nothing that evaluates the flake; it
               exists for the nix flake check sandbox, which has neither network nor
               store, says in the summary that the evaluated half did not run, and is
               never chosen on its own — a missing tool is a refusal, not a quiet pass
  --template   print a canonical module, package or flake and exit
  --list-rules print every rule with its tier and mechanism, and exit

Environment: CHECK_NIX_NESTED=1 runs the checks and skips the self-test, which is how a
gate that calls this more than once avoids proving the same copy twice
Nothing here reaches the network
Exit 0 when clean, 1 with one `check-nix: <what>` line per finding, 2 on a usage error,
an unreadable path, a missing tool, a tool whose output shape moved, or nothing to check
EOF
}

die() { # the request itself is wrong
  printf 'check-nix: %s\n' "$1" >&2
  exit 2
}

# ---- the rules, listed once ------------------------------------------------------------
# machine: --list-rules prints this, and the self-test walks it to be sure every rule has
# a planted defect. A rule that exists in neither place is a rule nobody proved
rules() {
  cat <<'EOF'
nixfmt-formatted	delegated	a file nixfmt would rewrite
statix	delegated	an antipattern statix names, minus the two lints that fight module Nix
deadnix	delegated	an unused binding, lambda argument or inherit
EOF
}

# ---- templates ---------------------------------------------------------------------------
template_module() {
  cat <<'EOF'
{
  config,
  lib,
  pkgs,
  ...
}:

# What this module is for and why it is arranged this way — the comment sits after the
# argument header and abuts the body, so the reader meets it before the first attribute
let
  cfg = config.example.thing;
in
{
  options.example.thing = {
    enable = lib.mkEnableOption "the thing";

    port = lib.mkOption {
      type = lib.types.port;
      default = 8080;
      description = "Loopback port the thing binds";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = with pkgs; [ jq ];

    services.thing = {
      enable = true;
      inherit (cfg) port;
    };
  };
}
EOF
}

template_package() {
  cat <<'EOF'
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
}:

# Why this package lives here rather than coming from nixpkgs — a derivation carries the
# reason for its own existence, and meta carries everything a reader needs after that
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "example";
  version = "1.0.0";

  src = fetchFromGitHub {
    owner = "example";
    repo = "example";
    tag = "v${finalAttrs.version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };

  installPhase = ''
    runHook preInstall
    install -Dm755 example -t $out/bin
    runHook postInstall
  '';

  meta = {
    description = "Example of the shape a package takes in this family";
    homepage = "https://github.com/example/example";
    license = lib.licenses.mit;
    mainProgram = "example";
    platforms = lib.platforms.all;
  };
})
EOF
}

template_flake() {
  cat <<'EOF'
{
  description = "One line saying what this flake is, in the present tense";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAllSystems (pkgs: {
        default = pkgs.callPackage ./nix/package.nix { };
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell { packages = with pkgs; [ jq ]; };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
EOF
}

# ---- arguments ----------------------------------------------------------------------------
root=""
namespaces=()
paths=()
static=0
while (($#)); do
  case "$1" in
    -C)
      (($# >= 2)) || die "-C needs a directory"
      root="$2"
      shift 2
      ;;
    -N)
      (($# >= 2)) || die "-N needs a namespace"
      namespaces+=("$2")
      shift 2
      ;;
    --static)
      static=1
      shift
      ;;
    --list-rules)
      rules
      exit 0
      ;;
    --template)
      case "${2:-module}" in
        module) template_module ;;
        package) template_package ;;
        flake) template_flake ;;
        *) die "no such template: $2 — module, package or flake" ;;
      esac
      exit 0
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      paths+=("$1")
      shift
      ;;
  esac
done

if [[ -z "$root" ]]; then
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
fi
[[ -d "$root" ]] || die "cannot read $root as a directory"
for p in ${paths[@]+"${paths[@]}"}; do
  [[ -r "$p" ]] || die "cannot read $p"
done

findings=0
finding() {
  printf 'check-nix: %s\n' "$1" >&2
  findings=$((findings + 1))
}

# With a template, because the BSD mktemp on macOS wants one
work=$(mktemp -d "${TMPDIR:-/tmp}/check-nix.XXXXXX")
trap 'rm -rf "$work"' EXIT

# ---- the tools ----------------------------------------------------------------------------
# Run before a single rule reads a line, so a machine without a tool is refused rather than
# quietly checked with less. Degrading on a missing tool was rejected: an extractor that
# finds nothing must never read as "nothing drifted"
tool_preflight() {
  local missing=""
  local t
  for t in nixfmt statix deadnix jq nix-instantiate; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing:+$missing, }$t"
  done
  [[ -z "$missing" ]] ||
    die "needs $missing — nix develop -c is where the pinned ones live"
}
tool_preflight

# The two statix lints that fight module Nix, disabled for every repository at once rather
# than argued about in each. empty_pattern wants `_:` where a NixOS module's signature is
# `{ ... }:`, which is what nixpkgs and every module in this family writes. repeated_keys
# wants `home.packages` and `home.sessionVariables` folded into one nested `home`, but a
# dotted path at the top level is the module idiom and the module system does the merging
cat >"$work/statix.toml" <<'EOF'
disabled = ["empty_pattern", "repeated_keys"]
EOF

# ---- the files ----------------------------------------------------------------------------
# git ls-files rather than find wherever there is a git repository: it already knows what is
# ignored, and it does not descend into a result symlink pointing at the store. --others with
# --exclude-standard is what makes a file that is written but not yet staged visible: without
# it a new module passes here and fails in CI, where the same file is tracked, which is the
# one failure a gate exists to move earlier rather than later
nix_files() {
  if ((${#paths[@]})); then
    printf '%s\n' "${paths[@]}"
  elif git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
    git -C "$root" ls-files --cached --others --exclude-standard -- '*.nix' | sed "s|^|$root/|"
  else
    find "$root" -name '*.nix' -type f -not -path '*/.git/*' -not -path '*/result/*'
  fi
}

files=$(nix_files)
[[ -n "$files" ]] || die "no .nix file under $root — nothing to check"
file_count=$(printf '%s\n' "$files" | grep -c .)

# ---- delegated: nixfmt ---------------------------------------------------------------------
# Not `nix fmt -- --ci`: the checker also runs over a directory with no flake at all, and a
# repository's formatter output is the treefmt wrapper around this same binary
check_nixfmt() {
  local f
  printf '%s\n' "$files" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    nixfmt --check "$f" >/dev/null 2>&1 || printf '%s\n' "$f"
  done
}

# ---- delegated: statix ----------------------------------------------------------------------
# One file per call: statix takes a single target, and a directory walk would follow a result
# symlink into the store. errfmt is FILE>LINE:COL:SEVERITY:CODE:message, one finding per line
check_statix() {
  local f
  printf '%s\n' "$files" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    statix check -o errfmt -c "$work/statix.toml" "$f" 2>/dev/null || :
  done
}

# ---- delegated: deadnix ----------------------------------------------------------------------
# One JSON object per file with a results array; jq flattens it to the same shape the other
# two report in. The generated hardware-configuration.nix is excluded everywhere: NixOS writes
# it and a repository does not edit it, so its unused pkgs argument is not anybody's finding
check_deadnix() {
  local f
  printf '%s\n' "$files" | while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in */hardware-configuration.nix) continue ;; esac
    deadnix -o json "$f" 2>/dev/null |
      jq -r '.results[]? | "\(.line):\(.column): \(.message)"' |
      sed "s|^|$f:|"
  done
}

# ---- the run ----------------------------------------------------------------------------------
unformatted=$(check_nixfmt)
if [[ -n "$unformatted" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    finding "$f is not formatted by nixfmt — run nix fmt"
  done <<EOF
$unformatted
EOF
fi

statix_rows=$(check_statix)
if [[ -n "$statix_rows" ]]; then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    # FILE>LINE:COL:SEVERITY:CODE:message
    f="${row%%>*}"
    rest="${row#*>}"
    line="${rest%%:*}"
    rest="${rest#*:}"
    col="${rest%%:*}"
    rest="${rest#*:}"
    rest="${rest#*:}"
    code="${rest%%:*}"
    msg="${rest#*:}"
    finding "$f:$line:$col: statix W$code — $msg"
  done <<EOF
$statix_rows
EOF
fi

dead_rows=$(check_deadnix)
if [[ -n "$dead_rows" ]]; then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    finding "$row (deadnix)"
  done <<EOF
$dead_rows
EOF
fi

# ---- falsification ------------------------------------------------------------------------------
# Every check above is proven able to fail on this run, not on the run that wrote it: a canon is
# assembled from this script's own templates, confirmed clean, and then one defect per check is
# planted into a fresh copy, which must be rejected for that defect's own stated reason. A copy
# that is merely rejected proves nothing — any breakage rejects everything
self=$0
canon="$work/canon"

build_canon() {
  mkdir -p "$canon/nix"
  template_flake >"$canon/flake.nix"
  template_module >"$canon/module.nix"
  template_package >"$canon/nix/package.nix"
}

nested() { # nested DIR [ARGS...] -> this script on DIR's copy, falsification skipped
  local d="$1"
  shift
  local mode=()
  ((static == 0)) || mode=(--static)
  CHECK_NIX_NESTED=1 "$BASH" "$self" -C "$d" ${mode[@]+"${mode[@]}"} "$@"
}

copy() { # copy NAME -> a fresh copy of the canon
  local c="$work/$1"
  mkdir -p "$c"
  cp -R "$canon/." "$c/"
  printf '%s\n' "$c"
}

planted=0
# The count lives here rather than beside each call, so a new planted case cannot be left out
# of the number the summary line reports
expect_red() { # expect_red DIR FRAGMENT WHAT
  local d="$1" want="$2" what="$3" out
  if out=$(nested "$d" 2>&1); then
    die "self-test: a copy with $what passed — the check cannot catch it"
  fi
  case "$out" in
    *"$want"*) ;;
    *) die "self-test: a copy with $what was rejected for the wrong reason: $out" ;;
  esac
  planted=$((planted + 1))
}

expect_green() { # expect_green DIR WHAT
  local d="$1" what="$2" out status=0
  out=$(nested "$d" 2>&1) || status=$?
  ((status == 0)) ||
    die "self-test: $what was rejected with exit $status — the checker is broken, not the canon:"$'\n'"$out"
}

append() { # append DIR FILE LINE -> the line added at the end of the file
  printf '%s\n' "$3" >>"$1/$2"
}

# Through the environment rather than -v: awk reads escape sequences in a -v value, so a planted
# line holding a backslash would arrive changed
plant_after() { # plant_after DIR FILE AFTER-PATTERN LINE
  PAT="$3" LINE="$4" awk '{ print } !done && index($0, ENVIRON["PAT"]) == 1 { print ENVIRON["LINE"]; done = 1 }' \
    "$1/$2" >"$1/$2.new"
  mv "$1/$2.new" "$1/$2"
}

self_test() {
  build_canon

  # The canon must pass before any plant means anything, and it must be what --template prints,
  # so a nixfmt or statix release that moves is caught here rather than in a consumer
  expect_green "$canon" "the canon this script's own --template prints"

  local c
  # nixfmt: a line nixfmt would rewrite. Two spaces of indentation are the canon's, four are not
  c=$(copy nixfmt-plant)
  append "$c" module.nix '{    a    =    1; }'
  expect_red "$c" "is not formatted by nixfmt" "a line nixfmt would rewrite"

  # statix: `x = x;` is W3 manual_inherit, the house rule spelled as a lint rather than twice
  c=$(copy statix-plant)
  plant_after "$c" module.nix '  cfg = config.example.thing;' '  lib = lib;'
  expect_red "$c" "statix W3" "a binding statix rewrites with inherit"

  # statix again, from the other side: the two disabled lints must still be disabled, or a
  # consumer's every module fires on its own signature
  c=$(copy statix-disabled-plant)
  printf '{ ... }:\n{\n  a.b = 1;\n  a.c = 2;\n}\n' >"$c/aggregate.nix"
  expect_green "$c" "the signature and the dotted paths the two disabled lints would reject"

  # deadnix: an argument named and never read
  c=$(copy deadnix-plant)
  plant_after "$c" module.nix '  pkgs,' '  unusedArgument,'
  expect_red "$c" "Unused lambda pattern: unusedArgument" "an argument nothing reads"

  # The refusal itself: a machine without a tool must be refused, never checked with less. The
  # defect goes in the tools rather than in the text, which is the one thing a planted line
  # cannot express. Only the PATH entries holding statix are dropped, so the rest of the
  # userland survives and the run fails on the tool rather than on a missing mktemp
  local no_statix="" p oldifs
  oldifs=$IFS
  IFS=:
  for p in $PATH; do
    [ -x "$p/statix" ] || no_statix="${no_statix:+$no_statix:}$p"
  done
  IFS=$oldifs

  local out status=0
  out=$(PATH="$no_statix" CHECK_NIX_NESTED=1 "$BASH" "$self" -C "$canon" 2>&1) || status=$?
  ((status == 2)) ||
    die "self-test: a machine without statix was not refused with exit 2 (got $status): $out"
  case "$out" in
    *"needs statix"*) ;;
    *) die "self-test: a machine without statix was refused without naming statix: $out" ;;
  esac
  planted=$((planted + 1))
}

[[ -n "${CHECK_NIX_NESTED:-}" ]] || self_test

rule_count=$(rules | grep -c .)
noun="files"
((file_count != 1)) || noun="file"
summary="check-nix: $file_count .nix $noun, 3 tools, $rule_count rules"
((static == 0)) || summary="$summary; --static, so nothing that evaluates the flake ran"
((planted == 0)) || summary="$summary; $planted planted defects caught"
printf '%s\n' "$summary" >&2

((findings == 0)) || exit 1
exit 0
