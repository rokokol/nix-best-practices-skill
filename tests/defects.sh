#!/usr/bin/env bash
# shellcheck disable=SC2016 # every $ in a single-quoted text here is text to find, never an expansion
# The defect list for this repository, read by the tests skill's harness, vendored beside it:
#
#   tests/t.sh falsify -- ./check.sh
#
# Needs bash 3.2, since falsify sources it wherever t.sh runs, macOS included; check.sh holds
# it to that claim through check-sh.sh
#
# check-nix.sh plants a defect per rule into fixtures it prints itself, on every run. That pass
# answers "can this rule still fire". It cannot answer the question this list is for: whether
# anything notices when the machinery UNDER the rules stops working — the file walk, the tool
# preflight, the exemptions, the cache, the tokenisers. A rule broken there takes its own proof
# down with it, and the two go quiet together.
#
# So the entries below aim at the shared parts, and at the shapes no fixture covers. A survivor
# is not a failure of this list: it is the gap it was written to find.
#
#   defect NAME FILE FIND REPLACE CONSEQUENCE [expect survived REASON | expect caught FRAGMENT]

# ---- the walk and the preflight -------------------------------------------------------------

defect walk-drops-untracked check-nix.sh \
  'ls-files --cached --others --exclude-standard --' \
  'ls-files --' \
  'A module written but not yet staged is checked by nobody until CI, where the same file is tracked and the same run goes red — the failure the gate exists to move earlier'

defect preflight-forgets-deadnix check-nix.sh \
  'for t in nixfmt statix deadnix jq nix-instantiate git; do' \
  'for t in nixfmt statix jq nix-instantiate git; do' \
  'A machine without deadnix runs to a green summary having said nothing about dead code, and the summary does not mention that either'

defect preflight-never-refuses check-nix.sh \
  '[[ -z "$missing" ]] ||' \
  '[[ -n "$missing" ]] ||' \
  'A machine missing every linter reports a clean run, which is the one thing a checker must never do: find nothing and read as nothing being wrong'

# ---- the exemptions -------------------------------------------------------------------------

defect generated-exemption-misses check-nix.sh \
  'case "$1" in */hardware-configuration.nix) return 0 ;; esac' \
  'case "$1" in */no-such-generated-file.nix) return 0 ;; esac' \
  'The hardware-configuration.nix NixOS writes starts producing findings nobody can act on, and a repository learns to read past its own checker'

defect kebab-exempts-any-capital check-nix.sh \
  'if (i == n && p ~ /^[A-Z][A-Z0-9_-]*(\.[a-z0-9]+)?$/) continue' \
  'if (i == n && p ~ /^[A-Z]/) continue' \
  'Any CamelCase path passes the naming rule, so a vendored font or a module named the wrong way is never named'

defect stale-excuse-forgiven check-nix.sh \
  'finding "$allow_file: \"$eid $epath\" excuses nothing' \
  ': "$allow_file: \"$eid $epath\" excuses nothing' \
  'An excuse outlives the finding it covered and goes on silently covering nothing, which is the failure the rule about dates in comments is about'

# ---- the tree, and the tokenisers that read it ------------------------------------------------

defect tree-cache-collides check-nix.sh \
  "cached=\"\$work/tree.\$(printf '%s' \"\$f\" | tr -c 'A-Za-z0-9' '.')\"" \
  'cached="$work/tree.shared"' \
  'Every file after the first is judged against the first file s tree, so a whole repository is checked as though it were one module'

defect lists-ignore-nesting check-nix.sh \
  '        else if (d == "{") nested = 1' \
  '        else if (d == "{") nested = 0' \
  'A list holding an attrset is read as a flat one, so a callPackage call or a submodule is offered advice about with pkgs that would not compile'

defect with-parse-half-gone check-nix.sh \
  'if [[ "$(body_head "$f")" == "(with "* ]]; then' \
  'if [[ "$(body_head "$f")" == "(never-matches "* ]]; then' \
  'The form that shares the header line, `{ pkgs, ... }: with pkgs;`, opens a file-wide scope and nothing says so — only the form nixfmt puts at column 0 is still caught'

defect body-keys-ignores-strings check-nix.sh \
  '      if (c == "\"") { instr = 1; i++; continue }' \
  '      if (c == "never") { instr = 1; i++; continue }' \
  'A brace inside a string is counted as nesting, so the keys a default.nix binds are read wrong and an aggregator is accused of configuring something'

defect namespace-reads-any-depth check-nix.sh \
  '      if (MODE == "ns" && want_ns && depth == 1) {' \
  '      if (MODE == "ns" && want_ns && depth >= 1) {' \
  'An options block inside a types.submodule is read as a namespace the repository declares, so a module gets a finding about a name it never chose and the rule teaches people to ignore it'

defect namespace-skips-lets-wrongly check-nix.sh \
  '      if (substr(s, i, 4) != "let ") return substr(s, i)' \
  '      if (substr(s, i, 4) != "never") return substr(s, i)' \
  'A module that binds cfg before its body — which is nearly all of them — is read as having no body at all, so every rule that asks what the body holds silently asks it of nothing'

# ---- the lock and the evaluation --------------------------------------------------------------

defect lock-shape-guard-off check-nix.sh \
  '((nodes >= 2)) ||' \
  '((nodes >= 0)) ||' \
  'A truncated or half-written flake.lock reads as a clean one, and the rule that watches for a local path override silently watches nothing'

defect static-still-evaluates check-nix.sh \
  '((static)) || check_eval' \
  'check_eval' \
  'The run inside the nix flake check sandbox tries to evaluate a flake whose inputs it cannot fetch, so the seam every consumer gets fails for a reason that is not theirs'

defect summary-hides-what-was-skipped check-nix.sh \
  '((unforced == 0)) || summary="$summary; an output needed inputs' \
  '((unforced == 1)) || summary="$summary; an output needed inputs' \
  'A run that could not evaluate the flake reports the same summary as one that could, so a shorter check reads as a complete one'
