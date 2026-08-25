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
      files.file.".gitleaks.toml".source = (pkgs.formats.toml { }).generate "gitleaks.toml" {
        title = "infra gitleaks configuration";
        allowlists = [
          {
            description = "DNSCrypt resolver-list Minisign public verification key";
            regexTarget = "secret";
            regexes = [ "^RWQf6LRCGA9i53mlYecO4IzT51TGPpvWucNSCh1CBM0QTaLn73Y7GFO3$" ];
          }
          {
            # Non-secret Cloudflare resource IDs the service-publication
            # registry records so adoption imports rather than recreates.
            description = "Cloudflare Access policy identifiers in the publication registry";
            regexTarget = "match";
            regexes = [ "cloudflareImportKey\"?[ =:]+\"[0-9a-f-]{36}\"" ];
          }
        ];
        extend.useDefault = true;
      };

      make-shells.default = {
        inputsFrom = [
          config.pre-commit.devShell
        ];
        shellHook = config.pre-commit.installationScript;
        packages = [ pkgs.gitleaks ];
      };
      pre-commit.check.enable = false;
      pre-commit.settings.hooks = {
        # General use pre-commit hooks
        trim-trailing-whitespace.enable = true;
        mixed-line-endings = {
          enable = true;
          # Generated .gitignore contains literal CR in macOS filenames
          # (e.g. `Icon\r`, `.HFS+ Private Directory Data\r`)
          excludes = [ "^\\.gitignore$" ];
        };
        end-of-file-fixer = {
          enable = true;
          excludes = [ "^\\.gitignore$" ];
        };
        check-executables-have-shebangs.enable = true;
        check-added-large-files.enable = true;
        # git secret checking
        gitleaks = {
          enable = true;
          name = "gitleaks";
          entry = "gitleaks git --pre-commit --redact --staged --verbose";
          pass_filenames = false;
          language = "system";
        };
      };
    };
}
