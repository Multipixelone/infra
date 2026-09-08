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
          type = types.str;
          description = ''
            The device's Syncthing device ID, copied from that device's own
            "Show ID" screen. Never generated, never guessed -- so a device
            gets declared here only once it has actually run Syncthing.
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
      # link is IN the registry even though it is never its own peer. The
      # Library mesh spans hosts, and modules/hylia/syncthing.nix has to name
      # link's ID from somewhere; a second copy hardcoded over there is a
      # constant that drifts. link's own module removes itself below.
      link.id = "XOMPLRL-64GMF4T-P4SQ4XN-GCG26C2-3BKWACO-4DSWVCW-BU755ZU-KOJUDQ2";

      # Historically the one introducer, and where most of the others came
      # from. The Library folders no longer lean on that: every mesh member is
      # declared, because an introduced device is invisible to nix and any host
      # running overrideDevices deletes it on the next activation.
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

      # The nix-darwin MacBook. NOT the device paired as "Macbook Pro"
      # (7UEQILL...), which is a different machine that keeps its own entry
      # above. This ID was generated by hylia's own first switch --
      # modules/hylia/syncthing.nix declares that side, receive-only, and named
      # link from the start -- and read off the device afterwards.
      hylia.id = "YXBPBVN-GU6MEU4-PEFAUK3-RF3XSWQ-ANWPPUL-FNSE2RJ-TKWAXD7-L7OCUQ3";

      # The Android handheld, and the one receiver that is also a declared
      # save-sync client (saveSync.clients.rg-slide in
      # modules/gaming/saves/policy.nix). The name matches that client key on
      # purpose: its generated .stignore pair is what narrows the Library down
      # to the one pilot title on this device, and a mismatched name would
      # leave the bundle and the folder talking about different machines.
      rg-slide.id = "2CNWCBJ-6OP67X6-CLOVJSW-5U2W2TJ-MQ7ZD5I-EENP7DE-6YINPLH-3ASEAQT";
    };

    shareDatasets = true;

    # Every device that carries the Library. Together with link these are the
    # mesh: each member is declared on every other member, so a replica pulls
    # from whichever peer is awake instead of only from link.
    #
    # chocolate is the iPad, and so it is the device the `ios` client profile
    # in modules/gaming/saves/policy.nix describes -- the names differ because
    # one is a Syncthing device and the other a save-sync client, but they are
    # one machine. Its generated roms.stignore is what narrows the Library to
    # the pilot title there; the folder below carries the whole Library and the
    # .stignore on the device decides what actually lands.
    receivers = [
      "alexandria"
      "fedora"
      "Nougat"
      "rg35xxsp"
      "hylia"
      "rg-slide"
      "chocolate"
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
            name: builtins.match deviceIdPattern cfg.devices.${name}.id != null
          ) deviceNames;
          message = ''
            saveSync.syncthing.devices has an entry whose id is not a Syncthing device ID.

            Expected 8 groups of 7 characters from [A-Z2-7], separated by "-":
              AAAAAAA-BBBBBBB-CCCCCCC-DDDDDDD-EEEEEEE-FFFFFFF-GGGGGGG-HHHHHHH

            Read it off the device itself (Syncthing -> Actions -> Show ID). Do
            not shorten it and do not paste the device name.
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
          assertion =
            (cfg.devices ? link) && !(lib.elem "link" cfg.receivers) && !(lib.elem "link" referencedDevices);
          message = ''
            saveSync.syncthing.devices.link must be declared, and link must
            never be one of its own peers.

            Declared: every other host in the Library mesh reads link's device
            ID out of this registry instead of hardcoding a second copy.

            Never a peer: link is the SENDER of both one-way datasets, and
            Syncthing adds the local device to every folder by itself. link's
            own module strips itself out of what it POSTs, so it must not
            appear in `receivers` or in any folder's device list here.
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
          # Everything except link itself: a device is never its own peer, and
          # Syncthing adds the local device to every folder on its own.
          devices = lib.mapAttrs (_: device: {
            inherit (device) name introducer;
            inherit (device) id;
          }) (removeAttrs cfg.devices [ "link" ]);

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
              devices = folderShares."romm-library-roms";
            };
            "romm-library-bios" = {
              id = "romm-library-bios";
              label = "RomM Library BIOS (one-way)";
              path = biosPath;
              type = "sendonly";
              devices = folderShares."romm-library-bios";
            };

            # -- Retired RetroArch trees --------------------------------------
            "3m6rp-ypawu" = {
              id = "3m6rp-ypawu";
              label = "roms";
              path = "/home/${username}/.config/retroarch/roms";
              devices = folderShares."3m6rp-ypawu";
            };
            "mujrf-sx6dp" = {
              id = "mujrf-sx6dp";
              label = "saves";
              path = "~/.config/retroarch/saves";
              type = "sendonly";
              devices = folderShares."mujrf-sx6dp";
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
              devices = folderShares."4bvms-ufujg";
            };
            "transcoded-music" = {
              id = "transcoded-music";
              label = "Transcoded-Music";
              path = "/media/Data/TranscodedMusic";
              devices = folderShares."transcoded-music";
            };
            "playlists" = {
              id = "playlists";
              label = "Playlists";
              path = "/media/Data/Playlists";
              devices = folderShares."playlists";
            };
            "singing" = {
              id = "singing";
              label = "Singing";
              path = "~/Music/Singing";
              devices = folderShares."singing";
            };

            # -- Games --------------------------------------------------------
            "multimc" = {
              id = "multimc";
              label = "Prism Launcher";
              path = "/home/${username}/.local/share/PrismLauncher/instances/";
              devices = folderShares."multimc";
            };
            "multimc-icons" = {
              id = "multimc-icons";
              label = "Prism Launcher Icons";
              path = "/home/${username}/.local/share/PrismLauncher/icons/";
              devices = folderShares."multimc-icons";
            };
            "sakft-erofr" = {
              id = "sakft-erofr";
              label = "ShipOfHarkinian";
              path = "/media/BigData/Games/ShipOfHarkinian/";
              devices = folderShares."sakft-erofr";
            };
            "vintage-story" = {
              id = "vintage-story";
              label = "Vintage Story Saves";
              path = "/home/${username}/.config/VintagestoryData/Saves";
              devices = folderShares."vintage-story";
            };
            "tvhrc-cfaky" = {
              id = "tvhrc-cfaky";
              label = "Steam Assets";
              path = "/home/${username}/.local/share/Steam/userdata/122579086/config/grid";
              devices = folderShares."tvhrc-cfaky";
            };

            # -- Everything else ----------------------------------------------
            "qgis" = {
              id = "qgis";
              label = "qgis";
              path = "~/qgis";
              devices = folderShares."qgis";
            };
            "screenshots" = {
              id = "screenshots";
              label = "screenshots";
              path = "~/Pictures/Screenshots";
              devices = folderShares."screenshots";
            };
          };
        };
      };
    };
}
