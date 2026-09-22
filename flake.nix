{
  description = "A standard for Nix: what the formatter cannot check, and a checker that holds it";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      inherit (nixpkgs) lib;
      # Darwin is here because the checker travels to repositories that run CI on macOS.
      # A contributor there runs `nix develop -c ./check.sh`.
      # Apple silicon only: nixpkgs 26.11 dropped x86_64-darwin.
      # The gate refuses a platform that the flake cannot evaluate.
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forAllSystems = f: lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # This dev shell pins the tools for check.sh and check-nix.sh, locally and in CI.
      # A check takes each tool from here, never from the runner.
      # An unpinned lookup changes what a check does while the repository stays the same.
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [
            actionlint
            # check-nix.sh reads flake.lock as JSON. It does not grep the file
            jq
            # This entry names nixfmt, because `nix fmt` needs a flake.
            # The checker also runs on a directory that has no flake.
            # A repository's own formatter wraps this same binary with treefmt
            nixfmt
            shellcheck
            shfmt
            # The checker calls these two linters. It does not repeat their work
            deadnix
            statix
          ];
        };
      });

      # This check gives the same rules to `nix flake check`.
      # A repository that runs that command needs no second command.
      # --static leaves out each rule that needs the flake's inputs.
      # The summary names that half, so a short run does not look complete
      checks = forAllSystems (pkgs: {
        nix-lint =
          pkgs.runCommand "nix-lint"
            {
              nativeBuildInputs = with pkgs; [
                deadnix
                # git walks a repository's file list, and git builds the fixture for the
                # falsification pass. Neither task happens here.
                # The checker still refuses a machine that lacks a tool it names
                git
                jq
                nix
                nixfmt
                statix
              ];
              # This source holds only what the checker reads.
              # An edit to a document does not rebuild it
              src = lib.fileset.toSource {
                root = ./.;
                fileset = lib.fileset.unions [
                  (lib.fileset.fileFilter (f: f.hasExt "nix") ./.)
                  ./flake.lock
                ];
              };
            }
            ''
              # nix-instantiate --parse needs no store and no daemon.
              # It still creates its state directory at startup, and the sandbox HOME is read-only.
              # Measured: without these variables it fails at startup, not on the expression
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
