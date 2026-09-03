{ lib, ... }:
let
  wireguardSubmodule = lib.types.submodule {
    options = {
      ipv4Address = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WireGuard IPv4 address for this host (without CIDR suffix).";
        example = "10.100.0.1";
      };
      publicKey = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "WireGuard public key for this host.";
      };
    };
  };

  hostSubmodule = lib.types.submodule (
    { name, config, ... }:
    {
      options = {
        hostName = lib.mkOption {
          type = lib.types.str;
          default = name;
          description = "Hostname of this host. Defaults to the attribute name.";
        };
        isNixOS = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether this host is managed as a NixOS configuration.";
        };
        isDarwin = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether this host is managed as a nix-darwin configuration.";
        };
        roles = lib.mkOption {
          # Closed vocabulary: a typo here would silently skip the role's module
          # and still ship as a colmena deployment tag.
          type = lib.types.listOf (
            lib.types.enum [
              "desktop"
              "edge"
              "laptop"
              "mobile"
              "nas"
              "server"
              "tablet"
              "wsl"
            ]
          );
          default = [ ];
          description = "Roles or tags describing this host (e.g. desktop, laptop, server, mobile).";
        };
        observabilityHub = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "Whether this host is the explicitly designated observability hub.";
        };
        description = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional human-friendly host description for docs/readme.";
        };
        manufacturer = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional hardware manufacturer for docs/readme.";
        };
        model = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional hardware model for docs/readme.";
        };
        readmeRole = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional display role used in README host table (e.g. Server/Laptop/Desktop).";
        };
        desktopWindowManager = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional desktop/window manager name for README host table.";
        };
        notes = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Optional notes for README host table.";
        };
        homeAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Static home/LAN IPv4 address.";
          example = "192.168.6.6";
        };
        iotAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = "Static home/IoT IPv4 address.";
          example = "192.168.5.3";
        };
        wireguard = lib.mkOption {
          type = wireguardSubmodule;
          default = { };
          description = "WireGuard network configuration for this host.";
        };
        deployAddress = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          readOnly = true;
          default =
            if config.wireguard.ipv4Address != null then config.wireguard.ipv4Address else config.homeAddress;
          description = "Address colmena and SSH use to reach this host; null means unreachable.";
        };
        deployable = lib.mkOption {
          type = lib.types.bool;
          default = config.isNixOS;
          description = "Whether colmena may deploy to this host. False while a host is declared but not yet installed, or when it is installed but managed outside colmena.";
        };
        inHive = lib.mkOption {
          type = lib.types.bool;
          readOnly = true;
          default = config.isNixOS && config.deployable && config.deployAddress != null;
          description = ''
            Whether colmena manages this host, and the only spelling of that test:
            modules/deployment-tags.nix writes `deployment` for exactly these hosts,
            modules/configurations/colmena.nix builds the hive from them, and
            modules/ssh.nix emits the `colmena.<name>` alias for them. False means
            the host keeps its nixosConfiguration and its check, but colmena never
            sees it.
          '';
        };
        sshHostKey = lib.mkOption {
          type = lib.types.nullOr lib.types.str;
          default = null;
          description = ''
            Contents of this host's /etc/ssh/ssh_host_ed25519_key.pub.
            Must equal this host's agenix recipient in nix-secrets.
          '';
        };
      };
    }
  );
in
{
  options.hosts = lib.mkOption {
    type = lib.types.attrsOf hostSubmodule;
    default = { };
    description = "Central registry of all hosts and devices, including network metadata.";
  };

  config.hosts = {
    link = {
      isNixOS = true;
      roles = [ "desktop" ];
      observabilityHub = true;
      description = "My desktop";
      manufacturer = "Custom";
      model = "Gaming PC";
      readmeRole = "Desktop";
      desktopWindowManager = "Hyprland";
      homeAddress = "192.168.6.6";
      wireguard.ipv4Address = "10.100.0.1";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDW3JFfjgVfQxXRj343LPp7VnQ5O11eGl55LMtkYQIBQ root@link";
    };
    impa = {
      isNixOS = true;
      # The host key is enrolled in nix-secrets and pinned below. Ingress and
      # DNS cutover remain separately gated by the service-publication registry.
      deployable = true;
      roles = [
        "server"
        "edge"
      ];
      description = "NYC edge host";
      readmeRole = "Server";
      desktopWindowManager = "None";
      homeAddress = "192.168.6.50";
      notes = "DNS and ingress edge";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJjgsvsNKNY+L9y/icxluHnY4uDmNEkvkAHZsmqcTiVx root@impa";
    };
    zelda = {
      isNixOS = true;
      roles = [ "laptop" ];
      description = "My personal laptop";
      manufacturer = "Razer";
      model = "Razer Blade";
      readmeRole = "Laptop";
      desktopWindowManager = "Hyprland";
      wireguard = {
        ipv4Address = "10.100.0.2";
        publicKey = "8mNNHB03ytgnnZMPv0AZOpgZVumEvy3tr+E7h3WBCUI=";
      };
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHjWdSmIUxhdOJxY4IwKGTPJP3gC3cdNpbGDGui4xQvy root@zelda";
    };
    iot = {
      isNixOS = true;
      homeAddress = "192.168.8.111";
      iotAddress = "192.168.5.3";
      roles = [ "server" ];
      description = "Old Dell laptop running IoT services";
      manufacturer = "Dell";
      model = "Laptop";
      readmeRole = "Server";
      desktopWindowManager = "None";
      notes = "IoT services";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIIz+/E9T3UyH7i7x8yKw85U/yeS6cfKXjrS5pWUrOGRT root@iot";
    };
    marin = {
      isNixOS = true;
      homeAddress = "192.168.5.21";
      iotAddress = "192.168.7.3";
      roles = [ "server" ];
      description = "Mac Mini as Airport Express";
      manufacturer = "Apple";
      model = "Mac Mini";
      readmeRole = "Server";
      desktopWindowManager = "None";
      notes = "Audio + home services";
      sshHostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIC95oj0z4gZSBkAQ2k+HQDsPuK/J9iDXYnLFxt3Hl1UG root@marin";
    };
    hylia = {
      isDarwin = true;
      roles = [ "laptop" ];
      description = "Apple Silicon MacBook (nix-darwin)";
      manufacturer = "Apple";
      model = "MacBook Neo";
      readmeRole = "Laptop";
      desktopWindowManager = "macOS";
      notes = "nix-darwin host";
      wireguard = {
        ipv4Address = "10.100.0.3";
        publicKey = "CdJg4znt9L9e/vnDNDuu0wMnRcXMKZeMSeOPEr+4HCk=";
      };
    };
    minish = {
      isNixOS = true;
      # WSL has no address of its own on either network, so colmena cannot dial
      # it; it is rebuilt from inside Windows. Saying so keeps deployable and
      # deployAddress consistent instead of relying on the missing address to
      # quietly drop the host out of the hive.
      deployable = false;
      roles = [ "wsl" ];
      description = "NixOS-WSL instance on Windows";
      manufacturer = "Microsoft";
      model = "WSL2";
      readmeRole = "WSL";
      desktopWindowManager = "None";
      notes = "NixOS under Windows Subsystem for Linux";
    };
    alexandria = {
      isNixOS = false;
      homeAddress = "192.168.6.9";
      roles = [
        "server"
        "nas"
      ];
      description = "Synology NAS (home-manager only, non-NixOS)";
      manufacturer = "Synology";
      model = "DS920+";
      readmeRole = "NAS";
      desktopWindowManager = "None";
      notes = "DSM host managed via standalone home-manager";
    };
    ipad = {
      roles = [ "tablet" ];
      description = "Personal tablet";
      manufacturer = "Apple";
      model = "iPad";
      readmeRole = "Tablet";
      wireguard = {
        ipv4Address = "10.100.0.50";
        publicKey = "YHW9LGJkWRaa5GtBCmqFd1IVS9fyVRUP3orDXeCC8l8=";
      };
    };
    iphone = {
      roles = [ "mobile" ];
      description = "Personal phone";
      manufacturer = "Apple";
      model = "iPhone";
      readmeRole = "Mobile";
      wireguard = {
        ipv4Address = "10.100.0.100";
        publicKey = "ORnW9c/rVHqOdaawcHJlpeTtg7pPvPxICtN2kXTlc3I=";
      };
    };
  };
}
