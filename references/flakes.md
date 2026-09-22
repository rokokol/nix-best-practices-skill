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

## The lock holds no local path

While an input is being worked on locally it is tempting to point at the checkout:

```nix
inputs.some-tool.url = "path:/home/<user>/Projects/some-tool";
```

That absolute path lands in `flake.lock`, and an ordinary `git add -A` commits it. Every other machine then fails on it:

```
error: path '/home/<user>/Projects/some-tool' does not exist
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
