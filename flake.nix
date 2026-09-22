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

      # The tools the checker calls, in one list. The package and the check then agree,
      # and a tool added for a new rule reaches both
      checkerTools =
        pkgs: with pkgs; [
          deadnix
          # git walks a repository's file list, and git builds the fixture for the
          # falsification pass. Neither task happens inside the sandbox.
          # The checker still refuses a machine that lacks a tool it names
          git
          jq
          nix
          nixfmt
          statix
        ];

      # What a consumer takes. A Nix repository adds this flake as an input and gets the
      # checker out of the store, so no repository carries a copy of the script.
      # This repository's own check goes through it too. A consumer and the author then run
      # one seam, and a break in it shows here first
      mkCheck =
        {
          pkgs,
          root,
          namespaces ? [ ],
        }:
        let
          has = p: builtins.pathExists (root + p);
        in
        pkgs.runCommand "nix-lint"
          {
            nativeBuildInputs = checkerTools pkgs;
            # Only what the checker reads. An edit to a document does not rebuild it.
            # check-nix.allow belongs here: without it every excused finding comes back
            src = lib.fileset.toSource {
              inherit root;
              fileset = lib.fileset.unions (
                [ (lib.fileset.fileFilter (f: f.hasExt "nix") root) ]
                ++ lib.optional (has "/flake.lock") (root + "/flake.lock")
                ++ lib.optional (has "/check-nix.allow") (root + "/check-nix.allow")
              );
            };
          }
          ''
            # nix-instantiate --parse needs no store and no daemon.
            # It still creates its state directory at startup, and the sandbox HOME is read-only.
            # Measured: without these variables it fails at startup, not on the expression
            export HOME=$TMPDIR/home NIX_STATE_DIR=$TMPDIR/state NIX_CONF_DIR=$TMPDIR/conf
            export NIX_DATA_DIR=$TMPDIR/data NIX_LOG_DIR=$TMPDIR/log XDG_CACHE_HOME=$TMPDIR/cache
            mkdir -p "$HOME" "$NIX_STATE_DIR" "$NIX_CONF_DIR" "$NIX_DATA_DIR" "$NIX_LOG_DIR" "$XDG_CACHE_HOME"
            bash ${./check-nix.sh} --static ${
              lib.concatMapStringsSep " " (n: "-N ${lib.escapeShellArg n}") namespaces
            } -C $src
            touch $out
          '';
    in
    {
      # A consumer's `nix flake check` gets the same rules from here.
      # --static leaves out each rule that needs the flake's inputs, because the sandbox
      # has neither the network nor the store to fetch them
      lib = { inherit mkCheck; };

      # The same checker as a command, for the half --static leaves out.
      # A consumer runs it where the inputs are available, which is a plain CI step
      packages = forAllSystems (pkgs: {
        check-nix = pkgs.writeShellApplication {
          name = "check-nix";
          runtimeInputs = checkerTools pkgs;
          text = builtins.readFile ./check-nix.sh;
          meta = {
            description = "Holds Nix sources to what the formatter cannot check";
            homepage = "https://github.com/rokokol/nix-best-practices-skill";
            license = lib.licenses.mit;
            mainProgram = "check-nix";
            platforms = systems;
          };
        };

        # nix-diff is in the runtime inputs rather than optional here. A command a consumer
        # runs by name should explain a move, and the script still works without it
        drv-diff = pkgs.writeShellApplication {
          name = "drv-diff";
          runtimeInputs = with pkgs; [
            git
            jq
            nix
            nix-diff
          ];
          text = builtins.readFile ./drv-diff.sh;
          meta = {
            description = "Says whether a change moved any derivation of a flake";
            homepage = "https://github.com/rokokol/nix-best-practices-skill";
            license = lib.licenses.mit;
            mainProgram = "drv-diff";
            platforms = systems;
          };
        };
      });

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
            # drv-diff.sh reports a move without it and explains one with it
            nix-diff
          ];
        };
      });

      # The summary names the half --static left out, so a short run does not look complete
      checks = forAllSystems (pkgs: {
        nix-lint = mkCheck {
          inherit pkgs;
          root = ./.;
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
