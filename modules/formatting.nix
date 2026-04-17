{ inputs, ... }:
{
  imports = [ inputs.treefmt-nix.flakeModule ];

  flake-file.inputs.treefmt-nix = {
    url = "github:numtide/treefmt-nix";
    inputs.nixpkgs.follows = "nixpkgs";
  };

  perSystem =
    { config, ... }:
    {
      make-shells.default = {
        inputsFrom = [
          config.treefmt.build.devShell
        ];
      };
      treefmt = {
        inherit (config.flake-root) projectRootFile;
        enableDefaultExcludes = true;
        programs = {
          prettier.enable = true;
          shellcheck.enable = true;
          shfmt.enable = true;
        };
        settings = {
          on-unmatched = "fatal";
          global.excludes = [
            "*.jpg"
            "*.png"
            "Justfile"
            "LICENSE"
            "*.fish"
            "**/.gitkeep"
            "**/*.key"
            "**/*.crt"
            "**/*.gitmodules"
            "**/.direnv"
            "**/node_modules/*"
            "**/*.code-workspace"
            "pkgs/firefox-addons/generated.nix"
          ];
        };
      };
      pre-commit.settings.hooks.treefmt.enable = true;
    };
}
