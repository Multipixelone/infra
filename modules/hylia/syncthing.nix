# hylia's Syncthing, declared in home-manager.
#
# nix-darwin has NO syncthing module -- the pinned source contains no such file
# -- so this goes through home-manager, which does. On darwin its
# `services.syncthing` emits `launchd.agents.syncthing` plus
# `launchd.agents.syncthing-init`, and the init agent runs the SAME
# merge-syncthing-config script the NixOS module uses. So the declarative
# contract here is identical to link's: declared folders and devices are POSTed
# over the REST API and replace whatever the daemon holds.
#
# Unlike link, both override flags are ON. link's daemon carries 26 folders of
# hand-built state that predate nix and must survive; hylia's folders are all
# declared here, so there is no reason to let UI-added folders accumulate
# outside this file. If that stops being true, turn them off deliberately and
# say why, exactly as modules/link/syncthing.nix does.
#
# Device identities live in saveSync.syncthing.devices. The RomM Library mesh
# and Prism's link/zelda peers use that registry, never a second copy of an ID.
{ config, lib, ... }:
let
  user = config.flake.meta.owner.username;
  inventory = config.flake.saveSyncInventory;
  hyliaPaths = inventory.clients.hylia.paths;

  # The Library mesh, read out of the one registry in
  # modules/link/syncthing.nix rather than restated here: link (the sole
  # SENDER of both datasets) plus every receiver, minus hylia itself.
  #
  # Every peer is named explicitly instead of being learned through
  # Syncthing's introducer feature, and that is forced by overrideDevices
  # below. An introduced device exists only in the daemon's config; nix never
  # sees it, so the delete loop in merge-syncthing-config would remove it on
  # the very next activation and re-learn it on the next connection, forever.
  # Declared beats introduced whenever nix owns the file.
  syncthing = config.saveSync.syncthing;
  meshNames = lib.subtractLists [ "hylia" ] ([ "link" ] ++ syncthing.receivers);
  meshDevices = lib.filterAttrs (name: _: builtins.elem name meshNames) syncthing.devices;
  peerNames = builtins.attrNames meshDevices;
  prismPeers = [
    "link"
    "zelda"
  ];
  declaredDevices = lib.filterAttrs (
    name: _: builtins.elem name (meshNames ++ prismPeers)
  ) syncthing.devices;
in
{
  configurations.darwin.hylia.module = {
    assertions = [
      {
        assertion = builtins.elem "hylia" syncthing.receivers;
        message = ''
          hylia declares the two RomM Library folders but is not in
          saveSync.syncthing.receivers (modules/link/syncthing.nix).

          link would then offer them to nobody on this device, and these
          receive-only folders would sit empty forever while looking correctly
          configured. Add "hylia" there, or drop this module.
        '';
      }
      {
        # The whole point of reading the paths out of the inventory is that
        # this stays true. If the profile moves the ROM replica under the app
        # bundle or into the save tree, the receive-only folder would start
        # fighting RetroArch for a directory it also writes.
        assertion =
          lib.hasPrefix "~/Games/RomM/" hyliaPaths.roms && lib.hasPrefix "~/Games/RomM/" hyliaPaths.bios;
        message = ''
          saveSync.clients.hylia.paths.roms/.bios must stay under ~/Games/RomM/.

          They are the roots of two receive-only Syncthing folders. Pointing
          either at ~/Library/Application Support/RetroArch or at the save tree
          would put a folder Syncthing owns inside a directory RetroArch also
          writes, and a receive-only folder treats every local write as a
          conflict to be reverted.

          Current: roms = ${hyliaPaths.roms}, bios = ${hyliaPaths.bios}
        '';
      }
    ];

    # Taken as a function so `lib` here is home-manager's EXTENDED lib. The
    # flake-parts lib in this file's own arguments has no `lib.hm`, and
    # home.activation entries have to be tagged with lib.hm.dag.
    home-manager.users.${user} =
      { lib, ... }:
      {
        services.syncthing = {
          enable = true;

          overrideDevices = true;
          overrideFolders = true;

          settings = {
            devices = lib.mapAttrs (_: device: { inherit (device) id name; }) declaredDevices;

            # receiveonly, mirroring link's sendonly. The Library is
            # authoritative and lives on link; deleting a ROM here to reclaim
            # disk must never travel back. Every other mesh member is
            # receive-only too, and that is fine: a receive-only device still
            # SERVES what it holds, so hylia can pull from whichever peer is
            # awake while no peer can push a change back into the Library.
            #
            # The folder IDs are the permanent identity and MUST match link's
            # byte-for-byte -- the labels are cosmetic.
            folders = {
              "multimc" = {
                id = "multimc";
                label = "Prism Launcher";
                path = "~/Library/Application Support/PrismLauncher/instances/";
                type = "sendreceive";
                devices = prismPeers;
                # Receiver-local .stignore via Syncthing's API. Leave Linux
                # ignores alone; runtime data must be regenerated on the Mac.
                # Unrooted patterns match at any depth, including .minecraft
                # and minecraft game directories. Never ignore instance.cfg:
                # Prism requires it to discover an instance at all.
                ignorePatterns = [
                  "(?i)natives"
                  "(?i)logs"
                  "(?i)*.log"
                  "(?i)*.log.gz"
                  "(?i)crash-reports"
                  "(?i)assets"
                ];
              };
              "multimc-icons" = {
                id = "multimc-icons";
                label = "Prism Launcher Icons";
                path = "~/Library/Application Support/PrismLauncher/icons/";
                type = "sendreceive";
                devices = prismPeers;
              };
              "romm-library-roms" = {
                id = "romm-library-roms";
                label = "RomM Library ROMs";
                path = hyliaPaths.roms;
                type = "receiveonly";
                devices = peerNames;
              };
              "romm-library-bios" = {
                id = "romm-library-bios";
                label = "RomM Library BIOS";
                path = hyliaPaths.bios;
                type = "receiveonly";
                devices = peerNames;
              };
            };
          };
        };

        # Syncthing does create a missing folder root itself, but only once the
        # folder is actually shared and connected. Creating them up front means
        # RetroArch's Settings -> Directory can be pointed at real directories
        # during setup, before link has ever offered anything.
        home.activation.romLibraryDirs = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
          run mkdir -p "$HOME/Games/RomM/roms" "$HOME/Games/RomM/bios"
        '';
      };
  };
}
