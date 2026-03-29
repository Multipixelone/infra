{
  description = "Multipixelone (Finn)'s nix + HomeManager config";

  # FIX: I don't like the "Using saved setting for" warn. If there's a way to ignore this or not have to deal with it. I'm all ears
  nixConfig = {
    abort-on-warn = true;
    extra-experimental-features = [
      "pipe-operators"
    ];
    allow-import-from-derivation = false;
  };

  outputs =
    inputs:
    inputs.flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [ "x86_64-linux" ];

      imports = [
        (inputs.import-tree ./modules)
      ];

      _module.args.rootPath = ./.;

      # perSystem =
      #   {
      #     config,
      #     pkgs,
      #     system,
      #     ...
      #   }:
      #   {
      #     # Configure nixpkgs to allow unfree packages
      #     _module.args.pkgs = import inputs.nixpkgs {
      #       inherit system;
      #       config.allowUnfree = true;
      #     };
      #     devShells.default = pkgs.mkShell {
      #       packages = [
      #         pkgs.nixfmt
      #         pkgs.just
      #         pkgs.attic-client

      #         inputs.agenix.packages.${pkgs.stdenv.hostPlatform.system}.default
      #       ];
      #       name = "dots";
      #       DIRENV_LOG_FORMAT = "";
      #       shellHook = ''
      #         ${config.pre-commit.installationScript}
      #       '';
      #     };

      #     # TODO fix build with cmake 4
      #     packages = {
      #       musepack =
      #         inputs.nixpkgs-stable.legacyPackages.${pkgs.stdenv.hostPlatform.system}.callPackage ./pkgs/musepack
      #           { };
      #     };

      #     pre-commit.settings = {
      #       hooks =
      #         let
      #           # probably a better way to do this
      #           excludes = [ ];
      #         in
      #         {
      #           nixfmt = {
      #             inherit excludes;
      #             enable = true;
      #           };
      #         };
      #     };

      #     formatter = pkgs.nixfmt;
      #   };
    };

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-cloudflared.url = "github:wrbbz/nixpkgs/cloudflared-2025.4.0";
    nixpkgs-mine.url = "github:Multipixelone/nixpkgs/init-soundshow";

    # nixpkgs for zoom screensharing
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

    nixos-wsl = {
      url = "github:nix-community/NixOS-WSL/main";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-compat.follows = "flake-compat";
      };
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        flake-compat.follows = "flake-compat";
        nixpkgs.follows = "nixpkgs";
      };
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    files.url = "github:mightyiam/files";
    import-tree.url = "github:vic/import-tree";
    nur.url = "github:nix-community/NUR";
    musnix.url = "github:musnix/musnix";
    catppuccin.url = "github:catppuccin/nix";
    nix-hardware.url = "github:NixOS/nixos-hardware/master";
    zjstatus.url = "github:dj95/zjstatus";
    # helix fork with support for copilot-language-server
    helix.url = "github:spion/helix/textDocument/inlineCompletion";
    # helix color
    catppuccin-helix = {
      url = "github:catppuccin/helix";
      flake = false;
    };
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    wrappers.url = "github:BirdeeHub/nix-wrapper-modules";
    wrappers.inputs.nixpkgs.follows = "nixpkgs";
    # helix.url = "github:helix-editor/helix";
    yazi.url = "github:sxyazi/yazi";
    nixcord.url = "github:ScarsTRF/nixcord/pnpmFix";
    apple-fonts.url = "github:Lyndeno/apple-fonts.nix";
    ucodenix.url = "github:e-tho/ucodenix";
    base16.url = "github:SenchoPens/base16.nix";
    tinted-schemes = {
      flake = false;
      url = "github:tinted-theming/schemes";
    };
    nixpkgs-xr.url = "github:nix-community/nixpkgs-xr";
    direnv-instant = {
      url = "github:Mic92/direnv-instant";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-parts.follows = "flake-parts";
      };
    };
    # prismlauncher.url = "github:PrismLauncher/PrismLauncher";
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    # FIX: bump when https://github.com/samuelngs/apple-emoji-ttf/issues/101 fixed
    apple-emoji = {
      url = "github:samuelngs/apple-emoji-linux/b22ae7f";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    make-shell = {
      url = "github:nicknovitski/make-shell";
      inputs.flake-compat.follows = "flake-compat";
    };
    blocklist = {
      url = "github:StevenBlack/hosts";
      flake = false;
    };
    better-fox = {
      url = "github:yokoffing/Betterfox";
      flake = false;
    };
    claude-code-src = {
      url = "github:anthropics/claude-code";
      flake = false;
    };
    bgutil-ytdlp-pot-provider = {
      url = "github:Brainicism/bgutil-ytdlp-pot-provider";
      flake = false;
    };
    yt-dlp-YTNSigDeno = {
      url = "github:bashonly/yt-dlp-YTNSigDeno";
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
    beets-plugins = {
      url = "github:Multipixelone/beets-plugins";
    };
    waybar-mediaplayer = {
      url = "github:Multipixelone/waybar-mediaplayer/artist";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    # TODO switch to upstream if PR accepted (https://github.com/obskyr/khinsider/pull/98)
    khinsider = {
      url = "github:Multipixelone/khinsider/nix-build";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-utils.follows = "flake-utils";
    };
    euphony = {
      url = "github:Multipixelone/euphony/nix-build";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    zjstatus-hints = {
      url = "github:b0o/zjstatus-hints";
      # inputs.nixpkgs.follows = "zjstatus";
      # inputs.crane.follows = "zjstatus";
      # inputs.rust-overlay.follows = "zjstatus";
    };
    uwu-colors = {
      url = "github:q60/uwu_colors";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        utils.follows = "flake-utils";
      };
    };
    monocle = {
      url = "github:Multipixelone/monocle/nix-build";
      # inputs.nixpkgs.follows = "zjstatus";
      # inputs.crane.follows = "zjstatus";
      # inputs.rust-overlay.follows = "zjstatus";
    };
    # humble-key = {
    #   url = "github:Multipixelone/humble-steam-key-redeemer/nix-build";
    #   inputs.nixpkgs.follows = "nixpkgs";
    #   inputs.flake-utils.follows = "flake-utils";
    # };
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
    quadlet-nix = {
      url = "github:SEIAROTg/quadlet-nix";
    };
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    anyrun = {
      url = "github:fufexan/anyrun/launch-prefix";
      # url = "github:anyrun-org/anyrun";
      # inputs.nixpkgs.follows = "nixpkgs";
      # inputs.systems.follows = "systems";
    };
    anyrun-nixos-options = {
      url = "github:n3oney/anyrun-nixos-options";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.flake-parts.follows = "flake-parts";
    };
    # lanzaboote
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # noctalia
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.noctalia-qs.follows = "noctalia-qs";
    };
    noctalia-qs = {
      url = "github:noctalia-dev/noctalia-qs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # hyprland wm
    hyprland.url = "github:hyprwm/hyprland";
    hyprland-plugins = {
      url = "github:hyprwm/hyprland-plugins";
      inputs.hyprland.follows = "hyprland";
    };
    hyprlock = {
      url = "github:hyprwm/hyprlock";
      inputs = {
        hyprgraphics.follows = "hyprland/hyprgraphics";
        hyprlang.follows = "hyprland/hyprlang";
        hyprutils.follows = "hyprland/hyprutils";
        nixpkgs.follows = "hyprland/nixpkgs";
        systems.follows = "hyprland/systems";
      };
    };
    hyprpaper = {
      url = "github:hyprwm/hyprpaper";
      inputs = {
        hyprgraphics.follows = "hyprland/hyprgraphics";
        hyprlang.follows = "hyprland/hyprlang";
        hyprutils.follows = "hyprland/hyprutils";
        nixpkgs.follows = "hyprland/nixpkgs";
        systems.follows = "hyprland/systems";
      };
    };
    hypridle = {
      url = "github:hyprwm/hypridle";
      inputs = {
        hyprlang.follows = "hyprland/hyprlang";
        hyprutils.follows = "hyprland/hyprutils";
        nixpkgs.follows = "hyprland/nixpkgs";
        systems.follows = "hyprland/systems";
      };
    };
  };
}
