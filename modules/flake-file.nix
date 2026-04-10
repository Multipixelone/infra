{ lib, ... }:
{
  flake-file = {
    description = "Multipixelone (Finn)'s nix + HomeManager config";

    nixConfig = {
      abort-on-warn = true;
      extra-experimental-features = [
        "pipe-operators"
      ];
      allow-import-from-derivation = false;
    };

    inputs = {
      nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
      nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.05";
      nixpkgs-mine.url = "github:Multipixelone/nixpkgs/init-soundshow";

      systems.url = "github:nix-systems/default-linux";

      flake-compat.url = "github:edolstra/flake-compat";

      flake-utils = {
        url = "github:numtide/flake-utils";
        inputs.systems.follows = "systems";
      };

      flake-parts = {
        url = "github:hercules-ci/flake-parts";
        inputs.nixpkgs-lib.follows = "nixpkgs";
      };

      flake-file.url = "github:vic/flake-file";
      import-tree.url = lib.mkDefault "github:vic/import-tree";

      allfollow = {
        url = lib.mkDefault "github:spikespaz/allfollow";
        inputs.rust-overlay.follows = "monocle/rust-overlay";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      nixos-wsl = {
        url = "github:nix-community/NixOS-WSL/main";
        inputs = {
          nixpkgs.follows = "nixpkgs";
          flake-compat.follows = "flake-compat";
        };
      };

      files.url = "github:mightyiam/files";
      nur.url = "github:nix-community/NUR";
      musnix.url = "github:musnix/musnix";
      catppuccin.url = "github:catppuccin/nix";
      nix-hardware.url = "github:NixOS/nixos-hardware/master";

      catppuccin-foot = {
        url = "github:catppuccin/foot";
        flake = false;
      };

      mcp-servers-nix = {
        url = "github:natsukium/mcp-servers-nix";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      nixcord.url = "github:ScarsTRF/nixcord/pnpmFix";
      apple-fonts.url = "github:Lyndeno/apple-fonts.nix";
      ucodenix.url = "github:e-tho/ucodenix";
      base16.url = "github:SenchoPens/base16.nix";

      tinted-schemes = {
        url = "github:tinted-theming/schemes";
        flake = false;
      };

      nixpkgs-xr.url = "github:nix-community/nixpkgs-xr";

      direnv-instant = {
        url = "github:Mic92/direnv-instant";
        inputs = {
          nixpkgs.follows = "nixpkgs";
          flake-parts.follows = "flake-parts";
        };
      };

      apple-emoji = {
        url = "github:samuelngs/apple-emoji-linux/b22ae7f";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      blocklist = {
        url = "github:StevenBlack/hosts";
        flake = false;
      };

      secrets = {
        url = "git+ssh://git@github.com/Multipixelone/nix-secrets.git";
        flake = false;
      };

      nextmeeting = {
        url = "github:Multipixelone/nextmeeting/reformat?dir=packaging";
        inputs.nixpkgs.follows = "nixpkgs";
        inputs.flake-utils.follows = "flake-utils";
      };

      playlist-download = {
        url = "github:Multipixelone/playlist-downloader";
        inputs.nixpkgs.follows = "nixpkgs";
        inputs.flake-utils.follows = "flake-utils";
      };

      rb-scrobbler = {
        url = "github:Multipixelone/rb-scrobbler/nix-build";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      waybar-mediaplayer = {
        url = "github:Multipixelone/waybar-mediaplayer/artist";
        inputs.nixpkgs.follows = "nixpkgs";
        inputs.flake-utils.follows = "flake-utils";
      };

      euphony = {
        url = "github:Multipixelone/euphony/nix-build";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      qtscrob = {
        url = "github:Multipixelone/QtScrobbler/nix-build";
        inputs.nixpkgs.follows = "nixpkgs";
        inputs.flake-utils.follows = "flake-utils";
      };

      statix = {
        url = "github:molybdenumsoftware/statix";
        inputs = {
          flake-parts.follows = "flake-parts";
          nixpkgs.follows = "nixpkgs";
        };
      };

      stylix = {
        url = "github:danth/stylix";
        inputs = {
          flake-parts.follows = "flake-parts";
          nixpkgs.follows = "nixpkgs";
          nur.follows = "nur";
          systems.follows = "systems";
          tinted-schemes.follows = "tinted-schemes";
        };
      };

      auto-cpufreq = {
        url = "github:AdnanHodzic/auto-cpufreq";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      nix-gaming = {
        url = "github:fufexan/nix-gaming";
        inputs = {
          nixpkgs.follows = "nixpkgs";
          flake-parts.follows = "flake-parts";
        };
      };

      home-manager = {
        url = "github:nix-community/home-manager/master";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      agenix = {
        url = "github:ryantm/agenix";
        inputs = {
          nixpkgs.follows = "nixpkgs";
          home-manager.follows = "home-manager";
          systems.follows = "systems";
        };
      };

      nixos-generators = {
        url = "github:nix-community/nixos-generators";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      colmena = {
        url = "github:zhaofengli/colmena";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      quadlet-nix.url = "github:SEIAROTg/quadlet-nix";

      spicetify-nix = {
        url = "github:Gerg-L/spicetify-nix";
        inputs.nixpkgs.follows = "nixpkgs";
      };

      lanzaboote = {
        url = "github:nix-community/lanzaboote/v1.0.0";
        inputs.nixpkgs.follows = "nixpkgs";
      };
    };
  };
}
