# What the formatter settles, and what it leaves

`nixfmt` implements the standard Nix format. A repository declares it as its `formatter` output so that one command settles layout for everyone:

```nix
formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
```

`nixfmt-tree` is that formatter wrapped to walk a whole tree rather than the files it is handed, which is what makes `nix fmt` at the repository root mean the same thing as `nix fmt` in a subdirectory. `nixfmt-rfc-style` is an alias of the same binary and needs no separate mention

## What it decides, so nothing here does

- Two spaces per level, and indentation that follows the expression's structure rather than lining values up in a column
- A soft line width of 100; a string, a path or a URL may exceed it because breaking one changes it
- `let … in` always multiline, the `in` at the binding's own level, the body starting on its own line
- A nested attribute set always expanded, even when it would fit; a short list or set on one line when it holds few items
- Where a list wraps, where an argument list wraps, where an operator lands in a chain
- A single-line `/* … */` comment rewritten as `#`; a multiline one keeping its delimiters on lines of their own; `/* bash */` immediately before a string preserved, because that is the language annotation an editor highlights embedded code by

Run it in check mode where a gate needs an answer rather than a rewrite:

```sh
nix fmt -- --ci        # a repository with a formatter output
nixfmt --check FILE    # a directory with no flake
```

## What it keeps either way, so the author decides

The formatter preserves both of these, which means neither is settled by running it

**The order of a module's arguments.** The standard ones first, in this order, then everything else alphabetically, then `...`:

```nix
{
  config,
  lib,
  pkgs,
  osConfig,
  palette,
  ...
}:
```

A package is not a module and does not take this order. Its arguments come as nixpkgs writes them — `lib`, then the stdenv, then the fetchers, then what it builds against — and alphabetising would put `fetchFromGitHub` before `stdenvNoCC`, which no package does:

```nix
{
  lib,
  stdenvNoCC,
  fetchFromGitHub,
  sassc,
}:
```

The two are told apart by `...`: a module accepts arguments it does not name, a package names all of them

**Whether the arguments share a line.** Up to two go on one line, three or more go one per line:

```nix
{ config, lib, ... }:          # two
{                              # three
  config,
  lib,
  pkgs,
  ...
}:
```

**A comment's placement**, which the formatter moves nothing about. That has consequences past reading and is in [comments.md](comments.md)

**What a list is written against.** A list of nothing but `pkgs` attributes names `pkgs` once per element where the scope form names it once for the list; which lists that applies to, and which it must not, is in [scope.md](scope.md)

## When the formatter's own output moves

A new `nixfmt` can change what it produces, and a repository then goes red on files nobody edited. Bump the pin and land the reformat as its own commit, separate from any change in behaviour: a reformat mixed into a behaviour change hides the change from every future reader of that diff
