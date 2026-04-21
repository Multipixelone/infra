# DO-NOT-EDIT. This file was auto-generated using github:vic/flake-file.
# Use `nix run .#write-flake` to regenerate it.
{
  description = "Multipixelone (Finn)'s nix + HomeManager config";

  outputs = inputs: import ./outputs.nix inputs;

  nixConfig = {
    abort-on-warn = true;
    allow-import-from-derivation = false;
    extra-experimental-features = [ "pipe-operators" ];
    extra-substituters = [
      "https://yazi.cachix.org"
      "https://helix.cachix.org"
      "https://cache.nixos.org"
      "https://attic-cache.fly.dev/system?priority=50"
      "https://nix-community.cachix.org"
      "https://hyprland.cachix.org"
      "https://anyrun.cachix.org"
      "https://prismlauncher.cachix.org"
      "https://nix-gaming.cachix.org"
    ];
    extra-trusted-public-keys = [
      "yazi.cachix.org-1:Dcdz63NZKfvUCbDGngQDAZq6kOroIrFoyO064uvLh8k="
      "helix.cachix.org-1:ejp9KQpR1FBI2onstMQ34yogDm4OgU2ru6lIwPvuCVs="
      "cache.nixos.org-1:6NCHdD59X431o0gWypbY0EwA8p4P9YJf5vN2+6s8YfA="
      "system:XwpCBI5UHFzt9tEmiq3v8S062HvTqWPUwBR8PoHSfSk="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "hyprland.cachix.org-1:a7pgxzMz7+chwVL3/pzj6jIBMioiJM7ypFP8PwtkuGc="
      "anyrun.cachix.org-1:pqBobmOjI7nKlsUMV25u9QHa9btJK65/C8vnO3p346s="
      "prismlauncher.cachix.org-1:9/n/FGyABA2jLUVfY+DEp4hKds/rwO+SCOtbOkDzd+c="
      "nix-gaming.cachix.org-1:nbjlureqMbRAxR1gJ/f3hxemL9svXaZF/Ees8vCUUs4="
    ];
  };

  inputs = {
    agenix = {
      url = "github:ryantm/agenix";
      inputs = {
        home-manager.follows = "home-manager";
        nixpkgs.follows = "nixpkgs";
        systems.follows = "systems";
      };
    };
    anyrun.url = "github:fufexan/anyrun/launch-prefix";
    anyrun-nixos-options = {
      url = "github:n3oney/anyrun-nixos-options";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    apple-emoji = {
      url = "github:samuelngs/apple-emoji-linux/b22ae7f";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    apple-fonts.url = "github:Lyndeno/apple-fonts.nix";
    auto-cpufreq = {
      url = "github:AdnanHodzic/auto-cpufreq";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    base16.url = "github:SenchoPens/base16.nix";
    beets-plugins = {
      url = "github:Multipixelone/beets-plugins";
      inputs.beets-src.follows = "beets-src";
    };
    beets-src = {
      url = "github:beetbox/beets";
      flake = false;
    };
    better-fox = {
      url = "github:yokoffing/Betterfox";
      flake = false;
    };
    bgutil-ytdlp-pot-provider = {
      url = "github:Brainicism/bgutil-ytdlp-pot-provider";
      flake = false;
    };
    blocklist = {
      url = "github:StevenBlack/hosts";
      flake = false;
    };
    calibre-plugins.url = "github:nydragon/calibre-plugins";
    catppuccin.url = "github:catppuccin/nix";
    catppuccin-foot = {
      url = "github:catppuccin/foot";
      flake = false;
    };
    catppuccin-helix = {
      url = "github:catppuccin/helix";
      flake = false;
    };
    caveman = {
      url = "github:JuliusBrussee/caveman";
      flake = false;
    };
    claude-code-src = {
      url = "github:anthropics/claude-code";
      flake = false;
    };
    colmena = {
      url = "github:zhaofengli/colmena";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    direnv-instant = {
      url = "github:Mic92/direnv-instant";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    euphony = {
      url = "github:Multipixelone/euphony/nix-build";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    files.url = "github:mightyiam/files";
    flake-compat.url = "github:edolstra/flake-compat";
    flake-file.url = "github:vic/flake-file";
    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };
    flake-root.url = "github:srid/flake-root";
    flake-utils = {
      url = "github:numtide/flake-utils";
      inputs.systems.follows = "systems";
    };
    git-hooks = {
      url = "github:cachix/git-hooks.nix";
      inputs = {
        flake-compat.follows = "flake-compat";
        nixpkgs.follows = "nixpkgs";
      };
    };
    github-gitignore = {
      url = "github:github/gitignore";
      flake = false;
    };
    helix.url = "github:spion/helix/textDocument/inlineCompletion";
    home-manager = {
      url = "github:nix-community/home-manager/master";
      inputs.nixpkgs.follows = "nixpkgs";
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
    ignoreBoy = {
      url = "github:Ookiiboy/ignoreBoy";
      inputs.gitignore-repo.follows = "github-gitignore";
    };
    import-tree.url = "github:vic/import-tree";
    khinsider = {
      url = "github:Multipixelone/khinsider/nix-build";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
    lanzaboote = {
      url = "github:nix-community/lanzaboote/v1.0.0";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    make-shell = {
      url = "github:nicknovitski/make-shell";
      inputs.flake-compat.follows = "flake-compat";
    };
    mcp-servers-nix = {
      url = "github:natsukium/mcp-servers-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    millennium.url = "github:SteamClientHomebrew/Millennium?dir=packages/nix";
    monocle.url = "github:Multipixelone/monocle/nix-build";
    musnix.url = "github:musnix/musnix";
    nextmeeting = {
      url = "github:Multipixelone/nextmeeting/reformat?dir=packaging";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
    nix-gaming = {
      url = "github:fufexan/nix-gaming";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    nix-hardware.url = "github:NixOS/nixos-hardware/master";
    nix-index-database = {
      url = "github:nix-community/nix-index-database";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixcord.url = "github:ScarsTRF/nixcord/pnpmFix";
    nixos-facter-modules.url = "github:numtide/nixos-facter-modules";
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";
    nixpkgs-mine.url = "github:Multipixelone/nixpkgs/init-soundshow";
    nixpkgs-stable.url = "github:nixos/nixpkgs/nixos-25.05";
    nixpkgs-xr.url = "github:nix-community/nixpkgs-xr";
    noctalia = {
      url = "github:noctalia-dev/noctalia-shell";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        noctalia-qs.follows = "noctalia-qs";
      };
    };
    noctalia-qs = {
      url = "github:noctalia-dev/noctalia-qs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    nur.url = "github:nix-community/NUR";
    playlist-download = {
      url = "github:Multipixelone/playlist-downloader";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
    qmd.url = "github:tobi/qmd";
    qtscrob = {
      url = "github:Multipixelone/QtScrobbler/nix-build";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
    quadlet-nix.url = "github:SEIAROTg/quadlet-nix";
    rb-scrobbler = {
      url = "github:Multipixelone/rb-scrobbler/nix-build";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    room.url = "github:Multipixelone/room/reduce-binary-size";
    secrets = {
      url = "git+ssh://git@github.com/Multipixelone/nix-secrets.git";
      flake = false;
    };
    spicetify-nix = {
      url = "github:Gerg-L/spicetify-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    statix = {
      url = "github:molybdenumsoftware/statix";
      inputs = {
        flake-parts.follows = "flake-parts";
        nixpkgs.follows = "nixpkgs";
      };
    };
    steam-easygrid = {
      url = "github:luthor112/steam-easygrid";
      flake = false;
    };
    streamrip = {
      url = "github:mikelandzelo173/streamrip/feat/qobuz-login-fix";
      flake = false;
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
    systems.url = "github:nix-systems/default-linux";
    tinted-schemes = {
      url = "github:tinted-theming/schemes";
      flake = false;
    };
    treefmt-nix = {
      url = "github:numtide/treefmt-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    ucodenix.url = "github:e-tho/ucodenix";
    uwu-colors = {
      url = "github:q60/uwu_colors";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    waybar-mediaplayer = {
      url = "github:Multipixelone/waybar-mediaplayer/artist";
      inputs = {
        flake-utils.follows = "flake-utils";
        nixpkgs.follows = "nixpkgs";
      };
    };
    wrappers = {
      url = "github:BirdeeHub/nix-wrapper-modules";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    yt-dlp-YTNSigDeno = {
      url = "github:bashonly/yt-dlp-YTNSigDeno";
      flake = false;
    };
    zjstatus.url = "github:dj95/zjstatus";
    zjstatus-hints = {
      url = "github:b0o/zjstatus-hints";
      inputs.rust-overlay.follows = "monocle/rust-overlay";
    };
    zsm.url = "github:Multipixelone/zsm/nix-build";
  };
}
