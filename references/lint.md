# The three tools, and where their versions come from

Three programs decide most of what can be decided about Nix source, and they divide the work cleanly enough that nothing here needs to repeat any of them

| Tool | What it owns |
|---|---|
| `nixfmt` | layout: indentation, line breaks, where a list wraps, what becomes of a block comment |
| `statix` | the language's own antipatterns, one per lint, each with a code and an explanation |
| `deadnix` | bindings, lambda arguments and inherits that nothing reads |

What none of them sees is the module system, the repository, the lock and the file names — which is what is left for a checker of one's own

## Reading a `statix` finding

Each lint explains itself, with the reasoning and usually a source:

```sh
statix explain W12      # the lint behind a finding
statix check -o errfmt  # one finding per line: FILE>LINE:COL:SEVERITY:CODE:message
statix fix              # rewrites what it can
```

`fix` does not perform every lint — some only report — so a clean `fix` run is not a clean `check` run

Coverage is by pattern rather than exhaustive: a shape that does not match one of its patterns goes unreported even when it is the thing the lint is about. "statix is clean" means no pattern matched, not that the language is used well

## One lint stays off

`repeated_keys` asks for options whose paths share a first segment to be gathered into one nested set. In a module that first segment is an address into the global option tree rather than a structure the author chose, so the lint groups by string prefix against a file grouped by subject — and the module system merges definitions across files anyway, which is what the nesting would be imitating

Everything else it reports is worth acting on, including the two that overlap with rules people write by hand: `a = a` and `a = someAttr.a` are `inherit` and `inherit (someAttr)`, and are the linter's to find rather than a convention to remember

## Where a check's tools come from

In a check, from the repository's own lock:

```nix
devShells = forAllSystems (pkgs: {
  default = pkgs.mkShell {
    packages = with pkgs; [
      deadnix
      nixfmt
      statix
    ];
  };
});
```

and the gate is run as `nix develop -c ./check.sh`

`nix run nixpkgs#statix` is the other way, and it belongs to one-off work rather than to a check. It resolves against whatever the registry points at today, so the same command is a different program next week: a check that starts failing without a commit, or stops catching something without one. For a question asked once by a person, that is fine and convenient

A missing tool is a refusal rather than a quieter run. An extractor that finds nothing must never read as nothing having drifted, so the answer to a machine without `deadnix` is to say so and stop, not to report a clean tree

## When a tool's output moves

Both the formatter's output and the parser's re-printed form are things a release can change, and a checker that greps either is reading an undocumented shape. The way to hold that is to pin it: one probe expression, compared to what it produced when the rules were written, checked before any rule reads a line. A release that moves the shape then stops the run and shows what it now prints, rather than passing checks that have quietly stopped matching anything
