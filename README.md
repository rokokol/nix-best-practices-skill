<div align="center">

# nix-best-practices skill

**What the formatter cannot check, and a checker that holds it ʕ•ᴥ•ʔ**

[![Agent Skill](https://img.shields.io/badge/Agent_Skill-6E56CF?style=flat)](https://agentskills.io)
![Nix](https://img.shields.io/badge/Nix-flake-7EBAE4?style=flat&logo=nixos&logoColor=white)
![Bash](https://img.shields.io/badge/Bash-4EAA25?style=flat&logo=gnubash&logoColor=white)
[![license](https://img.shields.io/badge/MIT-3DA639?style=flat)](LICENSE)
[![ci](https://github.com/rokokol/nix-best-practices-skill/actions/workflows/build.yml/badge.svg)](https://github.com/rokokol/nix-best-practices-skill/actions/workflows/build.yml)

</div>

`nixfmt` owns layout, `statix` owns the language's antipatterns and `deadnix` owns dead code. What none of them can see is the shape of a module header, the scope a `with` opens, whether a derivation says what it is, and whether a lock names a path that exists on one machine alone. Those are the rules this skill writes down, and `check-nix.sh` is the half a machine decides

The second thing those tools cannot see is time. A derivation's hash, an input's private copy, an option's path: each is correct on the machine that wrote it and wrong on the next one, or correct today and wrong after a rename upstream. Most of the rules here are about that gap rather than about taste

## Contents

- [Install](#install)
- [The core](#the-core)
- [The checker](#the-checker)
- [Did anything move](#did-anything-move)
- [Taking it into a repository](#taking-it-into-a-repository)
- [Tests](#tests)
- [Layout](#layout)

## Install

```bash
npx skills add -g rokokol/nix-best-practices-skill    # for you, everywhere
npx skills add rokokol/nix-best-practices-skill       # for the project you are standing in
```

Claude Code also takes it as a plugin:

```
/plugin marketplace add rokokol/skills
/plugin install nix-best-practices@rokokol-skills
```

or by hand — clone into whichever skills directory your agent reads:

```bash
git clone https://github.com/rokokol/nix-best-practices-skill ~/.claude/skills/nix-best-practices
```

> [!NOTE]
> A skill has no version to pin — it is read at whatever revision you have checked out, so `git pull` is the whole upgrade path and the changelog is dated rather than numbered

Then ask Claude Code to write, review or refactor Nix, or reach for it by name. [SKILL.md](SKILL.md) carries the rules and `references/` the reasoning and the measurements behind each

## The core

The rules live in [SKILL.md](SKILL.md#the-core), one line each, and each points at the reference that carries the mechanism: what [nixfmt](references/format.md) decides and what it leaves to you, the scope a [`with`](references/scope.md) opens and why `inherit` is the way out, [modules](references/modules.md) and where an option belongs, [flakes](references/flakes.md) and the hygiene of a lock, [packages](references/packages.md) and what a `meta` has to say, the rest of the [language](references/language.md), the [lint](references/lint.md) doctrine with the one disabled rule and its reason, what a [comment](references/comments.md) carries that Nix cannot, and the [sources](references/sources.md) behind all of it

## The checker

`check-nix.sh` runs the three tools and adds twenty rules of its own. Each rests on one of five grounds and on nothing softer: the file name, the text after `nixfmt`, the canonical tree `nix-instantiate --parse` prints, the JSON a `flake.lock` already is, and the value an output evaluates to. Ask `--list-rules` what it holds a tree to and `--help` what each flag does

`--static` leaves out the rules that need the flake's inputs, which is what the build sandbox has no network to fetch, and the summary names that half so a short run does not read as a complete one. `--template module`, `package` or `flake` prints the shape the rules describe, already assembled — and that shape is what the checker plants its defects into on every run

`check-nix.allow` carries what a repository knows and the checker cannot, one `ID PATH [TEXT]` per line. An entry that excuses nothing is itself a finding, so an excuse cannot outlive its reason

## Did anything move

`drv-diff.sh` answers the question a refactor makes and cannot check for itself. It evaluates every output of the flake here and at another revision — packages, checks, dev shells, the formatter, and the toplevel of every `nixosConfigurations` entry — and names the ones whose derivation path moved

Naming one output by hand answers a narrower question. Measured across eleven repositories on the day it was written: `packages.default` matched everywhere, and the movement was in `checks`, which that package does not depend on. Asking the whole flake found it, and found that one repository's check held the entire repository, so an edit to its README rebuilt it

An untracked `.nix` file stops the run rather than being skipped. A flake reads what git tracks, so both sides would lack the change and the answer would be "nothing moved" about an edit neither side read

## Taking it into a repository

Every consumer of a Nix checker is a Nix repository, so it arrives as an input rather than as a copy of a script:

```nix
inputs.nix-best-practices.url = "github:rokokol/nix-best-practices-skill";
```

`lib.mkCheck` builds the sandboxed check a repository puts in its own `checks`, so a local `nix flake check` asks it before anything is pushed:

```nix
checks.${system}.nix-lint = inputs.nix-best-practices.lib.mkCheck {
  pkgs = nixpkgs.legacyPackages.${system};
  root = ./.;
  namespaces = [ "rokokol" ];          # the prefixes this repository declares options under
};
```

`packages.${system}.check-nix` and `packages.${system}.drv-diff` are the two commands, for the rules the sandbox cannot reach and for the question it does not ask

## Tests

`nix develop -c ./check.sh` runs the gate in two halves, because they ask different questions. The lint half holds the scripts, the flake and the documents to their rules, and runs the checker over this repository both directly and through `nix flake check`, which is the seam every consumer gets. The behaviour half gives the checker trees it did not build and requires each to be rejected for its own defect

On top of that, every run of `check-nix.sh` plants one defect per rule into fixtures it prints itself and requires each to be rejected for that defect's own stated reason — a copy therefore falsifies itself wherever it runs. `tests/defects.sh` asks the other question: it breaks the machinery beneath the rules — the file walk, the tool preflight, the exemptions, the tokenisers — and requires the suite to notice

## Layout

```
SKILL.md              the core, the checker, what to run and when
check-nix.sh          the checker: twenty rules on five grounds, each proven able to fail on every run
drv-diff.sh           did this change move any derivation, here against another revision
references/           one page per subject: format, scope, modules, flakes, packages, language, lint, comments; sources.md for the evidence
check.sh              this repo's own gate, in a lint half and a behaviour half
tests/defects.sh      the machinery beneath the rules, broken one guard at a time
tests/t.sh            the falsification harness, vendored from the tests skill
check-sh.sh           the shell standard's checker, vendored from bash-best-practices
check-skill.sh        the gate every skill repository shares, vendored from skill-authoring
check-pins.sh         the pin guard for the workflows, vendored from the ci skill
check-changelog.sh    the changelog checker, vendored from the versioning skill
vendor-sync.sh        keeps the vendored copies byte-equal to their source, vendored from the ci skill
```
