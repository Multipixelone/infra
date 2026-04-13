{ inputs, ... }:
{
  flake-file.inputs.git-hooks = {
    url = "github:cachix/git-hooks.nix";
    inputs = {
      flake-compat.follows = "flake-compat";
      nixpkgs.follows = "nixpkgs";
    };
  };

  imports = [ inputs.git-hooks.flakeModule ];

  gitignore = [ "/.pre-commit-config.yaml" ];

  perSystem =
    { config, pkgs, ... }:
    {
      make-shells.default = {
        shellHook = config.pre-commit.installationScript;
        packages = [ pkgs.gitleaks ];
      };
      pre-commit.check.enable = false;
      pre-commit.settings.hooks.gitleaks = {
        enable = true;
        name = "gitleaks";
        entry = "gitleaks git --pre-commit --redact --staged --verbose";
        pass_filenames = false;
        language = "system";
      };
    };
}
