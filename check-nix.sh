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
gate that calls this more than once avoids proving the same copy twice. CHECK_NIX_GOLDEN
set to anything makes the pinned shape of the parser's output deliberately wrong, which
is how the self-test proves the refusal that shape is pinned by
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
file-kebab-case	names	a tracked path component that is not kebab-case
with-at-file-level	text	a with whose scope is the whole file body
module-arg-order	header	formals not in the order: the standard ones, the rest alphabetically, then ...
arg-line-shape	header	up to two named formals split across lines, or three and more on one
file-comment-placement	header	a module's file comment above its header, or held off its body by a blank line
with-over-let	tree	a with whose body binds names of its own
lookup-path	tree	<nixpkgs> or NIX_PATH, which read the machine rather than the lock
pkgs-lib-with-lib-arg	tree	pkgs.lib where lib is already an argument
self-src-unwrapped	tree	a derivation src taken straight from inputs.self
derivation-meta	tree	a derivation with no meta
default-nix-imports-only	tree	a default.nix that binds anything but imports
lock-no-local-input	lock	an input locked to an absolute path on one machine
flake-formatter	eval	a flake with no formatter, or one that is not nixfmt-tree
meta-description-grammar	eval	a package whose meta.description breaks the grammar nixpkgs asks for
meta-license	eval	a package with no meta.license
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

# The canonical form nix-instantiate --parse prints is documented nowhere, and every rule that
# reads the tree greps it. So before a rule reads a line, one expression holding every construct
# those rules look for is parsed and compared to the line it produced when they were written. A
# release that moves the printer stops the run and shows what it printed instead, rather than
# passing a check that has quietly stopped looking at anything
tree_probe() {
  cat <<'EOF'
{ inputs, lib, pkgs, ... }:
{
  a = with pkgs; [ jq ];
  b = with lib; let c = 1; in c;
  d = pkgs.lib.mkForce 1;
  e = import <nixpkgs> { };
  f = "a {brace} b";
  g = pkgs.stdenvNoCC.mkDerivation { src = "${inputs.self}/assets"; meta = { }; };
}
EOF
}

tree_golden() {
  # The one hook a test needs: a golden that deliberately no longer describes the printer, so the
  # refusal below can be proven able to fire on a machine where the printer has not in fact moved
  [[ -z "${CHECK_NIX_GOLDEN:-}" ]] || {
    printf 'a line the printer would never print\n'
    return 0
  }
  cat <<'EOF'
({ inputs, lib, pkgs, ... }: { a = (with pkgs; [ (jq) ]); b = (with lib; (let c = 1; in c)); d = ((pkgs).lib.mkForce 1); e = (import (__findFile __nixPath "nixpkgs") { }); f = "a {brace} b"; g = ((pkgs).stdenvNoCC.mkDerivation { meta = { }; src = ((inputs).self + "/assets"); }); })
EOF
}

tree_preflight() {
  tree_probe >"$work/probe.nix"
  nix-instantiate --parse "$work/probe.nix" >"$work/probe.out" 2>"$work/probe.err" ||
    die "nix-instantiate could not read the built-in probe: $(tr '\n' ' ' <"$work/probe.err")"
  tree_golden >"$work/probe.want"
  cmp -s "$work/probe.out" "$work/probe.want" || {
    printf 'check-nix: the tree printed by %s is not the one tree_golden describes — either the printer moved or the golden did\n' \
      "$(nix-instantiate --version 2>/dev/null || echo 'nix, version unknown')" >&2
    printf 'check-nix: the probe printed this instead, which is what tree_golden would become:\n' >&2
    sed 's/^/  /' "$work/probe.out" >&2
    exit 2
  }
}
tree_preflight

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

# ---- the excuses ---------------------------------------------------------------------------------
# check-nix.allow holds what a repository knows this checker cannot: `ID PATH [TEXT]` per line, a
# path ending in / standing for everything under it, as vendor-sync.sh already spells a directory.
# An entry that excuses nothing is itself a finding — an excuse must not outlive its reason, which
# is the same rule the standard states about a comment carrying a date instead of a cause
allow_file="$root/check-nix.allow"
: >"$work/allow"
: >"$work/allow.used"
if [[ -r "$allow_file" ]]; then
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$line" in '' | '#'*) continue ;; esac
    read -r entry_id entry_path _ <<<"$line"
    [[ -n "$entry_id" && -n "$entry_path" ]] ||
      die "$allow_file:$lineno: an entry is ID PATH [TEXT], and this one is: $line"
    printf '%s\t%s\n' "$entry_id" "$entry_path" >>"$work/allow"
  done <"$allow_file"
fi

rel_path() { # rel_path PATH -> the path as the repository spells it
  case "$1" in "$root"/*) printf '%s' "${1#"$root"/}" ;; *) printf '%s' "$1" ;; esac
}

excused() { # excused ID PATH — and the entry that did it is marked used
  local id="$1" path eid epath
  path=$(rel_path "$2")
  while IFS=$'\t' read -r eid epath; do
    [[ "$eid" == "$id" ]] || continue
    case "$epath" in
      */) case "$path" in "$epath"*) ;; *) continue ;; esac ;;
      *) [[ "$path" == "$epath" ]] || continue ;;
    esac
    printf '%s\t%s\n' "$eid" "$epath" >>"$work/allow.used"
    return 0
  done <"$work/allow"
  return 1
}

finding_unless_excused() { # finding_unless_excused ID PATH MESSAGE
  excused "$1" "$2" || finding "$3"
}

# ---- generated files -------------------------------------------------------------------------
# NixOS writes hardware-configuration.nix and a repository does not edit it, so its unused pkgs
# argument, its header and its comments are nobody's finding. The one default exemption there is
is_generated() { # is_generated FILE
  case "$1" in */hardware-configuration.nix) return 0 ;; esac
  return 1
}

# ---- the tree ------------------------------------------------------------------------------------
# nix-instantiate --parse re-prints the parsed expression as canonical Nix on one line, fully
# parenthesised, with every comment gone and every layout choice normalised. It is this checker's
# equivalent of `shfmt --to-json`, with one measured limit: it sorts attribute keys and lambda
# formals alphabetically, so it can answer what a file's shape is but never what order anything
# was written in. Order is a question for the text
tree_of() { # tree_of FILE -> the canonical line, cached
  local f="$1" cached
  cached="$work/tree.$(printf '%s' "$f" | tr -c 'A-Za-z0-9' '.')"
  [[ -s "$cached" ]] || nix-instantiate --parse "$f" >"$cached" 2>/dev/null || :
  cat "$cached"
}

is_lambda() { # is_lambda FILE — does the file evaluate to a function taking formals
  case "$(tree_of "$1" | head -c 2)" in '({') return 0 ;; esac
  return 1
}

# Walks the canonical line with { } [ ] ( ) depth and skips over "…" strings, so a brace inside a
# string is not a nesting level. Two questions are asked of it: which keys the body attrset binds
# at its own level, and what the body opens with once the lambda header is out of the way
# A Nix identifier may hold an apostrophe, and this reads `foo'` as `foo` and gives up on a
# `@ args'` binding. Both are legal and neither appears in the family; both fail towards a
# finding rather than towards silence, which is the direction an unhandled shape has to fail in
# shellcheck disable=SC2016 # $0 here is awk's record, and not expanding it is the whole point
body_awk='
  function skip_lambda(s,   n, i, j, d, c, rest) {
    n = length(s); i = 1
    while (i <= n && substr(s, i, 1) == "(") i++
    if (substr(s, i, 1) != "{") return substr(s, i)
    j = i; d = 0
    while (j <= n) {
      c = substr(s, j, 1)
      if (c == "{") d++
      else if (c == "}") { d--; if (d == 0) break }
      j++
    }
    rest = substr(s, j + 1)
    if (rest !~ /^[[:space:]]*(@[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*)?:/) return substr(s, i)
    sub(/^[[:space:]]*(@[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*)?:[[:space:]]*/, "", rest)
    return rest
  }
  {
    body = skip_lambda($0)
    if (MODE == "head") { print substr(body, 1, 6); exit }
    n = length(body); i = 1
    while (i <= n && substr(body, i, 1) == "(") i++
    if (substr(body, i, 1) != "{") { print "NOT-AN-ATTRSET"; exit }
    i++
    depth = 0; instr = 0; word = ""
    while (i <= n) {
      c = substr(body, i, 1)
      if (instr) {
        if (c == "\\") i++
        else if (c == "\"") instr = 0
        i++; continue
      }
      if (c == "\"") { instr = 1; i++; continue }
      if (c == "{" || c == "[" || c == "(") { depth++; word = ""; i++; continue }
      if (c == "}" || c == "]" || c == ")") {
        if (c == "}" && depth == 0) break
        depth--; word = ""; i++; continue
      }
      if (depth == 0) {
        if (c ~ /[A-Za-z0-9_.-]/) { word = word c; i++; continue }
        if (c == "=" && word != "") { split(word, seg, "."); print seg[1]; word = ""; i++; continue }
        if (c == ";") { word = ""; i++; continue }
      }
      i++
    }
  }'

body_keys() { # body_keys FILE -> the keys the body attrset binds at its own level
  tree_of "$1" | awk -v MODE=keys "$body_awk"
}

body_head() { # body_head FILE -> the first six characters of the body, the lambda header gone
  tree_of "$1" | awk -v MODE=head "$body_awk"
}

# ---- the header ----------------------------------------------------------------------------------
# The one region where text can be read without a lexer: before the first `}:` there are no strings
# and no nesting, measured across every .nix file in the family. The awk emits one row —
# SHAPE, NAMED, VARIADIC, ABOVE, AFTER, GAP, FORMALS — and every header rule reads it
header_facts() { # header_facts FILE
  awk '
    BEGIN { state = "pre"; shape = "none"; above = 0; named = 0; variadic = 0; after = 0; gap = 0; f = "" }
    state == "pre" && /^[[:space:]]*$/ { next }
    state == "pre" && /^#/ { above = 1; next }
    state == "pre" && /^\{[[:space:]]*$/ { shape = "multi"; state = "formals"; next }
    state == "pre" && /^\{.*\}[[:space:]]*:/ {
      shape = "inline"
      line = $0
      sub(/^\{/, "", line)
      sub(/\}[[:space:]]*:.*$/, "", line)
      n = split(line, parts, ",")
      for (i = 1; i <= n; i++) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", parts[i])
        if (parts[i] == "...") variadic = 1
        else if (parts[i] != "") { named++; f = f (f ? " " : "") parts[i] }
      }
      state = "body"
      next
    }
    state == "pre" { exit }
    state == "formals" && /^\}[[:space:]]*:/ { state = "body"; next }
    state == "formals" {
      line = $0
      gsub(/^[[:space:]]+|,[[:space:]]*$/, "", line)
      gsub(/[[:space:]]+$/, "", line)
      if (line == "...") variadic = 1
      else if (line != "") { named++; f = f (f ? " " : "") line }
      next
    }
    state == "body" && /^[[:space:]]*$/ { if (after) gap = 1; next }
    state == "body" && /^#/ { after = 1; next }
    state == "body" { exit }
    END { printf "%s\t%d\t%d\t%d\t%d\t%d\t%s\n", shape, named, variadic, above, after, gap, f }
  ' "$1"
}

# The standard module arguments, in the order they come in; everything after them is alphabetical.
# `...` is always last, and nixfmt keeps whichever of the two line shapes it is given, so both the
# order and the shape are on the author
standard_args="config lib pkgs osConfig"

expected_order() { # expected_order FORMALS... -> the order they should have been written in
  local given="$*" s rest=""
  for s in $standard_args; do
    case " $given " in *" $s "*) printf '%s ' "$s" ;; esac
  done
  for s in $given; do
    case " $standard_args " in *" $s "*) ;; *) rest="$rest$s"$'\n' ;; esac
  done
  [[ -z "$rest" ]] || printf '%s' "$rest" | LC_ALL=C sort | tr '\n' ' '
}

# A comment block above a module's header is attribution — a credit for vendored third-party work,
# like a licence header — and nothing else. A URL or one of the words a credit is written with is
# what tells the two apart; an explanation of the module belongs after the header, where the reader
# meets it with the code it explains
is_attribution() { # is_attribution FILE
  awk '
    /^#/ { block = block $0 "\n"; next }
    { exit }
    END {
      if (block ~ /https?:\/\//) { print "yes"; exit }
      if (block ~ /(Author|Copyright|Original|Upstream|Vendored|SPDX)/) { print "yes"; exit }
      print "no"
    }
  ' "$1"
}

# ---- the tree's own rules ---------------------------------------------------------------------
# Everything here reads the canonical line, where comments are gone and layout is normalised, so a
# rule is about the expression rather than about how it was typed. The forms grepped for are the
# ones tree_probe pins: a release of Nix that moves them stops the run rather than passing it
check_tree() { # check_tree FILE
  local f="$1" tree keys
  tree=$(tree_of "$f")
  [[ -n "$tree" ]] || return 0

  # A with whose scope is the file body. nixfmt writes the `let … in with` form at column 0, which
  # the text anchor catches; the form that shares the header's line only shows here
  if [[ "$(body_head "$f")" == "(with "* ]]; then
    finding_unless_excused with-at-file-level "$f" \
      "$f: a with at the file level — its scope is every name the file goes on to bind"
  fi

  case "$tree" in
    *"; (let "*)
      # A with over a let is the shape the ban is really about: the body grows bindings, and each
      # one silently takes a name the with was opening
      case "$tree" in
        *"with "*"; (let "*)
          finding_unless_excused with-over-let "$f" \
            "$f: a with over a let — a binding added below silently takes a name the with opened"
          ;;
      esac
      ;;
  esac

  # `<nixpkgs>` parses to __findFile __nixPath, and NIX_PATH is read by name. Both make the
  # evaluation depend on the machine it runs on, which is the one thing a flake exists to stop
  case "$tree" in
    *"__findFile __nixPath"* | *'getEnv "NIX_PATH"'*)
      finding_unless_excused lookup-path "$f" \
        "$f: a lookup path or NIX_PATH — the evaluation then depends on the machine it runs on"
      ;;
  esac

  # `pkgs.lib` where lib is already an argument: two names for one thing, and the longer one is
  # the one that stops being obviously the same lib as soon as an overlay is in play
  if [[ "$tree" == *"(pkgs).lib."* ]] && [[ " $(header_facts "$f" | cut -f7) " == *" lib "* ]]; then
    finding_unless_excused pkgs-lib-with-lib-arg "$f" \
      "$f: pkgs.lib where lib is already an argument — call it lib"
  fi

  # A repository asset reaching a derivation as a plain string ties that derivation's hash to the
  # whole repository, so every commit rebuilds it. builtins.path with a fixed name is the isolation
  case "$tree" in
    *'src = ((inputs).self + '* | *'src = ((self + '* | *'src = (self + '*)
      finding_unless_excused self-src-unwrapped "$f" \
        "$f: a derivation takes its src straight from inputs.self — wrap it in builtins.path with a fixed name, or every commit rebuilds it"
      ;;
  esac

  # A derivation with no meta at all. The heuristic is deliberately narrow: an inline derivation
  # inside a module and a runCommand in a flake are not found here, and extending it to every
  # mkDerivation anywhere would fire on the throwaway derivations a wrapper builds
  case "$tree" in
    *mkDerivation* | *buildGoModule* | *buildRustPackage* | *buildPythonPackage* | *buildNpmPackage*)
      case "$tree" in
        *" meta = "*) ;;
        *)
          finding_unless_excused derivation-meta "$f" \
            "$f: a derivation with no meta — a package says what it is, who may use it and where it runs"
          ;;
      esac
      ;;
  esac

  # default.nix is reserved for aggregators. The repository's own root is the exception: there it
  # is the entry a bare `nix-build` reaches for, not a list of modules
  if [[ "$(basename "$f")" == "default.nix" ]] && [[ "$(dirname "$f")" != "$root" ]]; then
    keys=$(body_keys "$f" | tr '\n' ' ')
    if [[ "$keys" != "imports " ]]; then
      finding_unless_excused default-nix-imports-only "$f" \
        "$f: a default.nix binding ${keys:-nothing but a let} — it is reserved for aggregators that only import"
    fi
  fi
}

check_header() { # check_header FILE
  local f="$1" row shape named variadic above after gap formals want
  row=$(header_facts "$f")
  shape=$(printf '%s' "$row" | cut -f1)
  named=$(printf '%s' "$row" | cut -f2)
  variadic=$(printf '%s' "$row" | cut -f3)
  above=$(printf '%s' "$row" | cut -f4)
  after=$(printf '%s' "$row" | cut -f5)
  gap=$(printf '%s' "$row" | cut -f6)
  formals=$(printf '%s' "$row" | cut -f7)

  [[ "$shape" == "inline" || "$shape" == "multi" ]] || return 0

  if [[ "$shape" == "multi" ]] && ((named <= 2)); then
    finding_unless_excused arg-line-shape "$f" \
      "$f: $named named arguments are stacked — up to two go on one line"
  fi
  if [[ "$shape" == "inline" ]] && ((named >= 3)); then
    finding_unless_excused arg-line-shape "$f" \
      "$f: $named named arguments share a line — three and more go one per line"
  fi

  # Only a module: a package's arguments come in the order nixpkgs writes them — lib, the stdenv,
  # the fetchers, then what it builds against — and alphabetising them would put fetchFromGitHub
  # before stdenvNoCC, which no package in nixpkgs or in this family does
  if ((variadic && named >= 2)); then
    # shellcheck disable=SC2086 # splitting the formals into arguments is the point
    want=$(expected_order $formals)
    # Both sides are space-terminated, so a prefix never matches a longer name
    if [[ "$formals " != "$want" ]]; then
      finding_unless_excused module-arg-order "$f" \
        "$f: arguments are $formals, and the order is ${want% }"
    fi
  fi

  # Only a module: a package or a plain function keeps its comment on line 1, which is where a
  # reader of a file that is not a module looks first
  if ((variadic)) && ((above)) && [[ "$(is_attribution "$f")" == "no" ]]; then
    finding_unless_excused file-comment-placement "$f" \
      "$f: a module's file comment sits above its header — it goes after it, abutting the body"
  fi
  if ((gap)); then
    finding_unless_excused file-comment-placement "$f" \
      "$f: a blank line holds the file comment off the body it explains"
  fi
  if ((after && above && variadic)); then
    finding_unless_excused file-comment-placement "$f" \
      "$f: the file comment is in both places at once, above the header and after it"
  fi
}

# ---- the run ----------------------------------------------------------------------------------
unformatted=$(check_nixfmt)
if [[ -n "$unformatted" ]]; then
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    finding_unless_excused nixfmt-formatted "$f" "$f is not formatted by nixfmt — run nix fmt"
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
    finding_unless_excused statix "$f" "$f:$line:$col: statix W$code — $msg"
  done <<EOF
$statix_rows
EOF
fi

dead_rows=$(check_deadnix)
if [[ -n "$dead_rows" ]]; then
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    finding_unless_excused deadnix "${row%%:*}" "$row (deadnix)"
  done <<EOF
$dead_rows
EOF
fi

# ---- the file names ------------------------------------------------------------------------------
# Every path in the repository, not only the .nix ones: a theme directory or an asset breaks the
# convention as readily as a module, and a rename has to find every reference to it. Conventional
# root metadata is the one shape spelled in capitals on purpose
kebab_rows=""
if ((${#paths[@]} == 0)) && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  kebab_rows=$(git -C "$root" ls-files --cached --others --exclude-standard | awk '
    {
      n = split($0, part, "/")
      for (i = 1; i <= n; i++) {
        p = part[i]
        # Conventional metadata is spelled in capitals on purpose, wherever it sits: README.md
        # beside the code it describes, LICENSE and CLAUDE.md at the root, MEMORY.md in a
        # directory of its own. The stem has to be capitals throughout, so a CamelCase asset
        # such as a vendored font is not swept in with them, and only the last component may
        # take the exemption — a directory in capitals was named without the convention
        if (i == n && p ~ /^[A-Z][A-Z0-9_-]*(\.[a-z0-9]+)?$/) continue
        if (p ~ /^\.?[a-z0-9][a-z0-9.-]*$/) continue
        print $0 "\t" p
        break
      }
    }')
fi
if [[ -n "$kebab_rows" ]]; then
  while IFS=$'\t' read -r path part; do
    [[ -n "$path" ]] || continue
    finding_unless_excused file-kebab-case "$path" "$path: \"$part\" is not kebab-case"
  done <<EOF
$kebab_rows
EOF
fi

# ---- the header, and the with that scopes a whole file ---------------------------------------------
# nixfmt puts a file-level `with` at column 0 only when a `let ... in` precedes it; the form
# `{ pkgs, ... }: with pkgs; { … }` it leaves on one line, so the text anchor alone is not enough
# and the parse form answers the rest
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  is_generated "$f" && continue
  if grep -q '^with ' "$f" 2>/dev/null; then
    finding_unless_excused with-at-file-level "$f" \
      "$f: a with at the file level — its scope is every name the file goes on to bind"
  fi
  check_tree "$f"
  is_lambda "$f" || continue
  check_header "$f"
done <<EOF
$files
EOF

# ---- the excuses, read back --------------------------------------------------------------------
# An entry that excused nothing this run is a finding of its own. It means either the thing it
# covered is gone, and the line outlived its reason, or the path stopped matching and the excuse
# has been silently covering nothing since. Neither is something to discover a year later
if [[ -s "$work/allow" ]]; then
  while IFS=$'\t' read -r eid epath; do
    [[ -n "$eid" ]] || continue
    grep -qxF "$eid	$epath" "$work/allow.used" ||
      finding "$allow_file: \"$eid $epath\" excuses nothing — the finding it covered is gone"
  done <"$work/allow"
fi

# ---- falsification ------------------------------------------------------------------------------
# Every check above is proven able to fail on this run, not on the run that wrote it: a canon is
# assembled from this script's own templates, confirmed clean, and then one defect per check is
# planted into a fresh copy, which must be rejected for that defect's own stated reason. A copy
# that is merely rejected proves nothing — any breakage rejects everything
self=$0
canon="$work/canon"

# A git repository on purpose: the name rule reads the repository's own file list, and the walk
# that finds the .nix files takes its git branch here rather than the find one, so the plants
# below exercise the path a consumer actually runs
build_canon() {
  mkdir -p "$canon/nix"
  template_flake >"$canon/flake.nix"
  template_module >"$canon/module.nix"
  template_package >"$canon/nix/package.nix"
  git -C "$canon" init -q
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

swap_lines() { # swap_lines DIR FILE FIRST SECOND -> the two lines exchanged
  A="$3" B="$4" awk '
    $0 == ENVIRON["A"] { print ENVIRON["B"]; next }
    $0 == ENVIRON["B"] { print ENVIRON["A"]; next }
    { print }
  ' "$1/$2" >"$1/$2.new"
  mv "$1/$2.new" "$1/$2"
}

collapse_header() { # collapse_header DIR FILE -> a stacked header put back on one line
  awk '
    NR == 1 && $0 == "{" { inhdr = 1; line = "{"; next }
    inhdr && /^\}[[:space:]]*:/ { print line " }:"; inhdr = 0; next }
    inhdr {
      gsub(/^[[:space:]]+|,[[:space:]]*$/, "", $0)
      line = line (line == "{" ? " " : ", ") $0
      next
    }
    { print }
  ' "$1/$2" >"$1/$2.new"
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

  # A path component that is not kebab-case. It is the file list the repository keeps, not the
  # .nix walk, so the plant is a file of any kind
  c=$(copy kebab-plant)
  : >"$c/Not_Kebab.txt"
  expect_red "$c" 'is not kebab-case' "a path component in snake case"

  # …and the exemption that keeps a README from being one: the same plant under a name spelled
  # in capitals throughout must pass, or every repository in the family goes red on its own docs
  c=$(copy kebab-metadata-plant)
  : >"$c/NOTES.md"
  expect_green "$c" "a document named in capitals the way metadata is"

  # A with whose scope is the file. nixfmt only puts it at column 0 after a `let … in`, which the
  # canon has, so the plant is what a consumer would actually have written
  c=$(copy with-plant)
  plant_after "$c" module.nix 'in' 'with pkgs;'
  expect_red "$c" "a with at the file level" "a with scoping the whole file"

  # The order of a module's arguments, which nixfmt preserves either way and so cannot hold
  c=$(copy order-plant)
  swap_lines "$c" module.nix '  config,' '  lib,'
  expect_red "$c" "and the order is config lib pkgs" "arguments out of their order"

  # Three named arguments on one line, which nixfmt also preserves
  c=$(copy shape-plant)
  collapse_header "$c" module.nix
  expect_red "$c" "share a line" "three arguments sharing a line"

  # The file comment held off the body by a blank line
  c=$(copy comment-gap-plant)
  plant_after "$c" module.nix '# argument header and abuts the body' ''
  expect_red "$c" "holds the file comment off the body" "a blank line between the comment and the body"

  # An excuse that covers nothing is a finding of its own
  c=$(copy stale-allow-plant)
  printf 'file-kebab-case No_Such_File.txt\n' >"$c/check-nix.allow"
  expect_red "$c" "excuses nothing" "an excuse whose finding is gone"

  # The tree's own rules. Each plant is a whole file rather than an edit to the canon, so the
  # fixture says plainly what shape it is about and nothing else in it can fire first
  c=$(copy aggregator-plant)
  mkdir -p "$c/sub"
  printf '{ ... }:\n{\n  imports = [ ];\n  services.thing.enable = true;\n}\n' >"$c/sub/default.nix"
  expect_red "$c" "reserved for aggregators" "a default.nix that also configures something"

  c=$(copy aggregator-clean-plant)
  mkdir -p "$c/sub"
  printf '{ ... }:\n{\n  imports = [ ];\n}\n' >"$c/sub/default.nix"
  expect_green "$c" "a default.nix that only imports"

  c=$(copy with-over-let-plant)
  printf '{ lib, ... }:\n{\n  a = with lib; let b = 1; in b;\n}\n' >"$c/scoped.nix"
  expect_red "$c" "a with over a let" "a with whose body binds names of its own"

  c=$(copy lookup-path-plant)
  printf '{ ... }:\n{\n  a = import <nixpkgs> { };\n}\n' >"$c/looked.nix"
  expect_red "$c" "a lookup path or NIX_PATH" "a lookup path"

  c=$(copy pkgs-lib-plant)
  printf '{ lib, pkgs, ... }:\n{\n  a = pkgs.lib.mkForce 1;\n  b = lib.mkDefault 2;\n}\n' >"$c/forced.nix"
  expect_red "$c" "pkgs.lib where lib is already an argument" "pkgs.lib beside a lib argument"

  c=$(copy self-src-plant)
  # shellcheck disable=SC2016 # ${inputs.self} is Nix interpolation in the planted file, not this shell's
  printf '{ inputs, pkgs, ... }:\n{\n  a = pkgs.stdenvNoCC.mkDerivation {\n    pname = "x";\n    version = "1";\n    src = "${inputs.self}/assets";\n    meta.description = "X";\n  };\n}\n' >"$c/vendored.nix"
  expect_red "$c" "straight from inputs.self" "a derivation src that is the whole repository"

  c=$(copy no-meta-plant)
  printf '{ pkgs, ... }:\n{\n  a = pkgs.stdenvNoCC.mkDerivation {\n    pname = "x";\n    version = "1";\n  };\n}\n' >"$c/bare.nix"
  expect_red "$c" "a derivation with no meta" "a derivation that says nothing about itself"

  # An input locked to a path on one machine. Two nodes, because a lock with fewer is a lock this
  # is reading wrong, and that refusal is a different one
  c=$(copy local-input-plant)
  cat >"$c/flake.lock" <<'LOCK'
{
  "nodes": {
    "local": {
      "locked": { "type": "path", "path": "/home/someone/dev/thing" },
      "original": { "type": "path", "path": "/home/someone/dev/thing" }
    },
    "root": { "inputs": { "local": "local" } }
  },
  "root": "root",
  "version": 7
}
LOCK
  expect_red "$c" "locked to an absolute local path" "an input pointing at one machine's disk"

  # The grammar meta.description is held to. Only the half that judges is planted: the half that
  # obtains needs a locked flake and its inputs, and is proven by every green run on a real
  # repository. Each case runs in a subshell, so the findings it prints do not reach this run's count
  local judged
  for judged in \
    'default	thing	A thing that does things	article:opens with an article' \
    'default	thing	Does things.	period:ends with a period' \
    'default	thing	does things	case:starts lowercase' \
    'default	thing	thing that does things	name:opens with the package'"'"'s own name' \
    'default	thing	Does things	license:no meta.license'; do
    local row="${judged%%	*}" rest="${judged#*	}" want
    row="${judged%	*}"
    want="${judged##*	}"
    want="${want#*:}"
    local out
    out=$( (printf '%s\n' "$row" | meta_judge) 2>&1 || :)
    case "$out" in
      *"$want"*) ;;
      *) die "self-test: a description this checker should have named was not: wanted \"$want\", got \"$out\"" ;;
    esac
    planted=$((planted + 1))
  done

  # The printer the tree rules read is not documented, so the shape it prints is pinned. This asks
  # the refusal rather than the rule: a golden that no longer describes the printer must stop the
  # run, and the check that it does is the one thing tree_preflight cannot prove about itself
  local out status=0
  out=$(CHECK_NIX_NESTED=1 CHECK_NIX_GOLDEN=moved "$BASH" "$self" -C "$canon" 2>&1) || status=$?
  ((status == 2)) ||
    die "self-test: a golden that no longer matches the printer did not stop the run (got $status): $out"
  case "$out" in
    *"is not the one tree_golden describes"*) ;;
    *) die "self-test: a moved golden was refused for the wrong reason: $out" ;;
  esac
  planted=$((planted + 1))

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

# ---- the lock ----------------------------------------------------------------------------------
# flake.lock is JSON and nothing else, so this asks it directly and needs neither network nor store
check_lock() {
  local lock="$root/flake.lock" nodes
  [[ -r "$lock" ]] || return 0
  nodes=$(jq -r '.nodes | length' "$lock" 2>/dev/null) ||
    die "$lock is not JSON this can read"
  ((nodes >= 2)) ||
    die "$lock holds $nodes nodes — this is reading the wrong shape, not an empty lock"

  # A dev override — url = "path:/home/…" while an input is worked on locally — reaches the lock
  # through an ordinary `git add -A` and then breaks the repository on every machine but one.
  # Relative paths are left alone: those are subflakes of this repository and travel with it
  local bad
  bad=$(jq -r '
    .nodes | to_entries[] | .key as $name
    | [(.value.locked // {}), (.value.original // {})][]
    | select(((.type? == "path") and ((.path? // "") | startswith("/")))
             or ((.type? == "git") and ((.url? // "") | startswith("file:///"))))
    | $name
  ' "$lock" | sort -u)
  local n
  for n in $bad; do
    finding_unless_excused lock-no-local-input "$lock" \
      "$lock: \"$n\" is locked to an absolute local path — a dev override reached the lock, and no other machine has it"
  done
}

# ---- what only the evaluation knows ----------------------------------------------------------
# These ask the flake for values rather than for text, so they need its inputs — which the nix
# flake check sandbox has neither the network nor the store to fetch. --static leaves them out and
# says so; the run that has them is a plain CI step beside the one in the sandbox
meta_judge() { # meta_judge — reads the evaluated packages as JSON on stdin
  local attr pname description license row
  while IFS=$'\t' read -r attr pname description license; do
    [[ -n "$attr" ]] || continue
    row="$root#packages.$attr"
    if [[ -z "$description" ]]; then
      finding_unless_excused meta-description-grammar "$row" \
        "$row: no meta.description — a package says in one sentence what it is"
    else
      case "$description" in
        [a-z]*) finding_unless_excused meta-description-grammar "$row" \
          "$row: meta.description starts lowercase: \"$description\"" ;;
      esac
      case "$description" in
        *.) finding_unless_excused meta-description-grammar "$row" \
          "$row: meta.description ends with a period: \"$description\"" ;;
      esac
      case "$description" in
        "A "* | "An "* | "The "*) finding_unless_excused meta-description-grammar "$row" \
          "$row: meta.description opens with an article: \"$description\"" ;;
      esac
      case "$description" in
        "$pname"*) finding_unless_excused meta-description-grammar "$row" \
          "$row: meta.description opens with the package's own name: \"$description\"" ;;
      esac
    fi
    [[ -n "$license" ]] ||
      finding_unless_excused meta-license "$row" \
        "$row: no meta.license — what a package may be used for is not a detail"
  done
}

unforced=0 # outputs whose value needed inputs this machine does not hold

check_eval() {
  [[ -r "$root/flake.nix" ]] || return 0
  local system outs name packages
  system=$(nix config show system 2>/dev/null) || system=""
  [[ -n "$system" ]] || die "nix could not say what system this is"

  # --offline throughout, because the help promises this reaches no network. The names of a
  # flake's outputs evaluate without forcing its inputs, so whether a formatter is declared can
  # be asked of any flake; what it evaluates to cannot, and that half is skipped and said aloud
  outs=$(nix eval --offline --impure --json --expr "builtins.attrNames (builtins.getFlake \"$root\")" 2>/dev/null) ||
    {
      unforced=1
      return 0
    }
  case "$outs" in
    *'"formatter"'*)
      if name=$(nix eval --offline --no-write-lock-file --raw "$root#formatter.$system.name" 2>/dev/null); then
        case "$name" in
          nixfmt-tree-*) ;;
          *) finding_unless_excused flake-formatter "$root/flake.nix" \
            "$root/flake.nix: formatter is $name — the family's is nixfmt-tree, which walks a whole tree rather than the files it is handed" ;;
        esac
      else
        unforced=1
      fi
      ;;
    *)
      finding_unless_excused flake-formatter "$root/flake.nix" \
        "$root/flake.nix: no formatter output — nix fmt then does nothing and CI has nothing to run"
      ;;
  esac

  case "$outs" in
    *'"packages"'*) ;;
    # A flake with no packages is not a finding: a module or a skill repository has none
    *) return 0 ;;
  esac
  packages=$(nix eval --offline --no-write-lock-file --json "$root#packages.$system" --apply '
    ps: builtins.mapAttrs (n: p: {
      pname = p.pname or n;
      description = p.meta.description or "";
      license = p.meta.license.spdxId or (p.meta.license.shortName or "");
    }) ps' 2>/dev/null) || {
    unforced=1
    return 0
  }
  printf '%s' "$packages" |
    jq -r 'to_entries[] | [.key, .value.pname, .value.description, .value.license] | @tsv' |
    meta_judge
}

check_lock
((static)) || check_eval

# Last, so every rule it plants a defect against is defined and every real finding is already out
[[ -n "${CHECK_NIX_NESTED:-}" ]] || self_test

rule_count=$(rules | grep -c .)
noun="files"
((file_count != 1)) || noun="file"
summary="check-nix: $file_count .nix $noun, 3 tools, $rule_count rules"
((static == 0)) || summary="$summary; --static, so nothing that evaluates the flake ran"
((unforced == 0)) || summary="$summary; an output needed inputs this machine does not hold, so what it evaluates to went unchecked"
((planted == 0)) || summary="$summary; $planted planted defects caught"
printf '%s\n' "$summary" >&2

((findings == 0)) || exit 1
exit 0
