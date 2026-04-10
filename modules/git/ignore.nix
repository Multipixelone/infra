{
  config,
  inputs,
  lib,
  ...
}:
{
  options.gitignore = lib.mkOption {
    type = lib.types.listOf lib.types.str;
  };

  config.gitignore = [
    "/.claude/settings.local.json"
  ];

  config.flake-file.inputs = {
    github-gitignore = {
      url = "github:github/gitignore";
      flake = false;
    };
    ignoreBoy = {
      url = "github:Ookiiboy/ignoreBoy";
      inputs.gitignore-repo.follows = "github-gitignore";
    };
  };

  config.perSystem =
    { system, ... }:
    {
      files.files = [
        {
          path_ = ".gitignore";
          drv = inputs.ignoreBoy.lib.${system}.generateGitIgnore {
            # https://github.com/github/gitignore — filenames (sans extension)
            github.languages = [
              "Nix"
            ];

            # https://www.toptal.com/developers/gitignore/
            # `curl -sL https://www.toptal.com/developers/gitignore/api/list`
            gitignoreio.languages = [ ];

            extraConfig = config.gitignore |> lib.naturalSort |> lib.concatLines;
          };
        }
      ];

      treefmt.settings.global.excludes = [ "*/.gitignore" ];
    };
}
