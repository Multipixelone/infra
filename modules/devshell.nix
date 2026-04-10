{ inputs, config, ... }:
{
  flake-file.inputs.make-shell = {
    url = "github:nicknovitski/make-shell";
    inputs.flake-compat.follows = "flake-compat";
  };
  imports = [ inputs.make-shell.flakeModules.default ];

  perSystem =
    { pkgs, ... }:
    {
      make-shells.default.name = config.flake.meta.repo.name;

      files.files = [
        {
          path_ = ".envrc";
          drv = pkgs.writeText ".envrc" ''
            #!/usr/bin/env sh
            # shellcheck shell=bash

            # This file is generated. Do not edit by hand.
            # Regenerate with: nix run .#generate-files

            use flake
            #use flake path:. --impure

            dotenv_if_exists .env.private
            source_env_if_exists .envrc.private
          '';
        }
      ];
    };
}
