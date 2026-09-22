#!/usr/bin/env bash
# shellcheck disable=SC2016 # every $ in a single-quoted text here is text to find, never an expansion
# The defect list for this repository.
# The tests skill's harness reads it, and that harness is vendored beside it:
#
#   tests/t.sh falsify -- ./check.sh
#
# Needs bash 3.2, because falsify sources it wherever t.sh runs, macOS included.
# check.sh holds it to that claim through check-sh.sh
#
# check-nix.sh plants a defect per rule on every run.
# It plants into fixtures it prints itself.
# That pass answers one question: can this rule still fire?
# This list answers a different one.
# Does anything notice when the machinery beneath the rules stops working?
# That machinery is the file walk, the tool preflight, the exemptions, the cache and the
# tokenisers.
# A rule broken there takes its own proof down with it, and both go quiet together
#
# So the entries below aim at the shared parts, and at shapes no fixture covers.
# A survivor is not a failure of this list.
# It is the gap the list was written to find
#
#   defect NAME FILE FIND REPLACE CONSEQUENCE [expect survived REASON | expect caught FRAGMENT]

# ---- drv-diff, which answers a different question ---------------------------------------------

defect drv-diff-sees-past-untracked drv-diff.sh \
  'if [[ -n "$untracked" ]]; then' \
  'if [[ -z "$untracked" ]]; then' \
  'A change written into a file nobody staged is invisible to both sides of the comparison, and the run answers "nothing moved" about an edit it never read. That is the one answer this tool must never give wrongly, because it is the answer people want'

defect drv-diff-never-says-moved drv-diff.sh \
  '    summary_rows="$summary_rows"$'"'"'\n'"'"'"  MOVED    $attr"' \
  '    summary_rows="$summary_rows"$'"'"'\n'"'"'"  same     $attr"' \
  'Every comparison reads as clean. A tool that only ever says "same" is worse than no tool: it is a signature on work nobody checked'

# ---- the walk and the preflight -------------------------------------------------------------

defect walk-drops-untracked check-nix.sh \
  'ls-files --cached --others --exclude-standard --' \
  'ls-files --' \
  'Nobody checks a module until someone stages it. CI then tracks the same file and goes red. The gate exists to move that failure earlier'

defect preflight-forgets-deadnix check-nix.sh \
  'for t in nixfmt statix deadnix jq nix-instantiate git; do' \
  'for t in nixfmt statix jq nix-instantiate git; do' \
  'A machine without deadnix reaches a green summary and says nothing about dead code. The summary does not mention that gap either'

defect pinned-path-guard-off check-nix.sh \
  "$(
    cat <<'EOF'
  if grep -q '^export PATH=' "$self"; then
EOF
  )" \
  '  if false; then' \
  'A copy whose wrapper pins the tools beside it dies on a plant that cannot work there. The consumer reads exit 2 on a tree where nothing is wrong, and the checker looks broken rather than the tree'

defect pinned-path-guard-always check-nix.sh \
  "$(
    cat <<'EOF'
  if grep -q '^export PATH=' "$self"; then
EOF
  )" \
  '  if true; then' \
  'Every run leaves out the five plants that prove a missing tool is refused. The summary says so, and a summary nobody reads is the whole risk'

defect preflight-never-refuses check-nix.sh \
  '[[ -z "$missing" ]] ||' \
  '[[ -n "$missing" ]] ||' \
  'A machine without any linter reports a clean run. A checker must never find nothing and then read as clean'

# ---- the exemptions -------------------------------------------------------------------------

defect generated-exemption-misses check-nix.sh \
  'case "$1" in */hardware-configuration.nix) return 0 ;; esac' \
  'case "$1" in */no-such-generated-file.nix) return 0 ;; esac' \
  'The hardware-configuration.nix that NixOS writes starts to produce findings nobody can act on. A repository then learns to read past its own checker'

defect kebab-reads-every-path check-nix.sh \
  "ls-files --cached --others --exclude-standard -- '*.nix' | awk '" \
  "ls-files --cached --others --exclude-standard | awk '" \
  "Cargo.toml, a pytest test_*.py, a zsh completion's leading underscore and an X11 cursor all become findings. None of those names is the author's, and a repository answers with a check-nix.allow longer than the rule"

defect idle-rule-excuse-called-stale check-nix.sh \
  '    case " $idle_rules " in *" $eid "*) continue ;; esac' \
  '    : "$idle_rules"' \
  'Every repository with a check-nix.allow goes red inside the nix flake check sandbox, and nowhere else. The excuse is correct; the rule it covers simply never ran there. A gate that is red only in one place teaches people to ignore that place'

defect stale-excuse-forgiven check-nix.sh \
  'finding "$allow_file: \"$eid $epath\" excuses nothing' \
  ': "$allow_file: \"$eid $epath\" excuses nothing' \
  'An excuse outlives the finding it covered. It then covers nothing, and nobody hears about it'

# ---- the tree, and the tokenisers that read it ------------------------------------------------

defect tree-cache-collides check-nix.sh \
  "cached=\"\$work/tree.\$(printf '%s' \"\$f\" | tr -c 'A-Za-z0-9' '.')\"" \
  'cached="$work/tree.shared"' \
  'Each file after the first is judged against the first file. A whole repository is then checked as one module'

defect lists-ignore-nesting check-nix.sh \
  '        else if (d == "{") nested = 1' \
  '        else if (d == "{") nested = 0' \
  'The walk reads a list with an attrset in it as a flat list. It then offers advice about with pkgs that would not compile' \
  expect survived 'The flag keeps such a list out of the test, not out of the finding. A list with an attrset in it cannot match "every element is a pkgs attribute" either way. The pattern is matched against text that holds the attrset. The flag is there so that a tighter pattern later cannot offer advice inside a callPackage call'

defect with-parse-half-gone check-nix.sh \
  'if [[ "$(body_head "$f")" == "with "* ]]; then' \
  'if [[ "$(body_head "$f")" == "never-matches "* ]]; then' \
  'The form `{ pkgs, ... }: with pkgs;` opens a file-wide scope and nothing says so. Only the form nixfmt puts at column 0 is still caught'

defect body-keys-ignores-strings check-nix.sh \
  '      if (c == "\"") { instr = 1; i++; continue }
      if (c == "{" || c == "[" || c == "(") { depth++; word = ""; i++; continue }' \
  '      if (c == "never") { instr = 1; i++; continue }
      if (c == "{" || c == "[" || c == "(") { depth++; word = ""; i++; continue }' \
  'The walk counts a brace inside a string as nesting. It then reads the keys of a default.nix wrong. The rule accuses an aggregator of configuring something'

defect header-without-its-terminator check-nix.sh \
  '      if (state != "body") { shape = "none"; named = 0; variadic = 0; after = 0; gap = 0; f = "" }' \
  '      if (state != "never") { shape = "none"; named = 0; variadic = 0; after = 0; gap = 0; f = "" }' \
  'Every flake.nix reads as a lambda whose formals are its own lines, indentation stripped. A file holding the bare word lib anywhere then draws the pkgs.lib finding, on a file that takes no arguments. Found by running the checker on a repository it was not written against'

defect namespace-reads-any-depth check-nix.sh \
  '      if (MODE == "ns" && want_ns && depth == 1) {
        if (c ~ /[A-Za-z0-9_.-]/) { nsword = nsword c; i++; continue }' \
  '      if (MODE == "ns" && want_ns && depth >= 1) {
        if (c ~ /[A-Za-z0-9_.-]/) { nsword = nsword c; i++; continue }' \
  'The rule reads an options block inside a types.submodule as a namespace this repository declares. A module then gets a finding about a name it never chose. People learn to ignore the rule'

defect namespace-skips-lets-wrongly check-nix.sh \
  '      if (substr(s, i, 4) != "let ") return substr(s, i)' \
  '      if (substr(s, i, 4) != "never") return substr(s, i)' \
  'Nearly every module binds cfg before its body. The walk then finds no body at all. Every rule that asks what the body holds asks it of nothing'

# ---- the lock and the evaluation --------------------------------------------------------------

defect lock-shape-guard-off check-nix.sh \
  '((nodes >= 2)) ||' \
  '((nodes >= 0)) ||' \
  'A truncated flake.lock reads as a clean one. The rule that watches for a local path override then watches nothing'

defect static-still-evaluates check-nix.sh \
  '((static)) || check_eval' \
  'check_eval' \
  'The sandbox run tries to evaluate a flake whose inputs it cannot fetch. The seam every consumer gets then fails for a reason that is not theirs'

defect summary-hides-what-was-skipped check-nix.sh \
  '((unforced == 0)) || summary="$summary; an output needed inputs' \
  '((unforced == 1)) || summary="$summary; an output needed inputs' \
  'A run that could not evaluate the flake reports the same summary as one that could. A shorter check then reads as a complete one'
