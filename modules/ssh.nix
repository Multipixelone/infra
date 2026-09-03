{ lib, config, ... }:
let
  # Both sets below are projections of the host registry, so every host fact is
  # reached by a static submodule path: a renamed or deleted `hosts` entry is an
  # eval error instead of a null that silently deletes an ssh block. `iso` is a
  # nixosConfiguration with no registry entry and is never an ssh target, so it
  # is simply absent here rather than a missing host every lookup has to
  # tolerate.

  # A pinned host key is what makes a host safe to dial, so it is the real
  # filter. The domain test is a guard, not a filter: nixpkgs' networking.fqdn
  # *throws* when domain is null, and modules/network/domain.nix sets it
  # fleet-wide, so dropping the test would let one unresolvable host abort every
  # other host's eval instead of just losing its own pin.
  pinnedHosts =
    config.hosts
    |> lib.filterAttrs (
      name: host:
      host.isNixOS
      && host.sshHostKey != null
      && config.flake.nixosConfigurations.${name}.config.networking.domain != null
    );

  # hosts.<name>.inHive is the one spelling of hive membership, so an alias
  # cannot outlive the node it deploys to. Reading
  # `configurations.nixos.<name>.deployment` back instead was a two-hop
  # indirection into a lazyAttrsOf that any module may extend.
  hiveHosts = lib.filterAttrs (_: host: host.inHive) config.hosts;

  # The one datum the registry does not own: only the NixOS eval concatenates
  # hostName with domain. modules/roles.nix mints a configurations.nixos entry
  # for every isNixOS host, so this index cannot miss for a member of
  # pinnedHosts; it stays un-`or`ed so it would fail loudly rather than drop a
  # pin if that ever changed.
  fqdn = name: config.flake.nixosConfigurations.${name}.config.networking.fqdn;
in
{
  flake.modules = {
    nixos.base = {
      config = {
        programs.mosh = {
          enable = true;
          openFirewall = true;
        };

        services.openssh = {
          enable = true;
          openFirewall = true;
          allowSFTP = true;

          settings = {
            PasswordAuthentication = false;
            PermitRootLogin = "prohibit-password";
          };

          extraConfig = ''
            Include /etc/ssh/sshd_config.d/*
          '';
        };

        users.users.${config.flake.meta.owner.username}.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAfFq+1W21NoXAyFc1HT5zJ7GAVDbQw/f6reJI3X2vtn link"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIK5bqb1RiYN2X5dx4GKlTgeiWhYWHQhiV/HU1MtOZfFt zelda"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIF8qkIXQ0F+FCGzcuZaFoIj95/9G6CN1/kJiEMngWCiJ iot"
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICyIzZ3DY1XXqW77DjjHgw5hcxDkmdFYcPPRj4Wv0arr tunnel@hylia"
          "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBK7HXtVv6LFt7sH5QUrj80iqtaUmYJuf7eBwmsdzni7epBfrX2iyZzzXtIDSdgPaOhSJp5FJIkBvA6UMMkveYbM= iphone"
          "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBGm2epY8mE3z7qoL10fXmBuv4EPHnQoqJoYrL9TgfJwhnZMsaf1FQ2jalGSCE6T+QuYF/WM+bIWxZiYrT/XisM= ipad"
        ];

        # Root login is deploy-only, and every deploy originates on the WireGuard
        # mesh or the home LAN.
        users.users.root.openssh.authorizedKeys.keys = [
          ''from="10.100.0.0/24,192.168.0.0/16" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOVPE0NP1EtHnnzhBXZ4Cz6YAw/ZaEFUA8T6YvtnzGcK colmena-deploy''
        ];

        # ssh matches known_hosts on the address it dialled, and colmena dials the
        # `colmena.<name>` alias whose HostName is the bare deploy address, so the
        # fqdn pin alone would never apply.
        programs.ssh.knownHosts =
          pinnedHosts
          |> lib.mapAttrs (
            name: host: {
              hostNames = [
                (fqdn name)
              ]
              ++ lib.optional (host.deployAddress != null) host.deployAddress;
              publicKey = host.sshHostKey;
            }
          );
      };
    };

    homeManager.base = args: {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        includes = [ "${args.config.home.homeDirectory}/.ssh/hosts/*" ];
        settings =
          pinnedHosts
          |> lib.mapAttrsToList (
            name: _host: {
              "${fqdn name}" = {
                IdentityFile = "~/.ssh/keys/id_ed25519";
              };
            }
          )
          |> lib.concat (
            hiveHosts
            |> lib.mapAttrsToList (
              name: host: {
                "colmena.${name}" = {
                  # Non-null by construction: hosts.<name>.inHive filters on it,
                  # so this alias can never render with an absent HostName.
                  HostName = host.deployAddress;
                  User = "root";
                  IdentityFile = "${args.config.home.homeDirectory}/.ssh/colmena";
                  IdentitiesOnly = true;
                };
              }
            )
          )
          |> lib.concat [
            {
              # DSM: reachable and worth an alias, but not a NixOS host and not a
              # colmena node, so it stays hand-written. The static path is what
              # matters - `config.hosts.alexandria.deployAddress or null` used to
              # degrade a renamed entry into a HostName-less block, leaving ssh to
              # resolve the literal string "alexandria" against DNS.
              "alexandria" = {
                HostName = config.hosts.alexandria.deployAddress;
                User = config.flake.meta.owner.username;
                IdentityFile = "${args.config.home.homeDirectory}/.ssh/colmena";
                IdentitiesOnly = true;
              };
            }
            {
              "*" = {
                SetEnv.TERM = "xterm-256color";
                Compression = true;
                IdentitiesOnly = true;
                HashKnownHosts = false;
                IdentityFile = "${args.config.home.homeDirectory}/.ssh/id_ed25519";
                ForwardAgent = true;
                AddKeysToAgent = "yes";
                ServerAliveInterval = 0;
                ServerAliveCountMax = 3;
                UserKnownHostsFile = "~/.ssh/known_hosts";
                ControlMaster = "no";
                ControlPath = "~/.ssh/master-%r@%n:%p";
                ControlPersist = "no";
              };
            }
          ]
          |> lib.mkMerge;
      };
    };
  };
}
