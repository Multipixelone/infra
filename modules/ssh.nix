{ lib, config, ... }:
let
  reachableNixoss =
    config.flake.nixosConfigurations
    |> lib.filterAttrs (
      _name: nixos:
      !(lib.any isNull [
        nixos.config.networking.domain
        nixos.config.networking.hostName
        nixos.config.services.openssh.publicKey
      ])
    );

  # Resolve host address: wireguard -> homeAddress -> null
  resolveHostAddress =
    name:
    let
      host = config.hosts.${name} or null;
    in
    if host == null then
      null
    else if host.wireguard.ipv4Address != null then
      host.wireguard.ipv4Address
    else if host.homeAddress != null then
      host.homeAddress
    else
      null;

  # Get deployable hosts with resolvable addresses
  deployableHosts = lib.filterAttrs (_: cfg: cfg.deployment != null) config.configurations.nixos;
  colmenaHosts = lib.filterAttrs (name: _: resolveHostAddress name != null) deployableHosts;
in
{
  flake.modules = {
    nixos.base = {
      options.services.openssh.publicKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
      };

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
          "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBK7HXtVv6LFt7sH5QUrj80iqtaUmYJuf7eBwmsdzni7epBfrX2iyZzzXtIDSdgPaOhSJp5FJIkBvA6UMMkveYbM= iphone"
          "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBBGm2epY8mE3z7qoL10fXmBuv4EPHnQoqJoYrL9TgfJwhnZMsaf1FQ2jalGSCE6T+QuYF/WM+bIWxZiYrT/XisM= ipad"
        ];

        users.users.root.openssh.authorizedKeys.keys = [
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOVPE0NP1EtHnnzhBXZ4Cz6YAw/ZaEFUA8T6YvtnzGcK colmena-deploy"
        ];

        programs.ssh.knownHosts =
          reachableNixoss
          |> lib.mapAttrs (
            _name: nixos: {
              hostNames = [ nixos.config.networking.fqdn ];
              inherit (nixos.config.services.openssh) publicKey;
            }
          );
      };
    };

    homeManager.base = args: {
      programs.ssh = {
        enable = true;
        enableDefaultConfig = false;
        includes = [ "${args.config.home.homeDirectory}/.ssh/hosts/*" ];
        matchBlocks =
          reachableNixoss
          |> lib.mapAttrsToList (
            _name: nixos: {
              "${nixos.config.networking.fqdn}" = {
                identityFile = "~/.ssh/keys/id_ed25519";
              };
            }
          )
          |> lib.concat (
            colmenaHosts
            |> lib.mapAttrsToList (
              name: _: {
                "colmena.${name}" = {
                  hostname = resolveHostAddress name;
                  user = "root";
                  identityFile = "${args.config.home.homeDirectory}/.ssh/colmena";
                  identitiesOnly = true;
                };
              }
            )
          )
          |> lib.concat [
            {
              "alexandria" = {
                hostname = resolveHostAddress "alexandria";
                user = config.flake.meta.owner.username;
                identityFile = "${args.config.home.homeDirectory}/.ssh/colmena";
                identitiesOnly = true;
              };
            }
            {
              "*" = {
                setEnv.TERM = "xterm-256color";
                compression = true;
                identitiesOnly = true;
                hashKnownHosts = false;
                identityFile = "${args.config.home.homeDirectory}/.ssh/id_ed25519";
                forwardAgent = true;
                addKeysToAgent = "yes";
                serverAliveInterval = 0;
                serverAliveCountMax = 3;
                userKnownHostsFile = "~/.ssh/known_hosts";
                controlMaster = "no";
                controlPath = "~/.ssh/master-%r@%n:%p";
                controlPersist = "no";
              };
            }
          ]
          |> lib.mkMerge;
      };
    };
  };
}
