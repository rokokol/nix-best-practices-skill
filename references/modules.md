# Modules

A module is a function that takes arguments it does not all name and returns an attribute set the module system merges with every other one. Everything below follows from that: the merge is what makes a module composable, and most mistakes are a module reaching around it.

## Which layer

Decide by what the thing touches, not by which file is open.

- **System** — boot, hardware, kernel, the GPU, networking, system-wide services, users, anything under `/etc` or a system unit
- **User** — the interactive environment, an application's own configuration, the shell, the desktop, per-user packages, a user unit

A user's editor configuration in a system module works and is wrong: it rebuilds the system closure to change a keybinding, and it cannot differ between users.

## An option is declared where it is acted on

```nix
{ config, lib, ... }:

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
    services.thing = {
      enable = true;
      inherit (cfg) port;
    };
  };
}
```

The module that declares `example.thing.enable` is the module that does something when it is on. A different module reaching for `config.services.foo.enable` to decide its own behaviour couples the two in a direction neither declares: the first knows nothing about the second, so removing the second leaves the first working by accident.

Give a repository's own options a namespace of their own rather than adding to one nixpkgs owns. An option declared under `services.` or `programs.` collides the day nixpkgs adds a module of that name, and the collision surfaces as a type error in a file that did not change.

`cfg` is bound when the configuration is read more than once. For a single read, `config.example.thing.enable` is shorter than the binding that shortens it.

## What `mkIf` is for, and what it is not

`lib.mkIf` defers the condition until the merge, so a module can depend on an option another module sets without either one forcing the other first. A plain `if` around a configuration block evaluates immediately and can close a cycle the module system would otherwise have resolved.

`lib.mkDefault` lowers a value's priority so a host can override it without `mkForce`; `lib.mkForce` raises it above everything. Both are worth a comment saying which definition they are arguing with, because neither says so itself.

## `default.nix` aggregates and nothing else

```nix
_:
{
  imports = [
    ./ai/ollama.nix
    ./desktop/portals.nix
    ./system/sops.nix
  ];
}
```

A file that both imports and configures is a file whose name says only half of what it does, and a reader looking for where something is set has to open every aggregator to find out. The repository root is the exception: a `default.nix` there is the entry a bare `nix-build` reaches for.

A module that names none of its arguments is written `_:` rather than `{ ... }:`. The two are interchangeable to the module system — a bare lambda still receives every module argument, `specialArgs` included — and `_:` is the one `statix` asks for, so the shorter form costs a rule nobody has to defend against the linter.

## Arguments a module did not ask for

A module receives whatever the evaluation was given. Constants that several modules need — a user name, a path, a palette, the flake's own `inputs` — are passed once, through `specialArgs` for NixOS and `extraSpecialArgs` for Home Manager, and pulled out of the arguments where they are wanted:

```nix
{ config, lib, palette, ... }:
```

A constant that lives instead in a `let` copied into several files is the same value with several owners, and they diverge in the direction of whichever was edited last.

## Home Manager as a NixOS module, and where an overlay goes

Home Manager can be loaded as a NixOS module. With `home-manager.useGlobalPkgs = true` it stops building a package set of its own and uses the system's, which has one consequence worth knowing before it is discovered:

**`nixpkgs.config` and `nixpkgs.overlays` inside a Home Manager module then do nothing.** Home Manager replaces those options with hidden placeholders and warns, naming the files that set them; setting both at once fails an assertion. The warning is easy to miss in a rebuild's output, and the symptom that brings someone looking is a package that does not have the override they wrote.

So under `useGlobalPkgs` there is one place for an overlay: the system's own `nixpkgs.overlays`. From there it reaches both layers, because there is only one package set. Without `useGlobalPkgs`, Home Manager builds its own set and its `nixpkgs.overlays` applies to the user layer alone — two sets, two overlay lists, and packages built twice.

There is no option under `home-manager.` for this. The options that exist there configure how Home Manager is loaded, not what it builds with.
