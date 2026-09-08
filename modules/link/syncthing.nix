# link's Syncthing config, brought into Nix.
#
# WHAT NIX OWNS HERE, AND WHAT IT DOES NOT
#
# `overrideFolders` and `overrideDevices` are both pinned OFF. They default to
# TRUE, and the DELETE loop in nixpkgs' merge-syncthing-config runs whenever the
# flag is set: it lists every folder/device the daemon holds, subtracts the ones
# declared here, and deletes the rest. link's daemon carries 26 folders and 17
# devices of hand-built state -- Books, the Clone Hero library, FNV profiles,
# the YouTube archive, the WiiU and Kingdom Hearts trees, two Kindles, a
# router, a Fedora box -- and only the ones below are worth Nix's attention.
# Turning either flag on would delete the other eleven folders on the next
# activation.
#
# So: everything declared below is AUTHORITATIVE (a declared folder or device is
# POSTed as a whole object and REPLACES what the daemon holds under that ID),
# and everything not declared is LEFT ALONE. Adding a folder in the web UI still
# works and still survives; it simply is not tracked here.
#
# IMPORT FIDELITY. Every folder and device below was read off the live
# config.xml and diffed field-by-field against the daemon's own `<defaults>`
# template. The only live values that differ from those defaults are the ones
# written out here -- id, label, path, type, the device list, and `saves`'
# staggered versioning. That matters because a POST to /rest/config/folders
# starts from `defaults`, not from the folder's current state: any field NOT
# named here is reset to the default. Since the live values already equal the
# defaults, the import is behaviour-neutral. Do not add a folder to this file
# without running that same diff.
#
# TWO DELIBERATE EXCEPTIONS to behaviour-neutrality, both intended:
#
#   1. Devices are POSTed from `defaults.device`, where `paused` is false. The
#      live config has all 16 remote devices paused -- a `gamemode-start` that
#      never got its matching `gamemode-end`, which had left the daemon fully
#      paused and syncing nothing at all. The first activation after this lands
#      unpauses them. A gamemode pause during a later activation would likewise
#      be undone; that is a transfer resuming early, not data loss.
#
#   2. The legacy `roms` folder (id 3m6rp-ypawu, ~/.config/retroarch/roms) is
#      declared with an EMPTY device list. It used to fan out to eight devices;
#      the RomM Library replaces it as the ROM source. link keeps its local copy
#      and its history -- unsharing is not deleting, and it is reversible by
#      putting the names back -- but nothing syncs from it any more. Deleting
#      the folder entry outright stays an operator action, because with
#      `overrideFolders` off Nix cannot and should not do it.
#
# The retired retroarch `saves` folder (id mujrf-sx6dp) is a different case and
# is left shared exactly as it is: progress travels over the WebDAV save
# authority now (ADR-0002), but the migration tooling still reads this folder,
# and it is retired by hand once that is done.
#
# modules/link/gamemode.nix is unaffected by any of this: it pauses and resumes
# through /rest/system/pause and /rest/system/resume with the API key from
# age.secrets."syncthing". That endpoint suspends transfers process-wide and
# touches no folder or device configuration.
{ config, lib, ... }:
let
  inherit (lib) mkOption types;

  inventory = config.flake.saveSyncInventory;
  linkPaths = inventory.clients.link.paths;
  romsPath = linkPaths.roms;
  biosPath = linkPaths.bios;

  cfg = config.saveSync.syncthing;
  username = config.flake.meta.owner.username;

  # Syncthing device IDs are 8 groups of 7 base32 characters (RFC 4648 alphabet
  # minus 0/1/8/9), luhn-checked per group. The regex cannot prove a checksum,
  # but it does reject the two things that actually get pasted here by mistake:
  # a truncated ID and a device *name*.
  deviceIdPattern = "[A-Z2-7]{7}(-[A-Z2-7]{7}){7}";

  deviceType = types.submodule (
    { name, ... }:
    {
      options = {
        id = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            The device's Syncthing device ID, copied from that device's own
            "Show ID" screen. Never generated, never guessed.

            `null` means DECLARED BUT NOT YET PAIRED. That is a real state, not
            a placeholder to be tidied away: a device that has never run
            Syncthing has no ID to copy, so the folder lists here can name it
            before it exists. An unpaired device is filtered out of the
            generated config entirely -- no device object, and its name is
            dropped from every folder's device list -- so declaring one changes
            nothing on the daemon until the ID lands. Naming an unpaired device
            in `receivers` is the one case that fails the build, because that is
            someone believing a dataset is being delivered when it is not.
          '';
        };
        name = mkOption {
          type = types.str;
          default = name;
          description = ''
            Device name as it should appear in link's Syncthing config.
            Declaring a device POSTs the whole device object over the REST API
            and REPLACES any existing entry with the same ID, so this has to be
            the name you actually want -- it is not merged with what the daemon
            already holds.
          '';
        };
        introducer = mkOption {
          type = types.bool;
          default = false;
          description = ''
            Whether this device may introduce link to other devices. True only
            for alexandria, which is where most of these devices were learned
            from in the first place.
          '';
        };
      };
    }
  );

  deviceNames = builtins.attrNames cfg.devices;

  # Only devices with an ID reach the daemon. Everything downstream -- the
  # device objects, every folder's device list, the receiver set -- is built
  # from this, so an unpaired declaration is inert by construction rather than
  # by remembering to leave it out in three places.
  pairedDevices = lib.filterAttrs (_: device: device.id != null) cfg.devices;
  pairedNames = builtins.attrNames pairedDevices;
  unpairedNames = lib.subtractLists pairedNames deviceNames;
  onlyPaired = builtins.filter (name: pairedDevices ? ${name});

  libraryReceivers = lib.optionals cfg.shareDatasets cfg.receivers;

  # Folder id -> the devices it is shared with, by name. link itself is never
  # listed: Syncthing adds the local device to every folder on its own.
  folderShares = {
    # Retired as a sender; see exception 2 in the header.
    "3m6rp-ypawu" = [ ];
    "mujrf-sx6dp" = [
      "Nougat"
      "alexandria"
      "chocolate"
      "fedora"
      "minish"
      "rg35xxsp"
      "zelda"
    ];
    "4bvms-ufujg" = [
      "Macbook Pro"
      "alexandria"
      "eggs"
      "minish"
      "zelda"
    ];
    "playlists" = [
      "alexandria"
      "zelda"
    ];
    "transcoded-music" = [ "zelda" ];
    "multimc" = [
      "Macbook Pro"
      "alexandria"
      "eggs"
      "fedora"
      "finn-router"
      "link-win"
      "minish"
      "steamdeck"
      "zelda"
    ];
    "multimc-icons" = [
      "alexandria"
      "fedora"
      "link-win"
      "minish"
      "zelda"
    ];
    "sakft-erofr" = [
      "alexandria"
      "fedora"
      "steamdeck"
      "zelda"
    ];
    "singing" = [
      "alexandria"
      "zelda"
    ];
    "screenshots" = [
      "alexandria"
      "minish"
      "zelda"
    ];
    "qgis" = [
      "alexandria"
      "zelda"
    ];
    "vintage-story" = [
      "alexandria"
      "minish"
      "zelda"
    ];
    "tvhrc-cfaky" = [
      "alexandria"
      "fedora"
      "minish"
      "zelda"
    ];
    "romm-library-roms" = libraryReceivers;
    "romm-library-bios" = libraryReceivers;
  };

  referencedDevices = lib.unique (lib.concatLists (builtins.attrValues folderShares));

  # What actually gets written, per folder.
  sharesOf = id: onlyPaired folderShares.${id};
in
{
  options.saveSync.syncthing = {
    devices = mkOption {
      type = types.attrsOf deviceType;
      default = { };
      description = ''
        Every Syncthing device link shares a Nix-declared folder with, keyed by
        the name the folder lists. Devices link knows about but shares nothing
        declared with (the Kindles, Palma2, ciara-laptop) are deliberately
        absent: declaring one would POST a device object over the daemon's
        existing entry for no gain.
      '';
    };

    shareDatasets = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether the two one-way Library datasets are actually shared with
        receiving devices. Off by default and validated on use: real Syncthing
        device IDs cannot be invented, so the folders stay declared-but-unshared
        until an operator supplies them. Unshared `sendonly` folders are inert
        -- link scans them and offers them to nobody.
      '';
    };

    receivers = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = ''
        Names, from `saveSync.syncthing.devices`, of the devices that receive
        the ROM and BIOS Library datasets. link is never a receiver: its ROM
        path IS the Library.

        Ignore patterns are NOT set from here. They are per-device local state,
        and a receiver that wants a subset of the Library writes its own
        .stignore (the generated bundles in modules/gaming/saves/ do this for
        the two declared save-sync clients).
      '';
      example = [ "alexandria" ];
    };
  };

  config.saveSync.syncthing = {
    devices = {
      # The one introducer, and where most of the others came from.
      alexandria = {
        id = "RBYKQEM-33KIP3W-D6KE3OD-V66VRWA-O6HZMFD-PKBWCWI-FZF6JD7-IZGLHAK";
        introducer = true;
      };
      zelda.id = "N6HYTWO-7AD7HYG-T24LFDU-AJEQOO4-X6U3UG4-HQOZ4TG-4O5LESC-XXCUNAS";
      minish.id = "36AQOJE-HBX7O7L-M7C3UHJ-5SVQOZU-Y4ZOMVQ-ZRCXL77-MMQT2XK-6OYGXQR";
      # Named `deck` in zelda's own config for the same ID. link's name wins
      # here because it is the one this file's folder lists use.
      fedora.id = "WPTWVQC-SJIKJOM-6SXC474-A6AJXVA-CBS5WQB-SREKAIH-XP6YCHN-PGK7KQE";
      chocolate.id = "2EONGPH-A2FP7GT-JZ4JJ62-FO34AYT-FWL6MQS-3YS2ZGA-ZHBHRM6-7HIKYQC";
      Nougat.id = "6DWQHVY-NHDAQ3Y-AGUQVVF-I3JEGS3-N7EZV6F-AH2N6E4-XPV2CEW-LEVFZAE";
      rg35xxsp.id = "AUOMSOJ-DU37XYD-2NOOOWF-B7ZAHZH-74SGVQG-PODWS3G-XX5UHV4-TY22VAN";
      "Macbook Pro".id = "7UEQILL-Z6FB263-LBEKVZC-YYEC7A7-YCSBLMU-AJ5PXKN-4FXRZPD-6QRKNQC";
      eggs.id = "2FIOYOF-7XNFNFL-CFIVK76-OMKIZSR-MTVJCKO-TCK6AM3-F5UFNZX-KDNUOAK";
      finn-router.id = "I5BYRFS-6ROFYD3-NRFJBMC-NE6653P-47I64WI-3XAX2ER-OIBYALN-3T6USAN";
      link-win.id = "AW3NGYJ-KMR7OKW-JYXYRXG-I4UTF3L-HBDO7BC-KRZCMPU-W7GXXIU-KRPJSAK";
      steamdeck.id = "F2M3MJV-FYNRHJM-YRQWG6G-XN6DLFI-AJZGE7F-VTJRMK6-DAHLJ2F-FL7RBAW";

      # hylia is the nix-darwin MacBook, and it is NOT the device already
      # paired as "Macbook Pro" (7UEQILL...), which is a different machine.
      # Its Syncthing has never run, so it has no ID to copy yet: hylia's own
      # side is declared in modules/hylia/syncthing.nix and names link (whose
      # ID has always been known), so the first `darwin-rebuild switch` there
      # generates the identity and offers the connection to link.
      #
      # To finish the pairing: read the ID off hylia
      #   syncthing --device-id            # or the GUI, Actions -> Show ID
      # set it here, and add "hylia" to `receivers` below in the same edit.
      hylia.id = null;
    };

    shareDatasets = true;

    # The devices that used to receive the legacy `roms` folder, minus the two
    # hosts whose Syncthing config is itself declarative and has no Library
    # path yet (zelda, minish). Add them there first, then here.
    receivers = [
      "alexandria"
      "fedora"
      "chocolate"
      "Nougat"
      "rg35xxsp"
    ];
  };

  config.configurations.nixos.link.module =
    { config, ... }:
    {
      assertions = [
        {
          assertion = cfg.shareDatasets -> cfg.receivers != [ ];
          message = ''
            saveSync.syncthing.shareDatasets is on but saveSync.syncthing.receivers is empty.

            Name one or more devices from saveSync.syncthing.devices in
            modules/link/syncthing.nix. Pair the device with link in the
            Syncthing UI at http://localhost:8384 FIRST: declaring a device
            POSTs the whole device object and replaces whatever the daemon
            already holds under that ID, so the pairing has to exist before the
            declaration, not after.
          '';
        }
        {
          assertion = lib.all (
            name: builtins.match deviceIdPattern pairedDevices.${name}.id != null
          ) pairedNames;
          message = ''
            saveSync.syncthing.devices has an entry whose id is not a Syncthing device ID.

            Expected 8 groups of 7 characters from [A-Z2-7], separated by "-":
              AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH

            Read it off the device itself (Syncthing -> Actions -> Show ID). Do
            not shorten it and do not paste the device name.
          '';
        }
        {
          assertion = lib.all (name: pairedDevices ? ${name}) cfg.receivers;
          message = ''
            saveSync.syncthing.receivers names a device that has no Syncthing
            device ID yet: ${
              lib.concatStringsSep ", " (builtins.filter (n: !(pairedDevices ? ${n})) cfg.receivers)
            }

            An unpaired device receives nothing, so listing it here would claim
            a dataset is being delivered when no such device exists on the
            daemon. Either pair it and set its id in
            saveSync.syncthing.devices, or take it out of receivers.

            Currently declared but unpaired: ${
              if unpairedNames == [ ] then "(none)" else lib.concatStringsSep ", " unpairedNames
            }
          '';
        }
        {
          assertion = lib.all (name: cfg.devices ? ${name}) (cfg.receivers ++ referencedDevices);
          message = ''
            A folder in modules/link/syncthing.nix is shared with a device that
            is not declared in saveSync.syncthing.devices.

            Declared devices: ${lib.concatStringsSep ", " deviceNames}
            Referenced:       ${lib.concatStringsSep ", " (lib.unique (cfg.receivers ++ referencedDevices))}
          '';
        }
        {
          assertion = !(lib.elem "link" cfg.receivers) && !(cfg.devices ? link);
          message = ''
            link is declared as a Syncthing peer of itself. It is the SENDER of
            every one-way dataset here and the local device is added to each
            folder by Syncthing automatically; it must never appear in
            saveSync.syncthing.devices or .receivers.
          '';
        }
        {
          # link's own profile is what makes "no ROM dataset for link" true. If
          # somebody repoints clients.link.paths.roms at a private copy, these
          # sendonly folders stop being the Library and this file is a lie.
          assertion = romsPath == "/media/Data/romm/library/roms";
          message = ''
            saveSync.clients.link.paths.roms is ${romsPath}, not the Library at
            /media/Data/romm/library/roms. link is the SENDER of the ROM
            dataset and reads the Library directly; it must never be given a
            ROM replica of its own. Fix the client profile in
            modules/gaming/saves/policy.nix, or repoint the folders here
            deliberately.
          '';
        }
        {
          # library/ and library/roms and library/bios are created at 2770
          # romm:romm by modules/link/romm.nix. Duplicating that rule here would
          # put two tmpfiles lines on the same path in two generated files, so
          # this asserts the contract instead of restating it.
          assertion =
            config.systemd.tmpfiles.settings ? "20-romm-library"
            && config.systemd.tmpfiles.settings."20-romm-library" ? ${biosPath};
          message = ''
            ${biosPath} is no longer created by modules/link/romm.nix's
            systemd.tmpfiles.settings."20-romm-library" rule.

            The BIOS Syncthing folder below has that directory as its root, and
            Syncthing fails a folder whose root is absent. Restore the tmpfiles
            entry in modules/link/romm.nix (mode 2770, user romm, group romm,
            matching library/ and library/roms) rather than adding a second
            rule for the same path here.
          '';
        }
      ];

      # The Library is 2770 romm:romm and the daemon runs as tunnel, who is in
      # group romm declaratively (users.users.tunnel.extraGroups in
      # modules/link/romm.nix). That membership alone is NOT enough: systemd
      # resolves a unit's supplementary groups when the process STARTS, so a
      # daemon that has been up since before tunnel joined the group keeps the
      # old set and cannot stat the Library -- which is exactly why both
      # romm-library-* folders sat in `Failed initial scan ... permission
      # denied` for weeks while looking correctly configured. Naming the group
      # on the unit makes the grant part of the unit's identity, so a change to
      # it restarts the daemon instead of waiting for the next reboot.
      systemd.services.syncthing.serviceConfig.SupplementaryGroups = [ "romm" ];

      services.syncthing = {
        enable = true;
        user = username;
        configDir = "/home/${username}/.config/syncthing";

        # See the header. These are the whole reason this file is more than
        # four lines long.
        overrideFolders = false;
        overrideDevices = false;

        settings = {
          devices = lib.mapAttrs (_: device: {
            inherit (device) name introducer;
            # Non-null by construction: pairedDevices is filtered on exactly this.
            inherit (device) id;
          }) pairedDevices;

          # IDs are the permanent identity every receiver must match; labels are
          # cosmetic and may be renamed freely. Paths are reproduced exactly as
          # the live daemon holds them, trailing slashes and `~/` included, so
          # that a POST rewrites the folder in place rather than creating a
          # second folder for the same tree.
          folders = {
            # -- The RomM Library, one-way out of link ------------------------
            #
            # sendonly, not sendreceive: a receiver that deletes a ROM to free
            # space on a handheld must never propagate that deletion back into
            # the Library. Neither folder is nested inside the other, and
            # neither is an alternative ID for a tree that already has one.
            "romm-library-roms" = {
              id = "romm-library-roms";
              label = "RomM Library ROMs (one-way)";
              path = romsPath;
              type = "sendonly";
              devices = sharesOf "romm-library-roms";
            };
            "romm-library-bios" = {
              id = "romm-library-bios";
              label = "RomM Library BIOS (one-way)";
              path = biosPath;
              type = "sendonly";
              devices = sharesOf "romm-library-bios";
            };

            # -- Retired RetroArch trees --------------------------------------
            "3m6rp-ypawu" = {
              id = "3m6rp-ypawu";
              label = "roms";
              path = "/home/${username}/.config/retroarch/roms";
              devices = sharesOf "3m6rp-ypawu";
            };
            "mujrf-sx6dp" = {
              id = "mujrf-sx6dp";
              label = "saves";
              path = "~/.config/retroarch/saves";
              type = "sendonly";
              devices = sharesOf "mujrf-sx6dp";
              # Six months of staggered history. This is the only pre-WebDAV
              # copy of some saves, so it is reproduced exactly rather than
              # allowed to fall back to the no-versioning default.
              versioning = {
                type = "staggered";
                params.maxAge = "15552000";
              };
            };

            # -- Media --------------------------------------------------------
            "4bvms-ufujg" = {
              id = "4bvms-ufujg";
              label = "Music";
              path = "/media/Data/Music";
              type = "sendonly";
              devices = sharesOf "4bvms-ufujg";
            };
            "transcoded-music" = {
              id = "transcoded-music";
              label = "Transcoded-Music";
              path = "/media/Data/TranscodedMusic";
              devices = sharesOf "transcoded-music";
            };
            "playlists" = {
              id = "playlists";
              label = "Playlists";
              path = "/media/Data/Playlists";
              devices = sharesOf "playlists";
            };
            "singing" = {
              id = "singing";
              label = "Singing";
              path = "~/Music/Singing";
              devices = sharesOf "singing";
            };

            # -- Games --------------------------------------------------------
            "multimc" = {
              id = "multimc";
              label = "Prism Launcher";
              path = "/home/${username}/.local/share/PrismLauncher/instances/";
              devices = sharesOf "multimc";
            };
            "multimc-icons" = {
              id = "multimc-icons";
              label = "Prism Launcher Icons";
              path = "/home/${username}/.local/share/PrismLauncher/icons/";
              devices = sharesOf "multimc-icons";
            };
            "sakft-erofr" = {
              id = "sakft-erofr";
              label = "ShipOfHarkinian";
              path = "/media/BigData/Games/ShipOfHarkinian/";
              devices = sharesOf "sakft-erofr";
            };
            "vintage-story" = {
              id = "vintage-story";
              label = "Vintage Story Saves";
              path = "/home/${username}/.config/VintagestoryData/Saves";
              devices = sharesOf "vintage-story";
            };
            "tvhrc-cfaky" = {
              id = "tvhrc-cfaky";
              label = "Steam Assets";
              path = "/home/${username}/.local/share/Steam/userdata/122579086/config/grid";
              devices = sharesOf "tvhrc-cfaky";
            };

            # -- Everything else ----------------------------------------------
            "qgis" = {
              id = "qgis";
              label = "qgis";
              path = "~/qgis";
              devices = sharesOf "qgis";
            };
            "screenshots" = {
              id = "screenshots";
              label = "screenshots";
              path = "~/Pictures/Screenshots";
              devices = sharesOf "screenshots";
            };
          };
        };
      };
    };
}
