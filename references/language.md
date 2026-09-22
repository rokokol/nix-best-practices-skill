# The language

Most of the Nix language's own antipatterns are `statix`' to find, and are not restated here: an unquoted URL, a `let` that binds nothing, a binding of the form `a = a`, an eta-reducible lambda, parentheses around nothing. Running it is the way to know about those. What follows is what it does not look for

## Reading the machine instead of the lock

```nix
import <nixpkgs> { }              # reads $NIX_PATH
builtins.getEnv "SOME_VAR"        # reads the environment
```

A lookup path resolves through `$NIX_PATH`, which is set per machine and per shell, so the same expression evaluates differently in two places and identically in neither of them twice. `builtins.getEnv` is the same thing without the syntax. A flake exists to make the answer depend on the lock instead, and one of these undoes that for the whole file

`nix-channel` is the same again at the level of the system: a channel is mutable state outside the repository, and a configuration that depends on one cannot be reproduced from what is committed

When something genuinely must come from outside — a secret, a machine-local path — it arrives as an argument the caller supplies, not as a read the expression performs

## Two names for one thing

```nix
{ lib, pkgs, ... }:
{
  a = pkgs.lib.mkForce 1;   # the same lib, spelled the longer way
  b = lib.mkDefault 2;
}
```

Where `lib` is already an argument, `pkgs.lib` is a second route to it. They are the same value today; they stop being the same the moment an overlay touches `lib`, and then which one a line meant is decided by which one it happened to be written with

## `rec` and the shadowing it invites

```nix
let a = 1; in rec { a = a; }      # infinite recursion, not 1
```

Inside `rec`, a name refers to the set's own binding rather than to the enclosing scope, so a binding that shares a name with something outside quietly refers to itself. A `let` before the set expresses the same thing without the trap, and the error `rec` produces when it happens — `infinite recursion encountered` — points at the evaluation rather than at the line

## Merging attribute sets

```nix
{ a = { b = 1; }; } // { a = { c = 3; }; }
# => { a = { c = 3; }; }   — b is gone
```

`//` replaces a value rather than merging into it, one level deep. For a nested set that is almost never what was meant; `lib.recursiveUpdate` merges all the way down. In module code neither is usually needed at all — the module system's own merge is what combines definitions, and reaching for `//` there is a sign that something is being assembled outside the system that would assemble it

## Reading a build's output at evaluation time

Import-from-derivation is an expression whose value cannot be known until something is built:

```nix
import (pkgs.runCommand "generated" { } "… > $out")
```

Evaluation then has to stop and build in the middle, which makes `nix flake check` and every editor's evaluation slow and serial, and makes the result depend on what a builder produced rather than on what the source says. Where the generated thing is small and stable, commit it. Where it is not, produce it in a derivation that consumes it, so the build stays in the build

## Strings that are paths

```nix
"${inputs.self}/assets"    # a string that interpolates a store path
./assets                   # a path, copied to the store when a derivation takes it
```

A path literal in a flake is relative to the file and becomes a store path when something builds with it. A string that interpolates `inputs.self` names a location inside the flake's own store copy. Which one a place wants is decided by whether the value is read at evaluation time or consumed by a build; the second case has its own rule, in [packages.md](packages.md)
