# `with` and `inherit`

Both bring names from an attribute set into view, and they differ in one way that decides every question below: `inherit` **declares** the names it brings, `with` only **offers** them.

## What `with` actually does

`with` puts its names in the weakest layer of the scope — weaker than `let`, weaker than a function's arguments, and regardless of which comes first in the text:

```
$ nix eval --impure --expr 'let a = 1; in with { a = 2; }; a'
1

$ nix eval --impure --expr 'with { b = "from-with"; }; let b = "from-let"; in b'
"from-let"
```

So `with lib;` at the top of a file does not import `lib`. It declares that *any* of lib's names, in this file, will lose to any local name that appears later. The set is not small: `nixpkgs.lib` has around five hundred names at its top level, and dozens of them are ordinary local names — `version`, `path`, `meta`, `types`, `options`, `optional`, `filter`, `head`, `last`, `count`, `match`, `trace`, `getExe`, `fix`, `id`, `min`, `max`.

Count them for a given nixpkgs with:

```nix
builtins.length (builtins.attrNames lib)
```

## What that costs

A collision is silent when the arity matches:

```nix
let
  lib = { optional = cond: x: if cond then [ x ] else [ ]; };
in
with lib;

let
  # added months later, three screens down: "always include it, cond can wait"
  optional = _cond: x: [ x ];
in
{
  packages = optional false "cuda-toolkit";
}
```

`lib.optional false` is `[ ]`. This evaluates to `[ "cuda-toolkit" ]`, with no error: the package is installed while the flag that was meant to gate it is off.

Written as `lib.optional false "cuda-toolkit"` there is nothing to shadow. Written as `inherit (lib) optional;` it does not evaluate at all — `inherit` declares the name, so a second definition beside it is a parse error:

```
error: attribute 'optional' already defined
```

That is the difference in one line: a name that is declared cannot be quietly replaced.

## Where `with` belongs

The body is one expression, visible whole, and binds nothing of its own.

```nix
home.packages = with pkgs; [
  curl
  dig
  jq
];
```

A flat list of packages. Every name in it is a package by construction, and there is nothing inside the literal for the scope to collide with. This is also the form a list of packages takes: naming `pkgs` once for the list rather than once per element is what the scope is for, and that holds at one element as much as at twenty.

```nix
meta = with lib; {
  description = "Pin images on top of everything on Wayland";
  license = licenses.mit;
  mainProgram = "pine";
  platforms = platforms.linux;
};
```

Five lines, all on screen, no `let` inside. nixpkgs has no settled position on this one; in this standard it is allowed, because the body cannot grow a binding without the reader seeing it happen.

```nix
type = with lib.types; either str (listOf str);
```

One expression inside one `mkOption`. The alternative spells `lib.types` three times for no gain.

```nix
type =
  with lib.types;
  attrsOf (oneOf [
    bool
    float
    int
    str
  ]);
```

The same case where the type does not fit a line.

## Where it does not

- **At the top of a file.** The body is the whole module, it will grow bindings, and every one of them takes a name from under the scope. This is the form the checker rejects
- **Over a `let`.** The same thing at a smaller size, and no less silent
- **Nested inside another `with`.** The inner one wins for a name both offer, which means reading either one requires reading both
- **Over a body that will grow.** The rule is about what the body becomes, not what it is today. A `with` over a two-line attrset is a `with` over a twenty-line attrset a year later, and nothing announces the crossing

## Keeping the brevity

```nix
{
  config,
  lib,
  pkgs,
  ...
}:

let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.example.thing;
in
{
  options.example.thing = {
    enable = mkEnableOption "the thing";
    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Loopback port the thing binds";
    };
  };

  config = mkIf cfg.enable { };
}
```

The names are as short as under `with lib;`, and they are declared: `deadnix` reports one that stops being used, a language server resolves each to its definition, and a typo is an error at evaluation rather than a name that quietly resolves to something else.

When a name is used once or twice, `lib.mkIf` needs no shortening at all.

## `inherit` on its own

`inherit (expr) a b;` is sugar for `a = expr.a; b = expr.b;`:

```
$ nix eval --impure --expr 'let p = { bare = "#1d1f21"; }; inherit (p) bare; in bare'
"#1d1f21"
```

Without parentheses, `inherit port;` means `port = port;` — take the name from the enclosing scope and bind it here under the same name:

```
$ nix eval --impure --expr 'let port = 9000; in { inherit port; }'
{ port = 9000; }
```

Both forms are how a value crosses into a smaller scope without being renamed on the way, and `x = x;` is never written instead — `statix` rewrites it.

## What the machine decides

A `with` at the file level and a `with` over a `let` are both findings. The first is caught two ways because one is not enough: the formatter puts it at column zero only when a `let … in` precedes it, and leaves the form that shares the argument header's line where it is.

Everything else here is read by a person. A scope that is narrow today and wide next year looks identical to the checker on the day it is written.
