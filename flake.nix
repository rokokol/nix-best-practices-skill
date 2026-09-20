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

      formatter = forAllSystems (pkgs: pkgs.nixfmt-tree);
    };
}
