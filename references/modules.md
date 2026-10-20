# Modules

A module is a function that takes arguments it does not all name and returns an attribute set the module system merges with every other one. Everything below follows from that: the merge is what makes a module composable, and most mistakes are a module reaching around it

## Which layer

Decide by what the thing touches, not by which file is open

- **System** — boot, hardware, kernel, the GPU, networking, system-wide services, users, anything under `/etc` or a system unit
- **User** — the interactive environment, an application's own configuration, the shell, the desktop, per-user packages, a user unit

A user's editor configuration in a system module works and is wrong: it rebuilds the system closure to change a keybinding, and it cannot differ between users

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

The module that declares `example.thing.enable` is the module that does something when it is on. A different module reaching for `config.services.foo.enable` to decide its own behaviour couples the two in a direction neither declares: the first knows nothing about the second, so removing the second leaves the first working by accident

Give a repository's own options a namespace of their own rather than adding to one nixpkgs owns. An option declared under `services.` or `programs.` collides the day nixpkgs adds a module of that name, and the collision surfaces as a type error in a file that did not change

`cfg` is bound when the configuration is read more than once. For a single read, `config.example.thing.enable` is shorter than the binding that shortens it

## What `mkIf` is for, and what it is not

`lib.mkIf` defers the condition until the merge, so a module can depend on an option another module sets without either one forcing the other first. A plain `if` around a configuration block evaluates immediately and can close a cycle the module system would otherwise have resolved

`lib.mkDefault` lowers a value's priority so a host can override it without `mkForce`; `lib.mkForce` raises it above everything. Both are worth a comment saying which definition they are arguing with, because neither says so itself

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

A file that both imports and configures is a file whose name says only half of what it does, and a reader looking for where something is set has to open every aggregator to find out. The repository root is the exception: a `default.nix` there is the entry a bare `nix-build` reaches for

A module that names none of its arguments is written `_:` rather than `{ ... }:`. The two are interchangeable to the module system — a bare lambda still receives every module argument, `specialArgs` included — and `_:` is the one `statix` asks for, so the shorter form costs a rule nobody has to defend against the linter

## Arguments a module did not ask for

A module receives whatever the evaluation was given. Constants that several modules need — a user name, a path, a palette, the flake's own `inputs` — are passed once, through `specialArgs` for NixOS and `extraSpecialArgs` for Home Manager, and pulled out of the arguments where they are wanted:

```nix
{ config, lib, palette, ... }:
```

A constant that lives instead in a `let` copied into several files is the same value with several owners, and they diverge in the direction of whichever was edited last

## Home Manager as a NixOS module, and where an overlay goes

Home Manager can be loaded as a NixOS module. With `home-manager.useGlobalPkgs = true` it stops building a package set of its own and uses the system's, which has one consequence worth knowing before it is discovered:

**`nixpkgs.config` and `nixpkgs.overlays` inside a Home Manager module then do nothing.** Home Manager replaces those options with hidden placeholders and warns, naming the files that set them; setting both at once fails an assertion. The warning is easy to miss in a rebuild's output, and the symptom that brings someone looking is a package that does not have the override they wrote

So under `useGlobalPkgs` there is one place for an overlay: the system's own `nixpkgs.overlays`. From there it reaches both layers, because there is only one package set. Without `useGlobalPkgs`, Home Manager builds its own set and its `nixpkgs.overlays` applies to the user layer alone — two sets, two overlay lists, and packages built twice

There is no option under `home-manager.` for this. The options that exist there configure how Home Manager is loaded, not what it builds with

## Storage the disk layout declares

A subvolume or a filesystem that the disk layout declares is made by the layout alone. The module that keeps data there exports what it needs as a read-only option, such as `subvolumes`, and the layout reads it: one list, two readers. The module never makes the path as a fallback. A fallback `btrfs subvolume create` is a second definition of the layout, and a fallback `mkdir` is worse: on a disk where the subvolume is missing it makes a plain directory, which a snapshot tool cannot snapshot, and nothing says so

At start the module sets only what the layout has no option for, such as the owner and the mode, with `chown` and `chmod` on a path that must already exist. A missing path then fails the unit, and a failed unit is an alert. On a host installed before the module, the path is made once by hand; a reinstall makes it from the layout

## Data on a volume that may be absent

A volume mounted with `nofail` may be missing at boot, and a unit that writes to its mountpoint then writes to the root filesystem below it

- Every unit that touches the volume carries `RequiresMountsFor` for its path and `ConditionPathIsMountPoint` for the mountpoint: the service, its socket, and the service of every snapshot or backup timer. A socket without them accepts a connection and fails it, and a service without them writes below the mountpoint on a manual start
- No `systemd.tmpfiles` rule names a path on the volume: tmpfiles runs at boot whether or not the volume is mounted, and makes what it was told to on the root filesystem
- Snapshots of the data sit on the same volume, as subvolumes the layout declares, taken by a timer with the same conditions. They undo a deletion, not the loss of the disk

## Data is not configuration

What a service keeps for its users — calendars, repositories, accounts, mailboxes — lives in its data, and the snapshots and backups keep it there. Declaring it again in Nix makes a second source of truth. The two drift on the first change a client makes: a renamed calendar, a deleted repository. Restoring a backup then disagrees with the configuration, and one of them has to win in silence. The configuration declares the service, the storage it needs and who may reach it. A client makes the data once, and the backup carries it from then on
