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
            # Generated, schema-typed projection of the service-publication
            # registry (metadata.containsSecrets is asserted false in Nix and
            # checked in CI). High-entropy route/application keys and
            # Cloudflare resource IDs it contains are not secrets. `paths`
            # only takes effect for file-source scans (`gitleaks detect`),
            # not `git --staged` diff scans, so match on the minified
            # document's own marker instead: registry.json is emitted as a
            # single line, so a line-target match covers the whole file.
            description = "Generated service-publication registry.json";
            regexTarget = "line";
            regexes = [ "\"generatedFrom\":\"servicePublication\"" ];
          }
          {
            # Non-secret Cloudflare resource IDs the service-publication
            # registry source records so adoption imports rather than
            # recreates them. Covers occurrences outside registry.json, e.g.
            # in modules/service-publication/registry.nix itself.
            description = "Cloudflare Access policy identifiers in the publication registry";
            regexTarget = "match";
            regexes = [ "cloudflareImportKey\"?[ =:]+\"[0-9a-f-]{36}\"" ];
          }
          {
            # RetroArch's OWN Discord Rich Presence application id, compiled in
            # as DEFAULT_DISCORD_APP_ID and written back into every
            # retroarch.cfg whether or not Discord is enabled -- the live file
            # on link carries it beside `discord_allow = "false"`, which is what
            # proves it was never operator-entered. It arrives here because
            # saveSync.retroarch.baseSettings is an import of that file.
            #
            # A Discord client id is public by construction: it is the first
            # thing in every OAuth authorize URL. gitleaks' stock
            # discord-client-id rule cannot tell a client id from a client
            # SECRET, so it is matched narrowly on the RetroArch key name rather
            # than by allowlisting the digits, which would also silence a real
            # Discord credential if one ever landed in this tree.
            description = "RetroArch's public Discord Rich Presence application id";
            regexTarget = "line";
            regexes = [ "discord_app_id\"?[ =:]+\"[0-9]{17,20}\"" ];
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
