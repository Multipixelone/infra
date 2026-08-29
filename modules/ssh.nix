{ lib, config, ... }:
let
  # `iso` is a nixosConfiguration with no entry in the host registry, so every
  # lookup here has to tolerate a missing host.
  hostKey = name: config.hosts.${name}.sshHostKey or null;
  hostAddress = name: config.hosts.${name}.deployAddress or null;

  reachableNixoss =
    config.flake.nixosConfigurations
    |> lib.filterAttrs (
      name: nixos:
      !(lib.any isNull [
        nixos.config.networking.domain
        nixos.config.networking.hostName
        (hostKey name)
      ])
    );

  colmenaHosts = lib.filterAttrs (_: cfg: cfg.deployment != null) config.configurations.nixos;
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
          reachableNixoss
          |> lib.mapAttrs (
            name: nixos: {
              hostNames = [
                nixos.config.networking.fqdn
              ]
              ++ lib.optional (hostAddress name != null) (hostAddress name);
              publicKey = hostKey name;
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
          reachableNixoss
          |> lib.mapAttrsToList (
            _name: nixos: {
              "${nixos.config.networking.fqdn}" = {
                IdentityFile = "~/.ssh/keys/id_ed25519";
              };
            }
          )
          |> lib.concat (
            colmenaHosts
            |> lib.mapAttrsToList (
              name: _: {
                "colmena.${name}" = {
                  HostName = hostAddress name;
                  User = "root";
                  IdentityFile = "${args.config.home.homeDirectory}/.ssh/colmena";
                  IdentitiesOnly = true;
                };
              }
            )
          )
          |> lib.concat [
            {
              "alexandria" = {
                HostName = hostAddress "alexandria";
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
