{ config, lib, ... }:
{
  # The darwin host builds its own nixpkgs instance and bypasses the
  # flake-parts perSystem pkgs (modules/nixpkgs/instance.nix). Reuse the
  # repo's aggregated allow-lists so unfree/insecure packages stay declarative
  # and in sync with the NixOS hosts.
  configurations.darwin.hylia.module = {
    nixpkgs.config = {
      allowUnfreePredicate =
        pkg: builtins.elem (lib.getName pkg) config.nixpkgs.config.allowUnfreePackages;
      allowInsecurePredicate =
        pkg: builtins.elem (lib.getName pkg) config.nixpkgs.config.permittedInsecurePackages;
    };

    # Share package fixes with the flake's other nixpkgs instances, including
    # the FastMCP override that keeps it on the compatible MCP SDK 1.x.
    nixpkgs.overlays = config.nixpkgs.overlays ++ [
      # Codex's managed-preferences synchronization fails inside Darwin builds.
      # Keep the install-time version check; run the test suite on Linux.
      (_final: prev: {
        codex-acp = prev.codex-acp.overrideAttrs { doCheck = false; };

        # Darwin cannot copy sockets; keep the rest of xcp's test suite enabled.
        xcp = prev.xcp.overrideAttrs (old: {
          cargoCheckFeatures = (old.cargoCheckFeatures or [ ]) ++ [ "test_no_sockets" ];
        });
      })
    ];
  };
}
