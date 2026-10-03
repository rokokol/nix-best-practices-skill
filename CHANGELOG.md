# Changelog

Kept in the shape of [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), dated rather than numbered, and with no `Unreleased` section — a skill is read at whatever revision you have checked out, so whatever is on the default branch is what everyone already has, and a section for work that has landed but not shipped would never close. The rule lives in the [versioning](https://github.com/rokokol/versioning-skill) skill, which owns what has no version

## 2026-10-03

### Added

- GitHub Actions workflows, which the repository never had: the `ci` badge in the README pointed at a `build.yml` that did not exist. `build.yml` runs `nix develop -c ./check.sh` on every push and pull request, and the gate now also lints the workflows with `actionlint` and `check-pins.sh`
- A `macos` workflow and its badge. `check-nix.sh` and `drv-diff.sh` claim the bash 3.2 macOS ships, and each now runs there under the real `/bin/bash` and the BSD userland, with its own planted defects. The claim used to rest on `check-sh.sh`'s static reading alone
- A weekly `vendor-sync` workflow, vendored from the [ci](https://github.com/rokokol/ci-skill) skill, takes the current revisions of the vendored checkers and lands them only when `build.yml` and `macos.yml` both pass on them

### Fixed

- Under the bash 3.2 that macOS ships, `check-nix.sh` said that a `meta.description` opening with a capital "starts lowercase". The rule tested a range, `[a-z]`, and bash 3.2 matches a range in the locale's collation order, where `H` sorts inside it. The rule now tests the `[[:lower:]]` class. The self-test judges each description again under en_US.UTF-8 with ASCII ranges turned off, when the machine has that locale, and a run without it says so in its summary
- On macOS 15 and later and on NixOS, `check-nix.sh` failed its own self-test with exit 127. The self-test proves that a machine without a tool is refused, and it dropped every `PATH` directory that held the tool. On macOS `/usr/bin` holds `jq` beside `mktemp`, and on NixOS `/run/current-system/sw/bin` holds `nix-instantiate` beside it, so the run died on `mktemp` first. The plant now takes away one command and keeps every other one. It now also covers `git`, which the checker already refused to run without
- In `references/comments.md` the `nixdoc` example holds a fenced block of its own, and its inner fence closed the outer one. The rest of the page then rendered as code, the heading "The comment that explains a deviation" included. The outer fence is four backticks now

## 2026-09-23

### Added

- `drv-diff.sh` answers the question a refactor makes and cannot check for itself: it evaluates every output of the flake here and at another revision and names the ones whose derivation path moved. `packages.${system}.drv-diff` is the same command for a consumer. Naming one output by hand answers a narrower question — measured across eleven repositories, `packages.default` matched everywhere while the movement was in `checks`, which that package does not depend on
- `lib.mkCheck` and `packages.${system}.check-nix` hand the checker out as flake outputs. Every consumer of a Nix checker is a Nix repository, so a copy of the script in each of them buys nothing an input does not, and the copy drifts
- `README.md` and this changelog

### Changed

- `file-kebab-case` judges the path of a `.nix` file and nothing else. Reading every tracked path gave 152 findings across sixteen repositories and not one true one: it fired on `Cargo.toml`, on a pytest `test_*.py`, on a zsh completion's leading underscore, on a systemd template unit's `@`, on an X11 cursor name and on an Obsidian note's title. Those names belong to Cargo, pytest, zsh, systemd, X11 and Obsidian, and the list of such conventions has no end
- The excuses in `check-nix.allow` are read back after every rule has run, so an excuse for the lock or for an evaluated output can be used at all; and a rule that did not run this invocation keeps its excuses, which is what the build sandbox does to the name rule

### Fixed

- A header is read only where a `}:` terminates one. A file that opened with `{` and never reached one went on collecting every line as a formal: measured on a `flake.nix`, 294 of them, two being the bare word `lib`, which made the `pkgs.lib` rule fire on three repositories whose flake takes no arguments at all
- The plant that proves a missing tool is refused steps aside in a copy that pins its own `PATH`, and the summary names which of the two ran. A wrapper builds such a copy, and the first `nix run` of the packaged checker died on a tree where nothing was wrong

## 2026-09-22

### Added

- The skill as it first went out: `SKILL.md`, nine references, and `check-nix.sh` with twenty rules on five grounds — the file name, the text after `nixfmt`, the canonical tree `nix-instantiate --parse` prints, the JSON a `flake.lock` already is, and the value an output evaluates to
- `tests/defects.sh` and the vendored `tests/t.sh` ask what the per-run falsification cannot: whether anything notices when the machinery beneath the rules stops working — the file walk, the tool preflight, the exemptions, the cache and the tokenisers
- `checks.<system>.nix-lint` gives the same rules to `nix flake check`, with `--static` leaving out what needs the flake's inputs and the summary naming that half
- `list-with-pkgs` rejects a list of nothing but `pkgs` attributes, and `options-namespaced` an option declared under a prefix the repository has not claimed

### Changed

- `statix`'s `empty_pattern` is on rather than disabled, and a module that names no argument is written `_:`. `{ ... }:` reads as "this module takes the usual arguments" where `_:` reads as "this one reads none of them"
