{ inputs, lib, ... }:
let
  # Guarded rather than referenced unconditionally: these land in nix-secrets,
  # and the flake input is pinned by revision, so between "module written" and
  # "lock bumped" the paths do not exist yet. Same idiom as
  # modules/link/forgejo-runner.nix, where an unguarded reference to a missing
  # .age is an eval error rather than a degraded config.
  sshSecret = "${inputs.secrets}/ssh/git.age";
  tokenSecret = "${inputs.secrets}/forgejo/token.age";
  hasSshSecret = builtins.pathExists sshSecret;
  hasTokenSecret = builtins.pathExists tokenSecret;

  domain = "git.finnrut.is";
  # Forgejo's built-in Go SSH server, not the host's sshd — impa's own sshd is
  # reached at impa.hosts.nyc.finnrut.is and is a different key entirely.
  sshPort = 2222;
in
{
  flake = {
    meta.accounts.forgejo = {
      inherit domain sshPort;
      # The forge account, which is not the GitHub account in meta.accounts.github.
      username = "tunnel";
    };

    modules = {
      nixos.base = {
        # `[host]:port` is the known_hosts spelling for a non-22 port; a bare
        # hostname here would simply never match what ssh looks up.
        #
        # ssh-rsa because that is the only host key the forge offers — Forgejo's
        # Go server generates an RSA key and nothing else, so there is no
        # ed25519 alternative to prefer.
        programs.ssh.knownHosts."forgejo" = {
          hostNames = [ "[${domain}]:${toString sshPort}" ];
          publicKey = "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAACAQCf9HDUZWeAl9S69dZ21CPinWhiN/IO+Iqhd204FfMweRPC5hsEG9e8CBPj4MhJCOEcqWaDjt9pITV3EDkOkIHIGmMmOv0SXweRAm/PCHe+4FsilxaGnQBl2m9G30DIDBC87AaF8IrH/jApPzfUSPNqDEojAekVxUfM1cFA5jynWOvx/V3PtITixW7mrYgV2YkVHYdodniveByVDV9uJT7Fdg6wsL89fl8dyTOHc3U3+7qZ9ge7Bbudxbb3ArKDFWWT8G89rDfrUkg7ga87RZgSug0+4pxG1yKd/00HSfPGPqoI05Hh0KcrytlmhAAg+z4lVduSqT3xivTdv+KKgXIZ8rBGd681iQ7jFzZ+DuJAZCpvaK2Tc1CNjFijFPL/oveoZN7skIRhP463968xC4EmwGHN37qOZS45T0Ks6q+8a6j+M9FOSSo9ku32FyTxtROJQyhvbi0skSkkI1ytf7LUT/ql7Yc37J6qdqeBcJplBch1dU88ZaivHld8gATnqTl6pVp83pq5rtpd/Ka945nOGrCYsgznd6UNuNeylmVnGtv8Fw0mfEE5LXpSC9nak5xfQVMDOIVTGrqDfqUfA4wVMhwtDn6ZzbV3Z1qZNqkqcUitNcQLGasIOy6ZL2lRuAA7IlNwc1Zp3zSBD2ETpagm2b4IMqs/yEP4HlFJ35TqSQ==";
        };
      };

      homeManager.base =
        hmArgs@{ pkgs, ... }:
        let
          # agenix decrypts into age.secretsDir (modules/security/secrets.nix
          # points that at ~/.secrets) at mode 0400, which is exactly what ssh
          # demands of a private key — so ssh reads the decrypted secret in
          # place and there is no copy into ~/.ssh to drift.
          gitKey = hmArgs.config.age.secrets."git-ssh".path;

          # Both forges get the same identity. The passphrase-protected
          # ~/.ssh/id_ed25519 that `Host *` supplies needs an agent, and a
          # non-interactive shell — CI, a nix build, an agent session — has
          # none, so every push failed with "Permission denied (publickey)"
          # even though the key existed. This one has no passphrase, which is
          # the whole point: it is git-only, and it is the only thing offered
          # for these two hosts because `Host *` already sets IdentitiesOnly.
          gitHostSettings = {
            IdentityFile = gitKey;
            IdentitiesOnly = true;
            User = "git";
          };

          # One wrapper serves both MCP stdio and the human CLI. Read the raw
          # token rather than sourcing it: the secret is not an environment file.
          forgejoMcp = pkgs.writeShellApplication {
            name = "forgejo-mcp";
            text = ''
              export FORGEJO_URL=${lib.escapeShellArg "https://${domain}"}
              FORGEJO_ACCESS_TOKEN="$(< ${lib.escapeShellArg hmArgs.config.age.secrets."forgejo-token".path})"
              export FORGEJO_ACCESS_TOKEN
              exec ${lib.getExe pkgs.forgejo-mcp} "$@"
            '';
          };

          forgejo = pkgs.writeShellApplication {
            name = "forgejo";
            text = ''
              exec ${lib.getExe forgejoMcp} --cli "$@"
            '';
          };
        in
        {
          age.secrets =
            lib.optionalAttrs hasSshSecret { "git-ssh".file = sshSecret; }
            // lib.optionalAttrs hasTokenSecret { "forgejo-token".file = tokenSecret; };

          home.packages = lib.optionals hasTokenSecret [
            forgejoMcp
            forgejo
          ];

          mcp-servers.settings.servers = lib.optionalAttrs hasTokenSecret {
            forgejo = {
              command = lib.getExe forgejoMcp;
              args = [
                "--transport"
                "stdio"
              ];
            };
          };

          # A per-host block beats the catch-all because home-manager renders
          # `Host *` last and ssh takes the first value it sees for a keyword.
          programs.ssh.settings = lib.mkIf hasSshSecret (
            lib.mkMerge [
              {
                ${domain} = gitHostSettings // {
                  # The ONLY place 2222 is written on the client side. Every
                  # remote can then be the ordinary scp-style
                  # `git@git.finnrut.is:tunnel/infra.git` and inherit the port
                  # from here, rather than dragging `ssh://…:2222/` through
                  # every URL that names the forge.
                  #
                  # The port itself is not negotiable: Forgejo's hardened unit
                  # sets CapabilityBoundingSet = "", so its built-in server can
                  # never bind below 1024, and 22 on impa belongs to the host
                  # sshd that colmena deploys over (modules/impa/forgejo.nix).
                  #
                  # Tradeoff: a plain `ssh git.finnrut.is` now reaches Forgejo
                  # rather than a shell. Correct for this name — impa's own
                  # sshd answers on its host alias.
                  Port = sshPort;
                };
              }
              { "github.com" = gitHostSettings; }
            ]
          );

          # Mirrors the `gh:` shorthand in modules/forges/github.nix: fetch over
          # https, push over ssh.
          #
          # scp-style rather than `ssh://git@host:2222/`, so the port stays in
          # the Host block above and out of every URL. git's insteadOf is a
          # plain prefix substitution, so `forge:tunnel/infra` expands to
          # `git@git.finnrut.is:tunnel/infra` and ssh supplies the rest.
          programs.git.settings.url = lib.mkIf hasSshSecret {
            "https://${domain}/".insteadOf = "forge:";
            "git@${domain}:".pushInsteadOf = "forge:";
          };
        };
    };
  };
}
