{
  inputs,
  config,
  withSystem,
  lib,
  ...
}:
{
  imports = [ inputs.files.flakeModules.default ];

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
          lib.concatStrings
        ]
      else
        text
    );
  };

  config = {
    text.readme.parts.files =
      withSystem (builtins.head config.systems) (psArgs: psArgs.config.files.files)
      |> map (file: "- `${file.path_}`")
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
