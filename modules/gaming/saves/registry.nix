# Schema for the Core policy and Client profiles, and the single resolved
# projection every consumer reads.
#
# Options only. The data lives next door in policy.nix, so the rules can be
# driven by synthetic fixtures in `perSystem.checks.*` without dragging the real
# policy -- or a NixOS system -- into the test. This is the same split
# lib/service-publication.nix and modules/service-publication/registry.nix
# already use, for the same reason.
#
# The resolved inventory hard-asserts on `errors` at evaluation time. A
# contradictory profile is not a warning and does not degrade to a subset: it
# fails the build, because the failure mode it prevents -- a client that
# silently syncs the wrong games, or loads a game under a core whose battery
# saves are incompatible -- is invisible until a save is already lost.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;
  savesLib = import ../../../lib/retroarch-saves.nix { inherit lib; };

  systemType = types.submodule (
    { name, ... }:
    {
      options = {
        core = mkOption {
          type = types.str;
          description = ''
            libretro core attribute name, as it appears inside
            `pkgs.retroarch.withCores (cores: with cores; [ ... ])`. Managed
            clients install this automatically; unmanaged clients are told to.
            `DETECT` is rejected -- a missing core must fail visibly.
          '';
        };
        libraryName = mkOption {
          type = types.str;
          description = ''
            The core's RetroArch display name. Recorded for validation reports
            only: it is deliberately NOT part of any save path, because it
            changes between core builds and would split one game's saves across
            two remote directories.
          '';
        };
        canonicalDir = mkOption {
          type = types.str;
          default = name;
          description = ''
            The one identifier that must match byte-for-byte on every client:
            the Library platform directory under `roms/`, the client's ROM
            subdirectory, and -- because
            `sort_savefiles_by_content_enable` derives the save subdirectory
            from the ROM's parent directory name -- the save directory too.
          '';
        };
        romExtensions = mkOption {
          type = types.listOf types.str;
          description = "ROM file extensions this system contributes to the ROM channel.";
        };
        saveExtensions = mkOption {
          type = types.nonEmptyListOf types.str;
          description = ''
            Save-file extensions the emulated hardware writes. The ROM and BIOS
            channels' rejection set is the union of these across every declared
            system plus RetroArch's save-state extensions, so adding a system
            extends the rejection set in the same edit.
          '';
        };
      };
    }
  );

  exceptionType = types.submodule {
    options = {
      core = mkOption {
        type = types.str;
        description = "libretro core attribute that overrides the system default for this game.";
      };
      why = mkOption {
        type = types.str;
        description = "Why this game does not use its system's default core. Required.";
      };
    };
  };

  # The policy's own vocabulary, not a Library inventory. Only games the policy
  # actually names -- exceptions, per-game inclusions and exclusions, the pilot
  # -- appear here, which is what lets validation be closed without committing a
  # text database of every ROM.
  contentIdentityType = types.submodule {
    options = {
      title = mkOption {
        type = types.str;
        description = "Human-readable title, for validation reports and runbooks.";
      };
      why = mkOption {
        type = types.str;
        description = "Why the policy names this game at all.";
      };
    };
  };

  clientPathsType = types.submodule {
    options = {
      roms = mkOption { type = types.str; };
      bios = mkOption { type = types.str; };
      saves = mkOption { type = types.str; };
      states = mkOption { type = types.str; };
      playlists = mkOption { type = types.str; };
      config = mkOption { type = types.str; };
      system = mkOption { type = types.str; };
      coreAssets = mkOption {
        type = types.str;
        description = ''
          RetroArch's `core_assets_directory`. Named explicitly because it is
          where Cloud Sync keeps `manifest.local` / `manifest.server` and the
          `cloud_backups/` tree -- the recovery runbook has to point at it, and
          nothing about the name suggests sync state lives there.
        '';
      };
    };
  };

  clientType = types.submodule {
    options = {
      platform = mkOption {
        type = types.enum [
          "linux"
          "ios"
          "android"
        ];
      };
      managed = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether Nix owns this client's configuration and installs its cores.
          Unmanaged clients get generated artifacts plus a validation report and
          are held to the policy procedurally, at setup and upgrade time.
        '';
      };
      systems = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Emulated systems included in full.";
      };
      includeGames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Individual content identities included from otherwise-disabled systems.";
      };
      excludeGames = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = "Individual content identities excluded from enabled systems.";
      };
      paths = mkOption { type = clientPathsType; };
    };
  };
in
{
  options.saveSync = {
    corePolicy = {
      systems = mkOption {
        type = types.attrsOf systemType;
        default = { };
      };
      exceptions = mkOption {
        type = types.attrsOf exceptionType;
        default = { };
        description = "Per-game core overrides, keyed by content identity.";
      };
      extraCores = mkOption {
        type = types.listOf types.str;
        default = [ ];
        description = ''
          Cores installed on managed clients that no system prescribes. This is
          not a second policy: it exists so a core that WROTE an existing save
          can still open and export it during the migration, after the policy
          has moved its system to a different default.
        '';
      };
    };

    contentIdentities = mkOption {
      type = types.attrsOf contentIdentityType;
      default = { };
    };

    clients = mkOption {
      type = types.attrsOf clientType;
      default = { };
    };

    webdav = {
      publicUrl = mkOption {
        type = types.str;
        description = "Save authority root URL, exactly as every client writes it into webdav_url.";
      };
      port = mkOption { type = types.port; };
      dataDir = mkOption {
        type = types.str;
        description = "Dedicated Btrfs subvolume rclone serves. Outside the Library and outside RomM's assets.";
      };
      snapshotDir = mkOption {
        type = types.str;
        description = "Directory btrbk writes read-only snapshots into. Same filesystem as dataDir.";
      };
    };

    pilot = {
      emeraldContentIdentity = mkOption {
        type = types.nullOr types.str;
        default = null;
        description = ''
          Canonical Library-relative content identity of the pilot GBA title,
          as `<canonicalDir>/<stem>`. Unset by default and validated on use:
          `/media/Data/romm/library` is mode 0750 romm:romm and is not readable
          by the login user, so this cannot be discovered without either an
          operator granting read access or running
          `sudo ls /media/Data/romm/library/roms/gba`.
        '';
      };
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Whether the pilot projection is active. Requires emeraldContentIdentity.";
      };
    };

    retroarch = {
      manageConfig = mkOption {
        type = types.bool;
        default = false;
        description = ''
          Whether Nix owns the complete `retroarch.cfg` on managed clients.
          Defaults off because turning it on without `baseSettings` would
          replace 3333 hand-tuned settings with RetroArch's defaults. The
          migration workflow is: `retroarch-config-import` -> review the diff ->
          populate baseSettings -> flip this.
        '';
      };
      baseSettings = mkOption {
        type = types.attrsOf types.str;
        default = { };
        description = ''
          The imported, secret-free settings from the live configuration.
          Managed keys always override these. Generated by
          `retroarch-config-import`, which refuses to emit any key in
          `secretKeys`.
        '';
      };
    };
  };

  config.flake.saveSyncInventory =
    let
      cfg = config.saveSync;
      errors =
        savesLib.validate {
          inherit (cfg.corePolicy) systems exceptions;
          inherit (cfg) clients contentIdentities;
        }
        # The pilot is the one place a value genuinely cannot be known here, so
        # it follows the prescribed shape: unset by default, and an error that
        # names exactly what to supply and where the moment it is switched on.
        ++ lib.optional (cfg.pilot.enable && cfg.pilot.emeraldContentIdentity == null) ''
          pilot: saveSync.pilot.emeraldContentIdentity is unset.
          Set it in modules/gaming/saves/policy.nix to the canonical
          Library-relative identity of the pilot GBA title, as <canonicalDir>/<stem>
          -- for example "gba/Pokemon Emerald-R v231014". Discover it with
            sudo ls /media/Data/romm/library/roms/gba
          on link; the login user cannot read that directory.
        ''
        ++ lib.optional (
          cfg.pilot.enable
          && cfg.pilot.emeraldContentIdentity != null
          && !(cfg.contentIdentities ? ${cfg.pilot.emeraldContentIdentity})
        ) "pilot: ${cfg.pilot.emeraldContentIdentity} is not declared in saveSync.contentIdentities"
        ++ lib.optional (cfg.retroarch.manageConfig && cfg.retroarch.baseSettings == { }) ''
          retroarch: saveSync.retroarch.manageConfig is on but baseSettings is empty.
          Rendering now would drop every setting the live file holds. Run
            retroarch-config-import
          on link, review the diff it prints, and paste its output into
          saveSync.retroarch.baseSettings before enabling this.
        '';

      resolved = {
        inherit errors;
        inherit (cfg)
          clients
          contentIdentities
          webdav
          pilot
          ;
        inherit (cfg.corePolicy) systems exceptions;
        saveExtensions = savesLib.saveExtensionsOf cfg.corePolicy.systems;
        inherit (savesLib) stateExtensions;
        rejectedExtensions = savesLib.rejectedExtensionsOf cfg.corePolicy.systems;
        # Every core any declared client must be able to load. Managed clients
        # install exactly this set, so the withCores list and the policy cannot
        # drift apart.
        requiredCores = lib.naturalSort (
          lib.unique (
            lib.concatMap (
              client:
              savesLib.coresFor {
                inherit (cfg.corePolicy) systems exceptions;
                inherit client;
              }
            ) (builtins.attrValues (lib.filterAttrs (_: client: client.managed) cfg.clients))
            ++ cfg.corePolicy.extraCores
          )
        );
        stignore = lib.mapAttrs (_: client: {
          roms = savesLib.renderStignore {
            kind = "roms";
            inherit (client) systems includeGames excludeGames;
            rejectedExtensions = savesLib.rejectedExtensionsOf cfg.corePolicy.systems;
          };
          bios = savesLib.renderStignore {
            kind = "bios";
            systems = savesLib.biosSystemsFor client;
            includeGames = [ ];
            excludeGames = [ ];
            rejectedExtensions = savesLib.rejectedExtensionsOf cfg.corePolicy.systems;
          };
        }) cfg.clients;
      };
    in
    assert lib.assertMsg (errors == [ ]) (lib.concatStringsSep "\n" errors);
    resolved;

  options.flake.saveSyncInventory = mkOption {
    type = types.raw;
    description = "Resolved Core policy and Client profile projection. Asserts on evaluation.";
  };
}
