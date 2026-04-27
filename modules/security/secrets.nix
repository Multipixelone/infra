{
  inputs,
  ...
}:
let
  polyModule = {
  };
in
{
  flake-file.inputs = {
    secrets = {
      url = "git+ssh://git@github.com/Multipixelone/nix-secrets.git";
      flake = false;
    };
    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        home-manager.follows = "home-manager";
        systems.follows = "systems";
      };
    };
  };

  flake.modules = {
    nixos.base = {
      imports = [
        inputs.agenix.nixosModules.default
        polyModule
      ];
      # agenix.homeManagerIntegration.autoImport = false;
    };

    homeManager.base =
      { pkgs, ... }:
      {
        imports = [
          inputs.agenix.homeManagerModules.default
          polyModule
        ];
        home.packages = [
          inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
        ];
        age = {
          identityPaths = [
            "/home/tunnel/.ssh/agenix"
          ];
          secretsDir = "/home/tunnel/.secrets";
        };
      };

    # nixOnDroid.base = {
    #   imports = [
    #     inputs.agenix.nixOnDroidModules.agenix
    #     polyModule
    #   ];
    # };

    # nixvim.base = nixvimArgs: {
    #   # https://github.com/danth/agenix/pull/415#issuecomment-2832398958
    #   imports = lib.optional (
    #     nixvimArgs ? homeConfig
    #   ) nixvimArgs.homeConfig.agenix.targets.nixvim.exportedModule;
    # };
  };
}
