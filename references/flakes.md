# Flakes and the lock

A flake's inputs are fetched once and recorded in `flake.lock`, and everything that reads the flake afterwards reads the lock. So the lock is the thing to be careful about: it is what travels, and it is what describes either a project or one computer

## Inputs

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  some-tool = {
    url = "github:owner/some-tool";
    inputs.nixpkgs.follows = "nixpkgs";
  };
};
```

An input that declares a `nixpkgs` of its own and is not told to follow yours brings a second copy: a second fetch, a second evaluation, and two package sets whose versions differ. `follows` points it at the one already here

Not every input has a `nixpkgs` to follow. A data-only flake has no inputs at all; a helper flake may take nothing but `systems`. Asking for `follows` on those is asking for something that does not exist, so the thing to check is the outcome rather than the declaration

The outcome is visible in the lock. A followed input is recorded as an array, a private copy as a string:

```json
"some-tool": { "inputs": { "nixpkgs": ["nixpkgs"] } }
"other-tool": { "inputs": { "nixpkgs": "nixpkgs_2" } }
```

A suffixed node name — `nixpkgs_2`, `ddlc-palette_2` — is a second copy of something the rest of the flake shares. For `nixpkgs` the cost is download and evaluation. For an input that exists precisely to be a single source of truth, such as a palette or a shared set of constants, the cost is that the two copies drift and every consumer of each is internally consistent while disagreeing with the other. Nothing reports that; both builds succeed

An input that pins its own `nixpkgs` and warns when overridden is a legitimate second copy. Write the reason in a comment above the input, where the next reader meets it

## A flake reads what git tracks, and nothing else

A flake in a git repository takes its source from git, so a file nobody has staged is not there at all. Nix says so when an expression reaches for one:

```
error: Path 'tests/no-secrets.sh' in the repository "…" is not tracked by Git
```

That error is the good case. The bad one is silence: a check that walks the source and finds nothing to object to passes, and a comparison of two revisions reports that nothing moved, both of them about a file neither side ever read. A new module is the common shape — written, evaluated in the editor, never staged

`git add -N` is enough, and it stages no content. Measured: before it the flake's source holds `flake.nix` alone; after it, the new file is there

`path:.` is the other way to be seen, and it is worse: it takes the directory as it is, `.git` included, so the source changes with every commit and the store copy carries the whole history

## The lock holds no local path

While an input is being worked on locally it is tempting to point at the checkout:

```nix
inputs.some-tool.url = "path:/srv/checkouts/some-tool";
```

That absolute path lands in `flake.lock`, and an ordinary `git add -A` commits it. In practice the path is usually under a home directory, which narrows it to one account as well as one machine. Every other machine then fails on it:

```
error: path '/srv/checkouts/some-tool' does not exist
```

The machine that wrote it keeps working, because the content is already in its store and the path is no longer needed to find it. So the break is invisible where it was made and visible only to everyone else

Relative paths are a different thing and are fine: those are subflakes of the repository and travel with it

## Outputs

```nix
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

    formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
  };
```

`inherit (nixpkgs) lib;` rather than `lib = nixpkgs.lib;` — the second is the shape `statix` rewrites

The caller always passes `self`, whether or not the outputs read it. So a formal list with no `...` has to name it, and a named argument nothing reads is what `deadnix` objects to. Removing the name is not the answer — the flake then refuses to evaluate:

```
error: function 'outputs' called with unexpected argument 'self'
```

`...` accepts it and reads nothing, which is the honest shape for a flake that does not need its own outputs. An underscore does not work here, because the caller passes the name `self` and a formal called `_self` is a different name

Name only the systems the flake can actually be evaluated for. A platform in the list that nothing there supports is a check that fails for a reason nobody will act on

A `formatter` output is what makes `nix fmt` mean anything in the repository; without it the command does nothing and a gate has nothing to run

## Overlays

An overlay is a function of two arguments whether or not it uses them:

```nix
overlay-stable = _final: _prev: {
  stable = import nixpkgs-stable { inherit system; };
};
```

The underscore prefix is what tells `deadnix` the arguments are unused on purpose. Writing `_: _:` silences it too and loses the names that make the function recognisable as an overlay at a glance

## Assertions the lock cannot make for itself

`flake.lock` is JSON, and a flake can read its own:

```nix
let
  lock = builtins.fromJSON (builtins.readFile ./flake.lock);
  duplicated = builtins.filter (n: builtins.match "shared-input_[0-9]+" n != null) (builtins.attrNames lock.nodes);
in
assert duplicated == [ ] || throw "flake.lock holds ${builtins.concatStringsSep ", " duplicated} — an input is missing its shared-input.follows";
```

This evaluates offline and without forcing any input, so it costs nothing and runs everywhere the flake is evaluated — on a rebuild, on `nix eval`, before a push rather than after one. A check that lives only in CI answers after the work has left the machine

## What `nix flake check` is for

For a configuration repository it is the closest thing to a test suite: it evaluates every output, which is where a bad option name, a type error or a missing attribute surfaces. It also builds whatever is under `checks`, so a repository can put its own gates there and get them from one command

It substitutes from the binary cache like any Nix build. Running it with `--offline` forbids that, which turns the first change to any check derivation into a build from source of everything that derivation depends on
