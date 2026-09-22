# Derivations

A package in a repository of one's own is held to the same shape as one in nixpkgs, because every tool that reads a package — a search, a shell completion, a licence audit, `nix run` — reads that shape and nothing else

## The name and the version

```nix
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "example-tool";
  version = "1.4.0";

  src = fetchFromGitHub {
    owner = "example";
    repo = "example-tool";
    tag = "v${finalAttrs.version}";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
  };
})
```

`pname` is the upstream name, lowercase, hyphenated as upstream hyphenates it. `version` starts with a digit. A commit with no release of its own takes `"0-unstable-YYYY-MM-DD"`, or `"X.Y-unstable-YYYY-MM-DD"` where there was a release to count from — that shape sorts correctly against real versions, which a bare date does not

`finalAttrs` is how the version reaches the source without being written twice. The alternative, a `let version = …` above the derivation, is the same value in two scopes, and only one of them is what `nix eval .#package.version` answers

## `meta`

```nix
meta = {
  description = "Pin images on top of everything on Wayland";
  homepage = "https://github.com/example/example-tool";
  license = lib.licenses.mit;
  mainProgram = "example-tool";
  platforms = lib.platforms.linux;
};
```

`description` is one sentence, and nixpkgs is specific about its grammar because every listing renders it in a row:

- capitalised
- no full stop at the end, and no other closing punctuation
- does not open with `A`, `An` or `The`
- does not open with the package's own name, which the row already shows
- says what the thing is rather than how good it is

`license` is set even when the answer is `lib.licenses.unfree`; an absent licence is not the same claim as an unknown one, and a tool auditing a closure cannot tell the difference

`mainProgram` is what `nix run` and `lib.getExe` resolve to. Without it they guess from `pname`, and the guess is wrong for every package whose binary is named differently. Write it as a literal string rather than as `pname`: the two agreeing today is not a reason to make one depend on the other

`platforms` says where it is expected to work. A package that names more platforms than it builds on turns every evaluation of those into a check that fails for a reason nobody will act on

`sourceProvenance` belongs on anything not built from source — `lib.sourceTypes.binaryNativeCode` for a repackaged binary — so a closure can be audited for what is in it

## Where a repository's own files come from

A derivation that takes its source from the repository around it must be given a filtered, named path:

```nix
src = builtins.path {
  name = "example-assets";
  path = "${inputs.self}/assets/example";
};
```

A bare `"${inputs.self}/assets/example"` ties the derivation's hash to the whole repository: every commit anywhere changes the source, so the package rebuilds and re-downloads on each. `builtins.path` with a fixed `name` isolates it to the directory that was asked for

The rule is about derivation inputs only. `imports = [ "${inputs.self}/modules/thing.nix" ]` needs no wrapping — a module is read at evaluation time and only the values it produces reach any derivation

`lib.fileset.toSource` is the same isolation expressed by what a file is rather than where it sits, which is what to reach for when the set is "every `.nix` file" rather than "this directory":

```nix
src = lib.fileset.toSource {
  root = ./.;
  fileset = lib.fileset.fileFilter (f: f.hasExt "nix") ./.;
};
```

## `callPackage`

```nix
packages = forAllSystems (pkgs: {
  default = pkgs.callPackage ./nix/package.nix { };
});
```

The package file names the arguments it wants and `callPackage` supplies them by name from the package set. That is why a package file's arguments are the packages it needs rather than a single `pkgs`: the ones it names are the ones an override can replace

## Ask the derivation, not the expression

What a package turns out to be is a different question from what its expression says, and the built derivation is the one that answers:

```sh
nix derivation show .#default | jq -r '.derivations[] | {
  name,
  outputs: (.outputs | keys),
  pname: .env.pname,
  version: .env.version,
  mainProgram: .env.NIX_MAIN_PROGRAM,
  system
}'
```

That is the value after every override, overlay and default has been applied, which is what a consumer gets. Reading the expression instead answers what one file intended, and the two differ exactly where an overlay is doing something — which is exactly when the question is being asked

`nix eval .#packages.<system>.<name>.meta` answers the same way for metadata, and is what a check on `meta` should read rather than grepping the file that wrote it
