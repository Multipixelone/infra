{
  inputs,
  config,
  withSystem,
  lib,
  ...
}:
{
  imports = [ (inputs.files + "/flake-module.nix") ];

  options.text = lib.mkOption {
    default = { };
    type = lib.types.lazyAttrsOf (
      lib.types.oneOf [
        (lib.types.separatedString "")
        (lib.types.submodule {
          options = {
            parts = lib.mkOption {
              type = lib.types.lazyAttrsOf lib.types.str;
            };
            order = lib.mkOption {
              type = lib.types.listOf lib.types.str;
            };
          };
        })
      ]
    );
    apply = lib.mapAttrs (
      _name: text:
      if lib.isAttrs text then
        lib.pipe text.order [
          (map (lib.flip lib.getAttr text.parts))
          (lib.concatStringsSep "\n")
        ]
      else
        text
    );
  };

  config = {
    flake-file.inputs.files.url = "github:mightyiam/files";

    text.readme.parts.files =
      withSystem (builtins.head config.systems) (psArgs: psArgs.config.files.file)
      |> builtins.attrNames
      |> map (path: "- `${path}`")
      |> lib.naturalSort
      |> lib.concat [
        # markdown
        ''
          ## Generated files

          The following files in this repository are generated and checked
          using [the _files_ flake-parts module](https://github.com/mightyiam/files):
        ''
      ]
      |> lib.concatLines;

    perSystem =
      {
        pkgs,
        config,
        self',
        ...
      }:
      {
        treefmt.settings.global.excludes =
          config.files.file
          |> builtins.attrNames
          |> builtins.filter (
            path:
            lib.any (extension: lib.hasSuffix extension path) [
              ".json"
              ".json5"
              ".jsonc"
            ]
          );

        files.file.".github/renovate.json5".text =
          builtins.toJSON {
            "$schema" = "https://docs.renovatebot.com/renovate-schema.json";
            enabledManagers = [ "custom.regex" ];
            dependencyDashboard = true;
            automerge = false;
            pinDigests = true;
            timezone = "America/New_York";
            schedule = [ "* 0-5 * * 1" ];
            customManagers = [
              {
                customType = "regex";
                managerFilePatterns = [ ''/^modules\/.*\.nix$/'' ];
                matchStrings = [
                  ''(?<prefix>(?:^|\n)[\t ]*image[\t ]*=[\t ]*")(?<depName>[a-z0-9][a-z0-9._-]*(?::[0-9]+)?(?:/[a-z0-9][a-z0-9._-]*)+):(?<currentValue>[A-Za-z0-9_][A-Za-z0-9_.-]{0,127})(?:@(?<currentDigest>sha256:[a-f0-9]{64}))?(?<suffix>";[\t ]*(?:\r?\n|$))''
                ];
                datasourceTemplate = "docker";
                versioningTemplate = "docker";
                autoReplaceStringTemplate = "{{{prefix}}}{{{depName}}}:{{{newValue}}}{{#if newDigest}}@{{{newDigest}}}{{/if}}{{{suffix}}}";
              }
            ];
            packageRules = [
              {
                matchManagers = [ "custom.regex" ];
                matchDatasources = [ "docker" ];
                groupName = "container images";
                groupSlug = "container-images";
                automerge = false;
              }
            ];
          }
          + "\n";

        make-shells.default.packages = [
          config.files.writer.drv
          config.packages.generate-files
        ];

        packages.generate-files = pkgs.writeShellApplication {
          name = "generate-files";
          meta.description = "Generate all automatically generated files for this repository";
          text = ''
            # github:mightyiam/files.
            ${self'.apps.write-files.program}

            lock_bck=$(mktemp)
            cp -p flake.lock "$lock_bck"

            ${lib.getExe self'.packages.write-flake}

            # If flake.lock remains unchanged, restore mtime.
            if cmp -s flake.lock "$lock_bck"; then
              touch -r "$lock_bck" flake.lock
            fi
          '';
        };

        apps.write-files = {
          program = config.files.writer.drv;
          meta.description = "Generate files using github:mightyiam/files.";
        };

        apps.generate-files = {
          program = config.packages.generate-files;
          meta.description = "Generate all automatically generated files for this repository";
        };

        pre-commit.settings.hooks."00-generate-files" = {
          enable = true;
          name = "generate-files";
          package = config.packages.generate-files;
          entry = self'.apps.generate-files.program;
          pass_filenames = false;
        };
      };
  };
}
