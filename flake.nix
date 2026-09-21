{
  description = "A standard for Nix: what the formatter cannot check, and a checker that holds it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      # Darwin too: the checker travels to repositories that run CI on macOS, and a
      # contributor there gets `nix develop -c ./check.sh` rather than a flake that does
      # not know their system. Apple silicon only — nixpkgs 26.11 dropped x86_64-darwin,
      # and naming a platform the flake cannot be evaluated for is what the gate refuses.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # The pinned toolbox for check.sh and for check-nix.sh, locally and in CI. Every tool
      # a check runs comes from here rather than from whatever the runner happens to have:
      # an unpinned lookup changes a check's behaviour with zero change in the repository
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            actionlint
            # check-nix.sh reads flake.lock as the JSON it is, rather than grepping it
            jq
            # Named rather than taken from `nix fmt`: the checker runs on a directory that
            # may have no flake at all, and a repository's own formatter output is the
            # treefmt wrapper around this same binary
            nixfmt
            shellcheck
            shfmt
            # The two linters the checker dispatches to instead of reimplementing them
            deadnix
            statix
          ];
        };
      });

      # The same rules under `nix flake check`, so a repository that already runs that gets them
      # without a second command to remember. What it cannot do is say so out loud rather than
      # quietly: --static leaves out everything that would need the flake's inputs, and the
      # summary names that half instead of letting a shorter run read as a complete one
      checks = forAllSystems (pkgs: {
        nix-lint =
          pkgs.runCommand "nix-lint"
            {
              nativeBuildInputs = [
                pkgs.deadnix
                # The walk over a repository's own file list is git's, and so is the fixture the
                # falsification pass builds; neither is here, but the checker refuses a machine
                # missing a tool it names rather than discovering it halfway through
                pkgs.git
                pkgs.jq
                pkgs.nix
                pkgs.nixfmt
                pkgs.statix
              ];
              # Only what the checker reads, so an edit to a document does not rebuild this
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  (lib.fileset.fileFilter (f: f.hasExt "nix") ./.)
                  ./flake.lock
                ];
              };
            }
            ''
              # nix-instantiate --parse needs no store and no daemon, but it does create its state
              # directory on the way in, and the sandbox's HOME is not writable. Measured: without
              # these it fails on startup rather than on the expression it was given
              export HOME=$TMPDIR/home NIX_STATE_DIR=$TMPDIR/state NIX_CONF_DIR=$TMPDIR/conf
              export NIX_DATA_DIR=$TMPDIR/data NIX_LOG_DIR=$TMPDIR/log XDG_CACHE_HOME=$TMPDIR/cache
              mkdir -p "$HOME" "$NIX_STATE_DIR" "$NIX_CONF_DIR" "$NIX_DATA_DIR" "$NIX_LOG_DIR" "$XDG_CACHE_HOME"
              bash ${./check-nix.sh} --static -C $src
              touch $out
            '';
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
