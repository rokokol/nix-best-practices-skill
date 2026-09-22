# Sources

Every rule in this standard rests either on a document below or on a measurement anybody can repeat. Where a rule rests on a measurement, the command that produced it is beside the rule

## The language and its format

- **The standard Nix format** — [`standard.md`](https://github.com/NixOS/nixfmt/blob/master/standard.md) in `NixOS/nixfmt`, and [RFC 166](https://github.com/NixOS/rfcs/pull/166), which made it the official one. Between them they settle indentation, line width, the shape of `let … in`, when a set expands, and what becomes of each comment form
- **nix.dev's list of antipatterns** — [Best practices](https://nix.dev/guides/best-practices.html). The `with` scoping, the lookup paths, `rec`, `//` against `recursiveUpdate`, and the reproducible source path all come from here
- **RFC 45**, on deprecating the bare URL syntax, which is the reasoning behind quoting a URL and is what `statix explain W12` cites

## Packaging

- **nixpkgs' own contributor guide** — [`pkgs/README.md`](https://github.com/NixOS/nixpkgs/blob/master/pkgs/README.md). The grammar `meta.description` is held to, the rules for `pname` and `version`, the `0-unstable-YYYY-MM-DD` shape, and what `mainProgram`, `license` and `sourceProvenance` are for
- **nixpkgs' `CONTRIBUTING.md`**, for file layout and the commit conventions a contribution there follows

## The tools

- **`statix`** — [oppiliappan/statix](https://github.com/oppiliappan/statix). Its lints are documented by the tool itself: `statix explain <code>` prints what a lint does, why it matters and an example
- **`deadnix`** — [astro/deadnix](https://github.com/astro/deadnix), and `deadnix --help` for the flags that decide what counts as unused
- **`nixfmt`** — [NixOS/nixfmt](https://github.com/NixOS/nixfmt)

## What has no document

Several things in this standard are not written down anywhere upstream and are pinned by measurement instead:

- the canonical form `nix-instantiate --parse` prints, which is not a documented interface
- what the formatter preserves rather than decides, which is visible only by running it on both forms
- how Home Manager behaves under `useGlobalPkgs`, which is in its `modules/misc/` source rather than in its manual

For each of these the checker carries a probe that compares the current behaviour against the one the rules were written for, so a change upstream stops the run instead of passing it
