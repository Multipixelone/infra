{ inputs, lib, ... }:
{
  # Bare-metal installer. `nix run .#nixos-anywhere` partitions the target with
  # the host's own disko module and installs its toplevel over SSH, so the
  # sequence in docs/new-host.md runs from the pinned flake instead of being
  # reconstructed by hand each time.
  #
  # Follows are spelled out per input rather than left to auto-pruning, and only
  # the ones nixos-anywhere actually declares are listed — it has no
  # `flake-parts` input, and `nixos-stable` keeps its own pin because it is a
  # stable channel, not this flake's unstable `nixpkgs`.
  flake-file.inputs.nixos-anywhere = {
    url = "github:nix-community/nixos-anywhere";
    inputs = {
      nixpkgs.follows = "nixpkgs";
      disko.follows = "disko";
      treefmt-nix.follows = "treefmt-nix";
    };
  };

  # Exposed as an app rather than a package: modules/package-checks.nix turns
  # every `packages` entry into a flake check, and the installer is a tool the
  # operator runs, not an artifact CI should build.
  perSystem =
    { system, ... }:
    {
      apps.nixos-anywhere = {
        # getExe' rather than the bare package: nixos-anywhere sets no
        # meta.mainProgram, and the resulting getExe warning is fatal under this
        # flake's abort-on-warn.
        program = lib.getExe' inputs.nixos-anywhere.packages.${system}.nixos-anywhere "nixos-anywhere";
        meta.description = "Install a declared host onto bare metal over SSH (see docs/new-host.md).";
      };
    };
}
