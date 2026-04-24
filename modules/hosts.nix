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
    { name, ... }:
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
        roles = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = [ ];
          description = "Roles or tags describing this host (e.g. desktop, laptop, server, mobile).";
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
      description = "My desktop";
      manufacturer = "Custom";
      model = "Gaming PC";
      readmeRole = "Desktop";
      desktopWindowManager = "Hyprland";
      homeAddress = "192.168.6.6";
      wireguard.ipv4Address = "10.100.0.1";
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
