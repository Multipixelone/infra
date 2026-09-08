# Everything an operator physically carries to a client, generated from the
# resolved inventory instead of typed: ignore patterns, playlists, core
# associations, expected paths, and the migration tooling that moves the live
# save tree onto the authority.
#
# The trap this file exists to avoid is the "one playlist, copied everywhere"
# reflex. A .lpl entry hard-codes an absolute ROM path AND an absolute core
# path, and those differ on every one of the three clients: link reads the
# Library at /media/Data/romm/library/roms and loads an ELF .so out of the Nix
# store, the RG Slide reads a microSD under Android's scoped storage and loads
# a *_libretro_android.so, and iOS reads a sandbox container and loads a
# *_libretro_ios.dylib. A playlist copied across that boundary does not fail
# loudly -- RetroArch shows the entries, and picking one does nothing, or
# quietly falls back to a core the policy never prescribed and whose battery
# saves the prescribed core cannot read. So every artifact here is generated
# per client, from that client's own profile, and the core filename is read
# back off nixpkgs rather than guessed: mkLibretroCore derives it from
# cores.nix's `core` argument, which is "mupen64plus-next" for the attribute
# `mupen64plus` and "pcsx_rearmed" for `pcsx-rearmed`. A hand-written second
# table is how a bundle ends up naming a core file that does not exist.
#
# Nothing generated here is committed and nothing generated here holds a
# credential. The WebDAV username and password reach a client through
# `retroarch-credential-stage`, one client at a time, into $XDG_RUNTIME_DIR --
# never through a bundle, because a bundle is a directory an operator copies
# onto a handheld's microSD.
{ config, lib, ... }:
let
  savesLib = import ../../../lib/retroarch-saves.nix { inherit lib; };
  inventory = config.flake.saveSyncInventory;

  defaultLibrary = "/media/Data/romm/library";

  # The focused per-client settings delta is declared elsewhere in the tree,
  # and every field of it is read through `or`, one level at a time. Today that
  # attribute carries `settings`, a pre-`rendered` form, a `delivery`
  # mechanism, the keys that stay manual, and free-text `notes`; a bundle must
  # still generate if it is absent or grows a different shape, with an honest
  # "no delta declared" rather than an evaluation failure at the far end of the
  # repository.
  clientSettings = config.flake.saveSyncClientSettings or { };
  deltaFor = name: clientSettings.${name}.settings or { };
  renderedFor =
    name: clientSettings.${name}.rendered or (savesLib.renderRetroarchConfig (deltaFor name));
  deliveryFor = name: clientSettings.${name}.delivery or null;
  manualKeysFor = name: clientSettings.${name}.manualKeys or [ ];
  notesFor = name: clientSettings.${name}.notes or [ ];

  # Rendered into the store and copied onto removable media, so the delta is
  # held to the same rule as managedSettings: no key that carries a credential,
  # ever. Checked by exact name against lib/retroarch-saves.nix's secretKeys --
  # a substring scan for password|token|key would strike out
  # input_enable_hotkey and eleven other benign keys.
  leakedKeys = name: lib.intersectLists savesLib.secretKeys (lib.attrNames (deltaFor name));
  leakingClients = lib.filter (name: leakedKeys name != [ ]) (builtins.attrNames inventory.clients);

  # Core shared-object naming, per platform, from the libretro buildbot's own
  # layout. These are the three suffixes RetroArch looks for; nothing about a
  # core's attribute name tells you which one a given device wants.
  coreSuffixes = {
    linux = "_libretro.so";
    android = "_libretro_android.so";
    ios = "_libretro_ios.dylib";
    # macOS is NOT the iOS suffix. The Apple buildbot ships desktop cores as a
    # bare `_libretro.dylib` and only the iOS tree carries the `_ios` infix, so
    # copying the ios value here would name a file that never exists and the
    # Core Downloader check in the bundle README would fail against every core.
    darwin = "_libretro.dylib";
  };

  # The core's RetroArch display name, taken from the policy rather than
  # invented: it is what the Core Downloader list shows on an unmanaged client,
  # which is the only thing an operator can match against by eye.
  libraryNameOf =
    attr:
    let
      matches = lib.filter (system: system.core == attr) (builtins.attrValues inventory.systems);
    in
    if matches == [ ] then attr else (lib.head matches).libraryName;

  stemOf = identity: lib.concatStringsSep "/" (lib.tail (lib.splitString "/" identity));
  identitiesIn = system: identities: lib.filter (i: savesLib.systemOfIdentity i == system) identities;

  # Every system a client carries content for: the ones it enables in full,
  # plus the ones a per-game inclusion reaches into.
  carriedSystems =
    client:
    lib.naturalSort (lib.unique (client.systems ++ map savesLib.systemOfIdentity client.includeGames));

  clientNames = builtins.attrNames inventory.clients;
in
{
  # Bundles and migration working trees are artifacts, not source. The
  # generators default to $XDG_STATE_HOME so nothing lands here in the first
  # place; these two entries only matter when somebody points --out at the
  # checkout. modules/git/ignore.nix owns the file itself, so after changing
  # this list run `nix run .#generate-files` to regenerate .gitignore.
  gitignore = [
    "/retroarch-save-bundles/"
    "/retroarch-save-migration/"
  ];

  perSystem =
    { pkgs, self', ... }:
    let
      # mkLibretroCore names the shared object after cores.nix's `core`
      # argument, and `pname` is the only place that argument survives into an
      # evaluated package. Reading it back keeps the bundle correct across a
      # nixpkgs bump; `mesen-s` is the single core in nixpkgs that opts out of
      # the "-" -> "_" normalisation, and no policy system uses it.
      coreFileBase =
        attr:
        let
          package =
            pkgs.libretro.${attr}
              or (throw "core policy names ${attr}, which is not an attribute of pkgs.libretro");
        in
        lib.replaceStrings [ "-" ] [ "_" ] (lib.removePrefix "libretro-" package.pname);

      coreEntry = platform: attr: {
        inherit attr;
        file = "${coreFileBase attr}${coreSuffixes.${platform}}";
        name = libraryNameOf attr;
      };

      systemSpec =
        client: system:
        let
          declared = inventory.systems.${system};
          whole = builtins.elem system client.systems;
          included = identitiesIn system client.includeGames;
          # A per-game core override only matters for a game this client
          # actually carries; an exception on a system it does not enable is
          # noise in the bundle.
          overrides = lib.filter (identity: whole || builtins.elem identity client.includeGames) (
            identitiesIn system (builtins.attrNames inventory.exceptions)
          );
        in
        {
          inherit whole;
          dir = declared.canonicalDir;
          inherit (declared) romExtensions;
          defaultCore = coreEntry client.platform declared.core;
          # Per-stem core, for the games whose core is not the system default
          # and for every individually included game.
          games = lib.listToAttrs (
            map (
              identity:
              lib.nameValuePair (stemOf identity) (
                coreEntry client.platform (
                  savesLib.coreFor {
                    inherit (inventory) systems exceptions;
                    inherit identity;
                  }
                )
              )
            ) (lib.unique (included ++ overrides))
          );
          # Games the bundle MUST find in the Library. A missing whole-system
          # directory is a thin bundle; a missing named game is a broken one.
          requiredStems = map stemOf included;
          excludeStems = map stemOf (identitiesIn system client.excludeGames);
        };

      specFor = name: client: {
        client = name;
        inherit (client) platform managed;
        romsRoot = client.paths.roms;
        biosRoot = client.paths.bios;
        playlistsRoot = client.paths.playlists;
        coreSuffix = coreSuffixes.${client.platform};
        inherit (client) paths;
        systems = lib.listToAttrs (
          map (system: lib.nameValuePair system (systemSpec client system)) (carriedSystems client)
        );
      };

      # savesLib.coresFor answers "the cores this client's ENABLED SYSTEMS
      # prescribe, plus any exception override it carries". That is the right
      # answer for the inventory's requiredCores, which only ever looks at
      # managed clients -- but it is empty for a client whose entire content
      # arrives through includeGames and which therefore enables no system at
      # all. Both pilot clients are exactly that shape, and an empty
      # required-core list on a handheld is the silent failure this bundle
      # exists to prevent: the operator installs nothing, RetroArch offers to
      # pick a core, and the first save is written by whatever it picked. So
      # the per-game cores are unioned back in here.
      coresForClient =
        client:
        lib.naturalSort (
          lib.unique (
            savesLib.coresFor {
              inherit (inventory) systems exceptions;
              inherit client;
            }
            ++ lib.filter (core: core != null) (
              map (
                identity:
                savesLib.coreFor {
                  inherit (inventory) systems exceptions;
                  inherit identity;
                }
              ) client.includeGames
            )
          )
        );

      coresDoc =
        name: client:
        let
          cores = coresForClient client;
          row =
            attr:
            "  ${attr}  ->  ${coreFileBase attr}${
                coreSuffixes.${client.platform}
              }  (\"${libraryNameOf attr}\")";
        in
        ''
          Required cores for ${name} (${client.platform})
          ===============================================

          Every core below must be present before a save from the authority is
          opened. Loading a game under a core the policy does not prescribe is
          how a battery save gets rewritten in a format the prescribed core
          cannot read -- .dsv and .srm for the same DS cartridge are already in
          the live save tree, which is what makes this a rule and not a caveat.

          attribute -> expected file in the core directory ("display name")

          ${
            if cores == [ ] then
              "  NONE. This client carries content but the policy prescribes no core for it.\n"
              + "  Do not proceed: that is a policy bug, not a client that needs nothing."
            else
              lib.concatStringsSep "\n" (map row cores)
          }

        ''
        + (
          if client.managed then
            ''
              This client is MANAGED. Nix installs these through
              pkgs.retroarch.withCores; nothing here is an install instruction.
              If a file above is missing from the core directory, the policy and
              modules/gaming/retroarch.nix have drifted -- fix the withCores
              list, do not download a core by hand.
            ''
          else
            ''
              This client is UNMANAGED. Install each core through RetroArch
              itself:

                Main Menu -> Online Updater -> Core Downloader -> "<display name>"

              Match on the display name in quotes above, then confirm the file
              that appeared in the core directory matches the expected filename.
              Never accept a near-match: "mGBA" and "VBA-M" both play GBA
              content and do not share a save format.

              Do NOT set a playlist entry's core to DETECT to work around a
              missing core. DETECT defers the choice to whatever RetroArch
              happens to rank first, which is exactly the silent substitution
              the core policy exists to prevent.
            ''
        );

      pathsDoc =
        name: client:
        let
          row = key: "${key}\t${client.paths.${key}}";
        in
        lib.concatLines (
          [ "# expected paths on ${name} -- key<TAB>path" ]
          ++ map row [
            "roms"
            "bios"
            "saves"
            "states"
            "playlists"
            "config"
            "system"
            "coreAssets"
          ]
        );

      deltaDoc =
        name:
        let
          delta = deltaFor name;
          note = line: "# ${line}";
        in
        if delta == { } then
          ''
            # No focused settings delta is declared for ${name}
            # (flake.saveSyncClientSettings.${name} is unset or carries no settings).
            #
            # That is a statement, not a gap: apply nothing beyond the Cloud Sync
            # credentials and the paths in paths.tsv.
          ''
        else
          lib.concatLines (
            [
              "# Focused settings delta for ${name}, generated -- do not edit."
              "#"
              "# Apply these keys ONE AT A TIME, in RetroArch's own settings UI or by"
              "# replacing the matching line in the existing retroarch.cfg. Never drop"
              "# this file in place of a config: it is a delta, and the file it would"
              "# replace holds the device's own controller mapping and video/audio"
              "# setup, none of which is represented here."
              "#"
              "# delivery: ${if deliveryFor name == null then "unspecified" else deliveryFor name}"
            ]
            ++ lib.optionals (manualKeysFor name != [ ]) [
              "# entered by hand, never shipped in a file:"
              "#   ${lib.concatStringsSep ", " (manualKeysFor name)}"
            ]
            ++ lib.optional (notesFor name != [ ]) "#"
            ++ map note (notesFor name)
            ++ [ "" ]
          )
          + renderedFor name;

      readmeCommon = name: client: ''
        RetroArch save-sync bundle: ${name}
        ${lib.concatStrings (lib.genList (_: "=") (28 + lib.stringLength name))}

        Generated from the Core policy and this client's profile. Deterministic,
        secret-free, and specific to ${name} -- nothing in here is portable to
        another client.

        Contents
        --------
          spec.json              the resolved projection this bundle was built from
          stignore/roms.stignore receiver-local Syncthing ignores, ROM dataset
          stignore/bios.stignore receiver-local Syncthing ignores, BIOS dataset
          playlists/<system>.lpl one playlist per system, with THIS client's paths
          cores.txt              required cores and how they are installed here
          retroarch-delta.cfg    the focused settings delta (may be a no-op)
          paths.tsv              expected paths
          manifest.tsv           verification manifest: what must exist, and under
                                 which core -- paths and cores only, no hashes,
                                 because a save's bytes change every session and a
                                 hash would turn normal play into a failed check

        What is NOT in here
        -------------------
        The WebDAV username and password. Each physical installation gets its
        own separately revocable credential; reinstalling, retiring or losing
        this device rotates that credential and nothing else. The server keeps
        only bcrypt hashes, so a leaked bundle leaks nothing. Stage the
        credential separately, on the machine you are provisioning from:

          nix run .#retroarch-credential-stage -- --client ${name}

        Playlists
        ---------
        Entries carry crc32 "00000000|crc", which is RetroArch's own placeholder
        for "CRC unknown" -- the value its manual scan writes when it cannot
        identify content. It is not a hash and must not be replaced with one
        that was made up. Thumbnail lookup will not resolve from it; run
        RetroArch's own scanner afterwards if you want thumbnails.

        Playlists here are ${lib.concatStringsSep ", " (map (s: "${s}.lpl") (carriedSystems client))}.
        Each is named after the policy's canonical system directory rather than
        after a libretro DAT system name. That directory string is already
        the one identifier that must match byte-for-byte everywhere -- Library
        directory, ROM subdirectory, and, because
        sort_savefiles_by_content_enable derives it from the ROM's parent
        directory, the remote save prefix too. Introducing a second naming
        scheme here whose only job is thumbnail lookup is how the two drift.
      '';

      readmeFor =
        name: client:
        readmeCommon name client
        + {
          linux = ''

            link is the SENDER
            ------------------
            link reads the Library directly: clients.link.paths.roms IS
            ${client.paths.roms}. It receives no ROM dataset and no BIOS
            dataset, and the two .stignore files in this bundle are NOT
            installed here. They are included so the sender can review the view
            each receiver is supposed to end up with.

            Cores are installed by Nix. Paths and the managed settings are
            owned by Nix too. So on link this bundle is a review artifact and a
            verification manifest, not an install kit.

            Validation
            ----------
              1. Every path in paths.tsv exists and is writable by tunnel.
              2. Every core file in cores.txt exists under the directory passed
                 as --core-dir.
              3. Every ROM path in manifest.tsv exists.
              4. After the migration cutover, ${client.paths.saves} contains
                 content-directory subdirectories (gba/, snes/, ...) and no
                 core-name subdirectories (mGBA/, gpSP/, ...). A core-name
                 directory left in place will be pushed to the authority on the
                 next Cloud Sync as a second, unrelated copy of every save.
          '';

          ios = ''

            iOS: App Store RetroArch
            ------------------------
            The app is sandboxed. Everything in paths.tsv is relative to the
            RetroArch Documents container -- the folder that appears as
            "RetroArch" under On My iPhone in Files.

            Getting the data across
            -----------------------
            Preferred: point Mobius at the RetroArch container directly. Mobius
            can pick a destination through the Files provider, so choosing
            On My iPhone -> RetroArch -> roms writes ROMs where RetroArch
            already looks and there is no second copy step, no duplicate
            occupying storage, and no chance of the two copies diverging.

            Fallback: Mobius -> its own storage -> Files -> drag into
            On My iPhone/RetroArch/. Use this when the provider picker refuses
            the destination, which it sometimes does after an iOS update.

            This is a MANUAL pull, every time. iOS gives no third-party app
            reliable background filesystem access, so treat ROM and BIOS
            updates as something you do deliberately while the app is in the
            foreground. Nothing here syncs ROMs on its own, and no bundle
            should be read as promising that it does.

            The .stignore files are included for reference only: there is no
            Syncthing on this device. They are the authoritative statement of
            which files belong here, and the set you should end up with after a
            manual copy.

            Credentials
            -----------
            Type them in by hand:

              Settings -> Cloud Sync -> Cloud Sync Backend: webdav
              Settings -> Cloud Sync -> URL / Username / Password

            Dropping a config fragment into the container does NOT apply on
            iOS. RetroArch reads its configuration at launch and rewrites the
            whole file, so a fragment is either ignored or clobbered, and there
            is no supported include mechanism. Do not tell yourself otherwise
            because the file "looks like it landed".

            Sync triggers on iOS are: app launch, core UNLOAD (not load), the
            menu's "Sync Now", and returning to the foreground after more than
            60 seconds in the background. There is no retry on reconnect and no
            durable queue -- if the network was down, nothing is queued for
            later. Close the content (which unloads the core) before locking
            the device.

            Validation
            ----------
              1. Files shows every path in paths.tsv under On My iPhone/RetroArch.
              2. Every core in cores.txt appears in Core Downloader as installed.
              3. Loading the playlist entry shows the core named in manifest.tsv,
                 not DETECT.
              4. Load the game, unload the core, and confirm the save appears on
                 the authority under saves/<system>/.
          '';

          darwin = ''

            hylia: macOS RetroArch
            ----------------------
            The app is the `retroarch-metal` Homebrew cask, declared in
            modules/gaming/retroarch-darwin.nix. Nix does NOT own the bundle,
            the cores or retroarch.cfg here: nixpkgs marks retroarch-bare
            broken on aarch64-darwin, so there is no closure to install and
            this client is `managed = false` for that reason and no other.

            Paths span TWO roots
            --------------------
            macOS does not put RetroArch under one directory. Saves and states
            default beneath ~/Documents/RetroArch, while config, playlists and
            downloads live beneath ~/Library/Application Support/RetroArch.
            paths.tsv reflects that split.

            Confirm every row against Settings -> Directory before trusting it.
            The rows were taken from RetroArch's documented macOS defaults, not
            measured on this machine, and a wrong savefile_directory does not
            raise an error -- it forks the save history silently, which is the
            failure this whole policy exists to prevent.

            Getting the data across
            -----------------------
            ROMs and BIOS arrive over Syncthing, receive-only, at
            ~/Games/RomM/roms and ~/Games/RomM/bios. Both folders are declared
            in modules/hylia/syncthing.nix and both are mirrors of link's
            sendonly originals: deleting a ROM here to reclaim disk is local
            only and never travels back to the Library. The two .stignore files
            in this bundle belong to those two folders.

            They live outside ~/Library/Application Support/RetroArch on
            purpose. A receive-only folder treats any local write as a conflict
            to revert, so its root must not be a directory RetroArch also
            writes. system_directory points AT the synced BIOS tree instead --
            one tree, delivered by Syncthing, read by RetroArch.

            Applying the delta
            ------------------
            Unlike iOS, macOS RetroArch has a command line:

              /Applications/RetroArch.app/Contents/MacOS/RetroArch \
                --appendconfig <path to retroarch-delta.cfg> --menu

            Launch it that way once and confirm the values under Settings.
            Launching the app from Finder or Spotlight passes no arguments, so
            the delta does NOT apply on an ordinary launch -- if the keys have
            to survive every launch, merge them into retroarch.cfg by hand
            instead, ONCE, and do not build a launcher for this.

            Never put the credentials in the appendconfig file. It sits in the
            home directory, which is exactly what a backup tool sweeps up.

            Cores
            -----
            Install them through RetroArch's own Online Updater -> Core
            Downloader. cores.txt names the file each one lands as; on macOS
            that is `<core>_libretro.dylib` under
            ~/Library/Application Support/RetroArch/cores.

            Validation
            ----------
              1. Every path in paths.tsv exists, and matches Settings -> Directory.
              2. Every core in cores.txt appears in Core Downloader as installed.
              3. The two Syncthing folders show "Up to Date" and the ROM count
                 matches the roms.stignore view.
              4. Load the game, unload the core, and confirm the save appears on
                 the authority under saves/<system>/.
          '';

          android = ''

            RG Slide: Android 13
            --------------------
            Target: the latest official 64-bit RetroArch
            (com.retroarch.aarch64) from retroarch.com or the Play Store.

            The factory Anbernic RetroArch is acceptable ONLY if it passes both
            tests below. Record the result in manifest.tsv's notes; do not skip
            them because the app "looks recent".

              Test 1 -- version. Main Menu -> Information -> System Information
              -> RetroArch version. Write it down. link runs 1.22.2; a build
              older than that lacks cloud_sync_sync_mode, which is harmless in
              itself (automatic is the only behaviour on older builds) but tells
              you exactly how far behind you are.

              Test 2 -- WebDAV Cloud Sync capability. Settings -> Cloud Sync
              must exist AND offer all of: Cloud Sync Enable, a Cloud Sync
              Backend selector containing "webdav", a URL/Username/Password
              triple, and a Destructive Cloud Sync toggle that can be turned
              OFF. If any one of those is missing, the build FAILS the test --
              WebDAV Cloud Sync has historically been absent from Android
              builds (libretro/RetroArch issue 16847), so this is a real
              failure mode and not a formality. Install official RetroArch.

            Scoped storage
            --------------
            Config, saves, states, playlists and Cloud Sync manifests live under
            the app's own external files directory
            (/storage/emulated/0/Android/data/com.retroarch.aarch64/files/...),
            which needs no permission grant and is what "internal
            app-accessible storage" means here. ROMs and BIOS live on the
            microSD under the roots this profile declares. Do not relocate
            either half: moving config onto the microSD costs you the
            no-permission property, and moving ROMs into app storage makes them
            invisible to the launcher.

            Leave the platform alone
            ------------------------
            Do NOT overwrite the device's controller mapping, video or audio
            settings. Anbernic ships a working input map and display
            configuration for this hardware, and RetroArch has no per-section
            merge -- replacing retroarch.cfg replaces those too. Apply
            retroarch-delta.cfg key by key.

            Validation
            ----------
              1. Every path in paths.tsv exists on the device.
              2. Every core in cores.txt is installed and matches the expected
                 filename.
              3. Buttons still work and the screen still fills correctly after
                 the delta is applied.
              4. Load the game, unload the core, and confirm the save appears on
                 the authority under saves/<system>/.
          '';
        }
        .${client.platform};

      staticBundle =
        name: client:
        pkgs.runCommand "retroarch-bundle-${name}" { } ''
          mkdir -p "$out/stignore"
          install -m0644 ${pkgs.writeText "roms.stignore" inventory.stignore.${name}.roms} \
            "$out/stignore/roms.stignore"
          install -m0644 ${pkgs.writeText "bios.stignore" inventory.stignore.${name}.bios} \
            "$out/stignore/bios.stignore"
          install -m0644 ${pkgs.writeText "cores.txt" (coresDoc name client)} "$out/cores.txt"
          install -m0644 ${pkgs.writeText "paths.tsv" (pathsDoc name client)} "$out/paths.tsv"
          install -m0644 ${pkgs.writeText "retroarch-delta.cfg" (deltaDoc name)} \
            "$out/retroarch-delta.cfg"
          install -m0644 ${pkgs.writeText "README" (readmeFor name client)} "$out/README"
          install -m0644 ${
            (pkgs.formats.json { }).generate "spec.json" (specFor name client)
          } "$out/spec.json"
        '';

      bundleCase = lib.concatStrings (
        lib.mapAttrsToList (name: client: ''
          ${name}) STATIC=${staticBundle name client} ;;
        '') inventory.clients
      );

      clientList = lib.concatStringsSep " " clientNames;

      # $XDG_STATE_HOME, not the checkout and not the Nix store: a bundle is a
      # working artifact that gets copied onto removable media and thrown away,
      # and a store path would be world-readable and immutable.
      defaultBundleRoot = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/retroarch-save-bundles"'';
      defaultWorkRoot = ''"''${XDG_STATE_HOME:-$HOME/.local/state}/retroarch-save-migration"'';

      saveExtensionList = lib.concatStringsSep "\n" inventory.saveExtensions;
      stateExtensionList = lib.concatStringsSep "\n" inventory.stateExtensions;
      # system name -> canonical Library directory, for the core-name to
      # content-directory remap.
      systemDirList = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (name: system: "${name}\t${system.canonicalDir}") inventory.systems
      );
      romExtensionList = lib.concatStringsSep "\n" (
        lib.concatLists (
          lib.mapAttrsToList (
            name: system: map (ext: "${name}\t${ext}") system.romExtensions
          ) inventory.systems
        )
      );
    in
    {
      packages = {
        retroarch-bundle-generate = pkgs.writeShellApplication {
          name = "retroarch-bundle-generate";
          meta.description = "Generate one client's RetroArch save-sync bundle from the Core policy";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            jq
          ];
          text = ''
            OUT=${defaultBundleRoot}
            LIBRARY="${defaultLibrary}"
            CLIENT=""
            CORE_DIR=""
            FORCE=0

            while [ $# -gt 0 ]; do
              case "$1" in
                --client) CLIENT="$2"; shift 2 ;;
                --core-dir) CORE_DIR="$2"; shift 2 ;;
                --library) LIBRARY="$2"; shift 2 ;;
                --out) OUT="$2"; shift 2 ;;
                --force) FORCE=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-bundle-generate --client NAME --core-dir DIR [--library DIR] [--out DIR] [--force]

              Writes one client's bundle: receiver-local .stignore files, one
              generated playlist per system, the required-core list, the focused
              settings delta, expected paths, and a verification manifest.

              --core-dir is REQUIRED and has no default. A playlist entry stores
              an absolute core path, and that path is a property of the device,
              not of this repository -- guessing it produces a playlist whose
              entries silently do nothing.

              Reads the Library to resolve which ROM files a system actually
              holds. Writes outside the checkout by default.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ -z "$CLIENT" ]; then
              echo "--client is required. Declared clients: ${clientList}" >&2
              exit 2
            fi

            case "$CLIENT" in
              ${bundleCase}
              *)
                echo "unknown client: $CLIENT" >&2
                echo "Declared clients: ${clientList}" >&2
                echo "Add it to saveSync.clients in modules/gaming/saves/policy.nix first." >&2
                exit 2 ;;
            esac

            PLATFORM="$(jq -r .platform "$STATIC/spec.json")"

            if [ -z "$CORE_DIR" ]; then
              cat >&2 <<EOF
            --core-dir is required and is not guessed.

            It is the directory the client loads cores from, and every playlist
            entry this tool writes stores an absolute path into it. Read it off
            the device:

              RetroArch -> Settings -> Directory -> Cores

            or, equivalently, Main Menu -> Information -> System Information,
            which prints the frontend's core directory. On $PLATFORM the cores in
            cores.txt must already be present there, or the playlist points at
            files that do not exist.

            Then rerun:

              retroarch-bundle-generate --client $CLIENT --core-dir <that directory>
            EOF
              exit 1
            fi

            ROMLIB="$LIBRARY/roms"
            if [ ! -d "$ROMLIB" ]; then
              echo "not a directory: $ROMLIB" >&2
              echo "Pass --library if the Library is somewhere other than ${defaultLibrary}." >&2
              exit 1
            fi
            if ! ls -A "$ROMLIB" >/dev/null 2>&1; then
              cat >&2 <<EOF
            Cannot read $ROMLIB

            The Library is mode 0750 romm:romm. The login user is in group romm
            declaratively, but group membership is read at LOGIN, so a shell
            started before that landed does not have it. Fix, cheapest first:

              sg romm -c 'retroarch-bundle-generate --client $CLIENT --core-dir $CORE_DIR'
              newgrp romm
              log out and back in

            Check with:  id -nG | tr ' ' '\n' | grep -x romm

            Refusing rather than emitting an empty bundle: an unreadable Library
            and an empty Library look identical from here, and the empty one
            would be copied onto a handheld before anybody noticed.
            EOF
              exit 1
            fi

            DEST="$OUT/$CLIENT"
            if [ -e "$DEST" ]; then
              if [ "$FORCE" -eq 0 ]; then
                echo "$DEST already exists. Rerun with --force to replace it." >&2
                exit 1
              fi
              rm -rf "''${DEST:?}"
            fi

            mkdir -p "$DEST"
            cp -rT "$STATIC" "$DEST"
            chmod -R u+w "$DEST"
            mkdir -p "$DEST/playlists"

            work="$(mktemp -d)"
            trap 'rm -rf "$work"' EXIT

            spec="$DEST/spec.json"
            ROMS_ROOT="$(jq -r .romsRoot "$spec")"

            manifest="$DEST/manifest.tsv"
            {
              printf '# verification manifest for %s -- kind\tpath\texpected_core\n' "$CLIENT"
              printf '# paths and cores only. No content hashes: a save file changes\n'
              printf '# every session, so a hash here would fail on healthy data.\n'
            } > "$manifest"

            while IFS=$'\t' read -r key value; do
              case "$key" in
                '#'*|"") continue ;;
              esac
              printf 'path\t%s\t-\n' "$value" >> "$manifest"
            done < "$DEST/paths.tsv"

            while IFS= read -r attr; do
              file="$(jq -r --arg a "$attr" '
                [ .systems[] | (.defaultCore, (.games[]?)) ] | map(select(.attr == $a)) | .[0].file
              ' "$spec")"
              printf 'core\t%s/%s\t%s\n' "$CORE_DIR" "$file" "$attr" >> "$manifest"
            done < <(jq -r '[ .systems[] | (.defaultCore, (.games[]?)) | .attr ] | unique | .[]' "$spec")

            total_roms=0
            thin_systems=""

            while IFS= read -r sysname; do
              dir="$(jq -r --arg s "$sysname" '.systems[$s].dir' "$spec")"
              whole="$(jq -r --arg s "$sysname" '.systems[$s].whole' "$spec")"
              srcdir="$ROMLIB/$dir"

              mapfile -t exts < <(jq -r --arg s "$sysname" '.systems[$s].romExtensions[]' "$spec")
              mapfile -t required < <(jq -r --arg s "$sysname" '.systems[$s].requiredStems[]' "$spec")
              mapfile -t excluded < <(jq -r --arg s "$sysname" '.systems[$s].excludeStems[]' "$spec")

              : > "$work/found"
              if [ -d "$srcdir" ]; then
                if ! ls -A "$srcdir" >/dev/null 2>&1; then
                  echo "Cannot read $srcdir -- see the group-membership fix above." >&2
                  exit 1
                fi
                while IFS= read -r -d "" file; do
                  base="''${file##*/}"
                  ext="''${base##*.}"
                  lext="$(printf '%s' "$ext" | tr '[:upper:]' '[:lower:]')"
                  for want in "''${exts[@]}"; do
                    if [ "$lext" = "$want" ]; then
                      printf '%s\t%s\n' "$base" "''${base%.*}" >> "$work/found"
                      break
                    fi
                  done
                done < <(find "$srcdir" -maxdepth 1 -type f -print0)
              fi
              LC_ALL=C sort -o "$work/found" "$work/found"

              : > "$work/rows"
              while IFS=$'\t' read -r base stem; do
                [ -n "$base" ] || continue

                skip=0
                for bad in "''${excluded[@]}"; do
                  if [ "$stem" = "$bad" ]; then
                    skip=1
                    break
                  fi
                done
                [ "$skip" -eq 0 ] || continue

                if [ "$whole" != "true" ]; then
                  wanted=0
                  for want in "''${required[@]}"; do
                    if [ "$stem" = "$want" ]; then
                      wanted=1
                      break
                    fi
                  done
                  [ "$wanted" -eq 1 ] || continue
                fi

                core_file="$(jq -r --arg s "$sysname" --arg g "$stem" '
                  .systems[$s].games[$g].file // .systems[$s].defaultCore.file' "$spec")"
                core_name="$(jq -r --arg s "$sysname" --arg g "$stem" '
                  .systems[$s].games[$g].name // .systems[$s].defaultCore.name' "$spec")"
                core_attr="$(jq -r --arg s "$sysname" --arg g "$stem" '
                  .systems[$s].games[$g].attr // .systems[$s].defaultCore.attr' "$spec")"

                printf '%s\t%s\t%s\t%s\n' \
                  "$base" "$stem" "$CORE_DIR/$core_file" "$core_name" >> "$work/rows"
                printf 'rom\t%s/%s/%s\t%s\n' \
                  "$ROMS_ROOT" "$dir" "$base" "$core_attr" >> "$manifest"
              done < "$work/found"

              # A named game that is not in the Library is a broken bundle, not
              # a thin one: the client carries that game and nothing else.
              missing=""
              for want in "''${required[@]}"; do
                if ! cut -f2 "$work/rows" | grep -qxF "$want"; then
                  missing="$missing  $sysname/$want"$'\n'
                fi
              done
              if [ -n "$missing" ]; then
                cat >&2 <<EOF
            $CLIENT includes games that are not in the Library:

            $missing
            Either the ROM is genuinely absent from $srcdir, or its filename no
            longer matches the content identity in
            modules/gaming/saves/policy.nix. Check the directory listing, then
            fix whichever side is wrong -- the identity string is also the save
            path, so renaming the ROM without renaming the identity forks the
            save history.
            EOF
                exit 1
              fi

              default_path="$CORE_DIR/$(jq -r --arg s "$sysname" '.systems[$s].defaultCore.file' "$spec")"
              default_name="$(jq -r --arg s "$sysname" '.systems[$s].defaultCore.name' "$spec")"

              jq -R -s \
                --arg romroot "$ROMS_ROOT/$dir" \
                --arg dbname "$dir.lpl" \
                --arg dcp "$default_path" \
                --arg dcn "$default_name" '
                split("\n") | map(select(length > 0) | split("\t")) |
                {
                  version: "1.5",
                  default_core_path: $dcp,
                  default_core_name: $dcn,
                  label_display_mode: 0,
                  right_thumbnail_mode: 0,
                  left_thumbnail_mode: 0,
                  thumbnail_match_mode: 0,
                  sort_mode: 0,
                  items: map({
                    path: ($romroot + "/" + .[0]),
                    label: .[1],
                    core_path: .[2],
                    core_name: .[3],
                    crc32: "00000000|crc",
                    db_name: $dbname
                  })
                }' < "$work/rows" > "$DEST/playlists/$dir.lpl"

              count="$(wc -l < "$work/rows")"
              total_roms=$(( total_roms + count ))
              printf 'playlist\t%s/%s.lpl\t-\n' "$(jq -r .playlistsRoot "$spec")" "$dir" >> "$manifest"
              printf '%-12s %5s entries -> playlists/%s.lpl\n' "$sysname" "$count" "$dir"

              if [ "$count" -eq 0 ]; then
                thin_systems="$thin_systems $sysname"
              fi
            done < <(jq -r '.systems | keys[]' "$spec")

            echo
            echo "Bundle: $DEST"
            echo "  client:    $CLIENT ($PLATFORM)"
            echo "  core dir:  $CORE_DIR"
            echo "  library:   $ROMLIB"
            echo "  ROM entries: $total_roms"

            if [ -n "$thin_systems" ]; then
              echo
              echo "EMPTY playlists for:$thin_systems"
              echo "  The Library directory is readable but holds no file with a"
              echo "  declared ROM extension. That is not necessarily wrong -- the"
              echo "  policy enables systems link already has cores for -- but a"
              echo "  bundle you are about to carry somewhere should not contain a"
              echo "  playlist with nothing in it. Check the Library first."
            fi

            cat <<EOF

            What to do next
              1. Read $DEST/README -- it is specific to $CLIENT.
              2. Copy $DEST to the device, minus this README if you like.
              3. Stage the credential separately, and only when you are at the
                 device:
                   nix run .#retroarch-credential-stage -- --client $CLIENT
              4. Walk $DEST/manifest.tsv on the device: every path must exist and
                 every playlist entry must show the core named beside it.
            EOF
          '';
        };

        retroarch-credential-stage = pkgs.writeShellApplication {
          name = "retroarch-credential-stage";
          meta.description = "Decrypt exactly one client's WebDAV credential into a marked file under XDG_RUNTIME_DIR";
          runtimeInputs = with pkgs; [
            coreutils
            gnugrep
          ];
          text = ''
            CLIENT=""
            SECRETS_REPO="''${SECRETS_REPO:-$HOME/Documents/Git/nix-secrets}"
            IDENTITY="$HOME/.ssh/agenix"
            AGE_FILE=""
            AGENIX="''${AGENIX:-agenix}"

            while [ $# -gt 0 ]; do
              case "$1" in
                --client) CLIENT="$2"; shift 2 ;;
                --secrets-repo) SECRETS_REPO="$2"; shift 2 ;;
                --identity) IDENTITY="$2"; shift 2 ;;
                --age-file) AGE_FILE="$2"; shift 2 ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-credential-stage --client NAME [--secrets-repo DIR] [--identity FILE] [--age-file PATH]

              Decrypts ONE client's WebDAV credential into a clearly marked file
              under $XDG_RUNTIME_DIR, mode 0600, and prints the path. Never
              prints the credential itself, and never writes it into the
              checkout or the Nix store.

              One credential per physical installation, so reinstalling,
              retiring or losing a device rotates that device's credential and
              touches no other client. The server holds only bcrypt hashes.

              Needs `agenix` on PATH (nix shell nixpkgs#agenix, or run this on a
              host that has it).
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ -z "$CLIENT" ]; then
              echo "--client is required. Declared clients: ${clientList}" >&2
              exit 2
            fi

            known=0
            for declared in ${clientList}; do
              if [ "$declared" = "$CLIENT" ]; then
                known=1
                break
              fi
            done
            if [ "$known" -eq 0 ]; then
              echo "unknown client: $CLIENT" >&2
              echo "Declared clients: ${clientList}" >&2
              echo "Add it to saveSync.clients in modules/gaming/saves/policy.nix first." >&2
              exit 2
            fi

            # games/, matching secrets.nix. link is deliberately NOT staged this
            # way even though the file name pattern would allow it: it is a
            # managed client, so its credential arrives through agenix at
            # activation (games/retroarch-webdav-{username,password}.age) and
            # never needs a decrypted copy on disk. Staging exists for the
            # devices that have to be typed into by hand.
            [ -n "$AGE_FILE" ] || AGE_FILE="games/retroarch-webdav-$CLIENT.age"

            runtime="''${XDG_RUNTIME_DIR:-}"
            if [ -z "$runtime" ] || [ ! -d "$runtime" ]; then
              cat >&2 <<'EOF'
            $XDG_RUNTIME_DIR is unset or missing.

            The staged credential must land on the per-user tmpfs, which is
            cleared at logout and never reaches disk. Run this from an
            interactive login session on the machine you are provisioning from,
            not from a bare systemd unit or an SSH session without a PAM
            session.
            EOF
              exit 1
            fi

            if [ ! -d "$SECRETS_REPO" ]; then
              cat >&2 <<EOF
            secrets repository not found: $SECRETS_REPO

            Clone it, or pass --secrets-repo. This tool decrypts from the repo
            rather than from /run/agenix on purpose: a client credential is only
            ever needed while you are provisioning a device, and there is no
            reason for link to hold a decrypted copy of it the rest of the time.
            EOF
              exit 1
            fi

            if [ ! -f "$SECRETS_REPO/$AGE_FILE" ]; then
              cat >&2 <<EOF
            no such secret: $SECRETS_REPO/$AGE_FILE

            Create it, with a credential you generate -- never one written down
            in this repository:

              cd $SECRETS_REPO
              # in secrets.nix:
              #   "$AGE_FILE".publicKeys = users;
              agenix -e $AGE_FILE -i $IDENTITY

            The plaintext is exactly two RetroArch configuration lines, and
            nothing else:

              webdav_username = "<a name unique to this installation>"
              webdav_password = "<a fresh random secret>"

            Then add that client's bcrypt hash to the authority's htpasswd
            (htpasswd -B from pkgs.apacheHttpd), push, and bump the secrets
            input. The server never sees the plaintext.
            EOF
              exit 1
            fi

            if [ ! -r "$IDENTITY" ]; then
              echo "cannot read the age identity: $IDENTITY" >&2
              echo "Pass --identity, or restore the key you decrypt this repo's secrets with." >&2
              exit 1
            fi

            staged="$(mktemp -p "$runtime" "STAGED-CREDENTIAL-$CLIENT-DELETE-ME-XXXXXX.cfg")"
            chmod 0600 "$staged"

            # onedrive-reauth shreds unconditionally on EXIT because its temp
            # file is an implementation detail. Here the file IS the deliverable,
            # so the trap shreds on every FAILURE path and stands down once the
            # credential has been validated -- otherwise this tool would delete
            # the thing it was asked to produce.
            KEEP=0
            cleanup() {
              if [ "$KEEP" -eq 0 ]; then
                shred -u "$staged" 2>/dev/null || rm -f "$staged"
              fi
            }
            trap cleanup EXIT

            if ! ( cd "$SECRETS_REPO" && "$AGENIX" -d "$AGE_FILE" -i "$IDENTITY" ) > "$staged"; then
              echo "decryption failed for $AGE_FILE" >&2
              echo "Check that $AGE_FILE has a rule in $SECRETS_REPO/secrets.nix and that" >&2
              echo "$IDENTITY is one of its recipients." >&2
              exit 1
            fi

            if [ ! -s "$staged" ]; then
              echo "decrypted $AGE_FILE to an empty file -- refusing to hand you nothing" >&2
              exit 1
            fi

            # Shape check by exact key name. It never echoes a value; it exists
            # so a credential pasted in the wrong format fails here rather than
            # on a handheld with no keyboard.
            if grep -qvE '^(webdav_username|webdav_password) = ".*"$|^$' "$staged"; then
              cat >&2 <<EOF
            $AGE_FILE is not in the expected shape.

            Expected exactly these two lines, verbatim, and nothing else:

              webdav_username = "..."
              webdav_password = "..."

            Re-encrypt it with:  cd $SECRETS_REPO && agenix -e $AGE_FILE -i $IDENTITY
            EOF
              exit 1
            fi
            for key in webdav_username webdav_password; do
              if ! grep -qE "^$key = \".*\"\$" "$staged"; then
                echo "$AGE_FILE is missing the $key line." >&2
                exit 1
              fi
            done

            KEEP=1
            cat <<EOF
            Staged one credential for $CLIENT:

              $staged   (mode 0600, on $runtime -- tmpfs, cleared at logout)

            It holds webdav_username and webdav_password and nothing else. It was
            not printed and must not be pasted into a terminal that is being
            logged or shared.

            Provisioning
              link / any managed client:  the managed configuration injects these
                two keys at runtime into a mode-0600 file outside the store; this
                staging copy is for reading them, not for installing.
              iOS:      type both values into
                          Settings -> Cloud Sync -> Username / Password.
                        A dropped file does not apply on iOS.
              RG Slide: type both values into the same menu, or replace those two
                        lines in the existing retroarch.cfg. Never replace the
                        whole file.

            When the device is provisioned, delete the staging copy:

              shred -u $staged

            Do not leave it for later. Nothing here removes it for you.
            EOF
          '';
        };

        retroarch-save-plan = pkgs.writeShellApplication {
          name = "retroarch-save-plan";
          meta.description = "Ordered save-migration plan with every precondition checked against the live host";
          runtimeInputs = with pkgs; [
            coreutils
            curl
            findutils
            gnugrep
            gnused
            procps
          ];
          text = ''
            SAVES="$HOME/.config/retroarch/saves"
            WORK=${defaultWorkRoot}
            LIBRARY="${defaultLibrary}"
            SYNCTHING_CONFIG="$HOME/.config/syncthing/config.xml"
            URL="${inventory.webdav.publicUrl}"
            CREDENTIAL=""

            while [ $# -gt 0 ]; do
              case "$1" in
                --saves) SAVES="$2"; shift 2 ;;
                --work) WORK="$2"; shift 2 ;;
                --library) LIBRARY="$2"; shift 2 ;;
                --url) URL="$2"; shift 2 ;;
                --credential-file) CREDENTIAL="$2"; shift 2 ;;
                --syncthing-config) SYNCTHING_CONFIG="$2"; shift 2 ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-save-plan [--saves DIR] [--work DIR] [--library DIR] [--url URL]
                                [--credential-file FILE] [--syncthing-config FILE]

              Prints the save migration in order and checks each step's
              precondition against this machine. Never writes anything.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            ok()   { printf '  [ ok ] %s\n' "$1"; }
            todo() { printf '  [ TODO ] %s\n' "$1"; }
            bad()  { printf '  [ BLOCKED ] %s\n' "$1"; }

            echo "Save migration plan"
            echo "==================="
            echo "  saves:     $SAVES"
            echo "  work:      $WORK"
            echo "  library:   $LIBRARY"
            echo "  authority: $URL"
            echo

            echo "1. Freeze writes to the save tree"
            if pgrep -x retroarch >/dev/null 2>&1; then
              bad "retroarch is running -- it rewrites saves on core unload and its config on exit"
              echo "         Quit it before anything else in this list."
            else
              ok "retroarch is not running"
            fi

            if [ -r "$SYNCTHING_CONFIG" ]; then
              if grep -qF 'path="~/.config/retroarch/saves"' "$SYNCTHING_CONFIG" \
                 || grep -qF "path=\"$SAVES\"" "$SYNCTHING_CONFIG"; then
                bad "a Syncthing folder still has $SAVES as its root"
                echo "         Verified live on link: folder id mujrf-sx6dp, label \"saves\","
                echo "         type=sendonly, fsWatcherEnabled=true. It is retired in intent"
                echo "         only. Pause or remove it at http://localhost:8384 before you"
                echo "         write anything into the save tree, or the migration's own"
                echo "         output propagates to every device it is shared with."
                echo "         modules/link/syncthing.nix deliberately does NOT delete it:"
                echo "         overrideFolders is off, so this is your call, not activation's."
              else
                ok "no Syncthing folder is rooted at the save tree"
              fi
            else
              todo "cannot read $SYNCTHING_CONFIG -- confirm no Syncthing folder covers $SAVES"
            fi

            echo
            echo "2. Archive and hash every existing save"
            latest=""
            if [ -d "$WORK/archive" ]; then
              latest="$(find "$WORK/archive" -maxdepth 1 -mindepth 1 -type d \
                | LC_ALL=C sort | tail -1)"
            fi
            if [ -n "$latest" ] && [ -s "$latest/sha256.tsv" ]; then
              ok "archive at $latest ($(grep -cv '^#' "$latest/sha256.tsv") files hashed)"
            else
              todo "run: nix run .#retroarch-save-archive -- --apply"
            fi

            echo
            echo "3. Choose ONE verified save per game"
            if [ -s "$WORK/seed-manifest.tsv" ]; then
              ok "seed tree at $WORK/seed ($(grep -cv '^#' "$WORK/seed-manifest.tsv") files)"
              if [ -s "$WORK/collisions.tsv" ]; then
                bad "$(cut -f1 "$WORK/collisions.tsv" | LC_ALL=C sort -u | wc -l) unresolved collisions"
                echo "         Cross-core duplicate stems -- including the pilot game itself."
                echo "         Open $WORK/collisions.tsv, pick a winner per row on mtime and"
                echo "         size, and rerun with --pick '<target>=<source>'."
              fi
            else
              todo "run: nix run .#retroarch-save-select -- --apply"
              echo "         Dry run first. Nothing is ever moved or deleted: it reads the"
              echo "         live tree and writes a new one."
            fi

            echo
            echo "4. Start with an EMPTY remote authority"
            if [ -z "$CREDENTIAL" ]; then
              todo "pass --credential-file to probe $URL"
              echo "         nix run .#retroarch-credential-stage -- --client link"
            elif [ ! -r "$CREDENTIAL" ]; then
              bad "cannot read $CREDENTIAL"
            else
              probe="$(mktemp)"
              trap 'rm -f "$probe"' EXIT
              {
                printf 'user = "%s:%s"\n' \
                  "$(sed -n 's/^webdav_username = "\(.*\)"$/\1/p' "$CREDENTIAL")" \
                  "$(sed -n 's/^webdav_password = "\(.*\)"$/\1/p' "$CREDENTIAL")"
              } > "$probe"
              chmod 0600 "$probe"
              code="$(curl -sS -o /dev/null -w '%{http_code}' -K "$probe" \
                -X PROPFIND -H 'Depth: 1' "''${URL%/}/saves/" || echo 000)"
              case "$code" in
                404) ok "no saves/ collection on the authority -- it is empty" ;;
                207) bad "saves/ already exists on the authority" ;;
                401|403) bad "the authority rejected this credential (HTTP $code)" ;;
                000) bad "could not reach $URL" ;;
                *) bad "unexpected HTTP $code from $URL" ;;
              esac
            fi

            echo
            echo "5. Seed from ONE client (link)"
            if [ -s "$WORK/seeded.tsv" ]; then
              ok "seeded $(grep -cv '^#' "$WORK/seeded.tsv") files, each read back and compared"
            else
              todo "run: nix run .#retroarch-save-seed -- --credential-file <staged> --apply"
            fi

            echo
            echo "6. Prove second-client retrieval"
            echo "     Manual, and the only step that proves the whole thing works:"
            echo "       a. Provision the second client from its bundle"
            echo "          (nix run .#retroarch-bundle-generate -- --client ios --core-dir ...)."
            echo "       b. Point it at $URL with its OWN credential."
            echo "       c. Launch RetroArch, then Cloud Sync -> Sync Now."
            echo "       d. Confirm the save arrived under that client's saves/<system>/."
            echo "       e. Load the game, unload the core, and confirm the change comes"
            echo "          back to link on its next sync."
            echo "     Triggers are startup, core UNLOAD, and Sync Now. There is no retry"
            echo "     on reconnect and no queue: a sync that failed did not happen."
            echo
            echo "Conflicts, when they happen: cloud_sync_destructive is false, so"
            echo "RetroArch touches NEITHER copy and logs \"Conflicting change of <file>.\""
            echo "There are no conflicted-copy filenames to look for. Look in the log, and"
            echo "in the client's core_assets_directory, under cloud_backups/, for the"
            echo "local copies RetroArch renamed rather than overwrote."
          '';
        };

        retroarch-save-archive = pkgs.writeShellApplication {
          name = "retroarch-save-archive";
          meta.description = "Archive and hash every file in the live RetroArch save tree before it is touched";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            gnugrep
            procps
          ];
          text = ''
            SAVES="$HOME/.config/retroarch/saves"
            WORK=${defaultWorkRoot}
            SYNCTHING_CONFIG="$HOME/.config/syncthing/config.xml"
            APPLY=0

            while [ $# -gt 0 ]; do
              case "$1" in
                --saves) SAVES="$2"; shift 2 ;;
                --work) WORK="$2"; shift 2 ;;
                --syncthing-config) SYNCTHING_CONFIG="$2"; shift 2 ;;
                --apply) APPLY=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-save-archive [--saves DIR] [--work DIR] [--apply]

              Copies the ENTIRE save tree -- including .stversions, conflict
              copies and anything unrecognised -- into a timestamped archive and
              writes a sha256 manifest of every file.

              Everything is archived, not just the files the migration will use:
              the point of this step is that the original state is recoverable
              afterwards, and a filter here would decide in advance what "the
              original state" was.

              Copies, never moves. Dry run by default.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            [ -d "$SAVES" ] || { echo "not a directory: $SAVES" >&2; exit 1; }

            case "$WORK/" in
              "$SAVES"/*)
                echo "--work ($WORK) is inside --saves ($SAVES)." >&2
                echo "The archive would archive itself. Pick a directory outside the save tree." >&2
                exit 1 ;;
            esac

            if pgrep -x retroarch >/dev/null 2>&1; then
              cat >&2 <<EOF
            retroarch is running.

            It rewrites save files on core unload, so an archive taken now is a
            snapshot of a moving tree. Quit RetroArch, then rerun.
            EOF
              exit 1
            fi

            if [ -r "$SYNCTHING_CONFIG" ] \
               && { grep -qF 'path="~/.config/retroarch/saves"' "$SYNCTHING_CONFIG" \
                    || grep -qF "path=\"$SAVES\"" "$SYNCTHING_CONFIG"; }; then
              cat >&2 <<EOF
            A Syncthing folder still has $SAVES as its root.

            On link that is folder id mujrf-sx6dp, label "saves", type=sendonly,
            file watcher on. Writes into the save tree propagate to every device
            it is shared with, which is precisely what "freeze writes" means to
            prevent.

            Pause or remove the folder in the Syncthing UI:

              http://localhost:8384

            then rerun. Pass --syncthing-config /dev/null only if you have
            confirmed by hand that nothing is watching the tree.
            EOF
              exit 1
            fi

            files="$(find "$SAVES" -type f | wc -l)"
            stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
            dest="$WORK/archive/$stamp"

            echo "save tree: $SAVES"
            echo "files:     $files"
            echo "archive:   $dest"

            if [ "$APPLY" -eq 0 ]; then
              echo
              echo "Dry run. Rerun with --apply to write the archive."
              exit 0
            fi

            mkdir -p "$dest/tree"
            cp -a "$SAVES/." "$dest/tree/"

            (
              cd "$dest/tree"
              find . -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum
            ) > "$dest/sha256.raw"

            {
              printf '# sha256\tbytes\tmtime\tpath (relative to %s)\n' "$SAVES"
              while IFS= read -r line; do
                sum="''${line%% *}"
                rel="''${line#*  }"
                printf '%s\t%s\t%s\t%s\n' \
                  "$sum" \
                  "$(stat -c '%s' "$dest/tree/$rel")" \
                  "$(date -u -r "$dest/tree/$rel" '+%Y-%m-%dT%H:%M:%SZ')" \
                  "$rel"
              done < "$dest/sha256.raw"
            } > "$dest/sha256.tsv"
            rm -f "$dest/sha256.raw"

            chmod -R a-w "$dest/tree"

            echo
            echo "Archived $(grep -cv '^#' "$dest/sha256.tsv") files."
            echo "The copy under $dest/tree is now read-only; $SAVES is untouched."
            echo
            echo "What to do next"
            echo "  nix run .#retroarch-save-select        # dry run: classify and map"
            echo "  nix run .#retroarch-save-select -- --apply"
          '';
        };

        retroarch-save-select = pkgs.writeShellApplication {
          name = "retroarch-save-select";
          meta.description = "Classify the live save tree and map core-name sorting onto content-directory sorting";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            gawk
            gnugrep
            gnused
          ];
          text = ''
            SAVES="$HOME/.config/retroarch/saves"
            LIBRARY="${defaultLibrary}"
            WORK=${defaultWorkRoot}
            APPLY=0
            LIST_ALL=0
            ONLY=""
            PICKS=""

            while [ $# -gt 0 ]; do
              case "$1" in
                --saves) SAVES="$2"; shift 2 ;;
                --library) LIBRARY="$2"; shift 2 ;;
                --work) WORK="$2"; shift 2 ;;
                --only) ONLY="$ONLY$2"$'\n'; shift 2 ;;
                --pick) PICKS="$PICKS$2"$'\n'; shift 2 ;;
                --list-all) LIST_ALL=1; shift ;;
                --apply) APPLY=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-save-select [--saves DIR] [--library DIR] [--work DIR]
                                  [--only SYSTEM/STEM]... [--pick TARGET=SOURCE]...
                                  [--list-all] [--apply]

              Reads the live save tree and writes a NEW one in the layout the
              authority expects. Nothing is moved and nothing is deleted.

              The live tree is CORE-NAME sorted (saves/<CoreDisplayName>/<stem>.<ext>)
              because sort_savefiles_enable was on. The target is
              CONTENT-DIRECTORY sorted (saves/<system>/<stem>.<ext>), because
              sort_savefiles_by_content_enable derives the directory from the
              ROM's immediate parent. The bridge between the two is the Library:
              a save's stem is matched against the ROM stems under
              <library>/roms/<system>/, and that system is the target directory.

              Every path in the tree is classified. Syncthing versioning
              archives, conflict copies, folder markers, save states, the stray
              save at the tree root and anything unrecognised are each counted
              and named -- none of them is silently included and none is silently
              dropped.

              Two saves that map to the same target are BOTH skipped and both
              reported with mtime and size. Cross-core duplicate stems exist in
              this tree, including the pilot game, and newest-wins would throw
              away a playthrough. Resolve one with:

                --pick 'gba/Pokemon - Emerald-R 260525.srm=/full/path/to/the/winner.srm'

              --only restricts the run to named content identities, which is how
              the pilot phase seeds one game rather than the whole tree.

              Dry run by default.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            [ -d "$SAVES" ] || { echo "not a directory: $SAVES" >&2; exit 1; }

            ROMLIB="$LIBRARY/roms"
            if [ ! -d "$ROMLIB" ] || ! ls -A "$ROMLIB" >/dev/null 2>&1; then
              cat >&2 <<EOF
            Cannot read $ROMLIB

            The save stem has to be matched against the Library's ROM stems --
            that match is the ONLY thing that says which system directory a save
            belongs in. Without it this tool would have to guess from the core
            name, which is exactly the mapping the policy removes.

            The Library is mode 0750 romm:romm and group membership is read at
            login. Cheapest first:

              sg romm -c 'retroarch-save-select ...'
              newgrp romm
              log out and back in

            Check with:  id -nG | tr ' ' '\n' | grep -x romm
            EOF
              exit 1
            fi

            case "$WORK/" in
              "$SAVES"/*)
                echo "--work ($WORK) is inside --saves ($SAVES)." >&2
                echo "The seed tree must not live inside the tree it is read from." >&2
                exit 1 ;;
            esac

            work="$(mktemp -d)"
            trap 'rm -rf "$work"' EXIT

            printf '%s\n' "${saveExtensionList}" > "$work/save-exts"
            printf '%s\n' "${stateExtensionList}" > "$work/state-exts"
            printf '%s\n' "${systemDirList}" > "$work/system-dirs"
            printf '%s\n' "${romExtensionList}" > "$work/rom-exts"
            printf '%s' "$PICKS" > "$work/picks"

            # --- Library index: stem -> system -----------------------------------
            : > "$work/library"
            while IFS=$'\t' read -r sysname dir; do
              [ -n "$sysname" ] || continue
              srcdir="$ROMLIB/$dir"
              [ -d "$srcdir" ] || continue
              if ! ls -A "$srcdir" >/dev/null 2>&1; then
                echo "Cannot read $srcdir -- see the group-membership fix above." >&2
                exit 1
              fi
              mapfile -t exts < <(awk -F'\t' -v s="$sysname" '$1 == s { print $2 }' "$work/rom-exts")
              while IFS= read -r -d "" file; do
                base="''${file##*/}"
                lext="$(printf '%s' "''${base##*.}" | tr '[:upper:]' '[:lower:]')"
                for want in "''${exts[@]}"; do
                  if [ "$lext" = "$want" ]; then
                    printf '%s\t%s\t%s\n' "''${base%.*}" "$sysname" "$dir" >> "$work/library"
                    break
                  fi
                done
              done < <(find "$srcdir" -maxdepth 1 -type f -print0)
            done < "$work/system-dirs"
            LC_ALL=C sort -u -o "$work/library" "$work/library"

            # A stem that exists under two systems cannot be mapped: the save
            # would have to go in two places, and picking one silently is how a
            # save lands where the client will never look for it.
            cut -f1 "$work/library" | LC_ALL=C uniq -d > "$work/ambiguous"

            # --- classify every path in the save tree ----------------------------
            matched_ext() {
              local base lower ext
              base="$1"
              lower="$(printf '%s' "$base" | tr '[:upper:]' '[:lower:]')"
              while IFS= read -r ext; do
                [ -n "$ext" ] || continue
                case "$lower" in
                  *".$ext") printf '%s' "$ext"; return 0 ;;
                esac
              done < "$2"
              return 1
            }

            : > "$work/classes"
            while IFS= read -r -d "" path; do
              rel="''${path#"$SAVES"/}"
              base="''${path##*/}"
              class=""

              case "/$rel" in
                */.stversions/*) class="syncthing-version-archive" ;;
              esac
              if [ -z "$class" ]; then
                case "$base" in
                  .stfolder|.stignore|.stversions) class="syncthing-marker" ;;
                  *.sync-conflict-*) class="syncthing-conflict-copy" ;;
                esac
              fi
              if [ -z "$class" ] && matched_ext "$base" "$work/state-exts" >/dev/null; then
                class="save-state"
              fi
              if [ -z "$class" ] && ext="$(matched_ext "$base" "$work/save-exts")"; then
                case "$rel" in
                  */*) class="candidate" ;;
                  *)   class="candidate-tree-root" ;;
                esac
              fi
              [ -n "$class" ] || class="unclassified"

              printf '%s\t%s\t%s\n' "$class" "''${ext:-}" "$rel" >> "$work/classes"
              ext=""
            done < <(find "$SAVES" -type f -print0)
            LC_ALL=C sort -o "$work/classes" "$work/classes"

            # --- map candidates to the content-directory layout -------------------
            : > "$work/planned"
            : > "$work/unmapped"
            : > "$work/ambiguous-hits"
            : > "$work/filtered"

            while IFS=$'\t' read -r class ext rel; do
              case "$class" in
                candidate|candidate-tree-root) ;;
                *) continue ;;
              esac
              base="''${rel##*/}"
              stem="''${base%.*}"

              if grep -qxF "$stem" "$work/ambiguous"; then
                printf '%s\t%s\n' "$stem" "$rel" >> "$work/ambiguous-hits"
                continue
              fi

              # Exact first-field match, never a substring: "Emerald" is a
              # suffix of "Pokemon Emerald", and a grep would map one game's
              # save onto another game's system directory.
              row="$(awk -F'\t' -v s="$stem" '$1 == s { print; exit }' "$work/library")"
              if [ -z "$row" ]; then
                printf '%s\t%s\n' "$stem" "$rel" >> "$work/unmapped"
                continue
              fi
              sysname="$(printf '%s\n' "$row" | cut -f2)"
              dir="$(printf '%s\n' "$row" | cut -f3)"

              if [ -n "$ONLY" ] && ! printf '%s' "$ONLY" | grep -qxF "$sysname/$stem"; then
                printf '%s\t%s\n' "$sysname/$stem" "$rel" >> "$work/filtered"
                continue
              fi

              printf '%s\t%s\n' "$dir/$base" "$SAVES/$rel" >> "$work/planned"
            done < "$work/classes"

            # --- collisions -------------------------------------------------------
            LC_ALL=C sort -o "$work/planned" "$work/planned"
            cut -f1 "$work/planned" | LC_ALL=C uniq -d > "$work/contested"

            : > "$work/collisions"
            : > "$work/resolved"
            while IFS= read -r target; do
              [ -n "$target" ] || continue

              # --pick 'TARGET=SOURCE'. Split on the FIRST "=" only: a source
              # path may legitimately contain one.
              winner="$(awk -v t="$target" '
                index($0, t "=") == 1 { print substr($0, length(t) + 2); exit }' "$work/picks")"

              if [ -n "$winner" ]; then
                if awk -F'\t' -v t="$target" -v w="$winner" '
                     $1 == t && $2 == w { found = 1 } END { exit !found }' "$work/planned"; then
                  printf '%s\t%s\n' "$target" "$winner" >> "$work/resolved"
                  continue
                fi
                echo "--pick names $winner for $target, but no save in the tree maps there." >&2
                echo "Copy the target and one of the sources verbatim out of the SKIPPED block." >&2
                exit 1
              fi

              awk -F'\t' -v t="$target" '$1 == t' "$work/planned" >> "$work/collisions"
            done < "$work/contested"

            # Drop every contested target -- including the first source that
            # claimed it -- then add back only the ones a human picked. Matched
            # on the first field alone: a substring match would also strike out
            # rows whose SOURCE path happens to contain a contested filename.
            awk -F'\t' 'NR == FNR { bad[$0] = 1; next } !($1 in bad)' \
              "$work/contested" "$work/planned" > "$work/planned.tmp"
            cat "$work/resolved" >> "$work/planned.tmp"
            mv "$work/planned.tmp" "$work/planned"
            LC_ALL=C sort -u -o "$work/planned" "$work/planned"

            # --- report -----------------------------------------------------------
            count_class() { grep -c "^$1"$'\t' "$work/classes" || true; }

            echo "Classification of $SAVES"
            echo "  candidates (in a core directory):   $(count_class candidate)"
            echo "  candidates at the tree root:        $(count_class candidate-tree-root)"
            echo "  save states (never migrated):       $(count_class save-state)"
            echo "  Syncthing version archive:          $(count_class syncthing-version-archive)"
            echo "  Syncthing conflict copies:          $(count_class syncthing-conflict-copy)"
            echo "  Syncthing markers:                  $(count_class syncthing-marker)"
            echo "  unclassified:                       $(count_class unclassified)"
            echo
            echo "  Save states are core- and build-specific and are deliberately left"
            echo "  behind: the authority carries them, but seeding them from a core the"
            echo "  policy has moved away from would seed something no client can load."

            if [ "$LIST_ALL" -eq 1 ]; then
              echo
              echo "Every classified path:"
              sed 's/^/  /' "$work/classes"
            fi

            for pair in \
              "syncthing-conflict-copy:Conflict copies -- a real second version of a save" \
              "unclassified:Unclassified -- neither a save, a state, nor Syncthing debris"; do
              class="''${pair%%:*}"
              title="''${pair#*:}"
              if [ "$(count_class "$class")" -gt 0 ]; then
                echo
                echo "$title:"
                grep "^$class"$'\t' "$work/classes" | cut -f3 | sed 's/^/  /'
              fi
            done

            if [ -s "$work/unmapped" ]; then
              echo
              echo "NO LIBRARY MATCH -- $(wc -l < "$work/unmapped") saves whose stem is not a ROM stem:"
              cut -f2 "$work/unmapped" | sed 's/^/  /'
              echo "  These are games that are not in the Library, or whose ROM was renamed"
              echo "  after the save was written. Neither is fixed by retrying: put the ROM"
              echo "  in the Library under the name the save uses, or rename the save."
            fi

            if [ -s "$work/ambiguous-hits" ]; then
              echo
              echo "AMBIGUOUS -- the stem exists under more than one system:"
              sed 's/^/  /' "$work/ambiguous-hits"
              echo "  Skipped. Remove the duplicate from the Library, or place the save by hand."
            fi

            if [ -s "$work/filtered" ]; then
              echo
              echo "Excluded by --only: $(wc -l < "$work/filtered") saves."
            fi

            if [ -s "$work/collisions" ]; then
              echo
              echo "SKIPPED -- $(cut -f1 "$work/collisions" | LC_ALL=C sort -u | wc -l) targets claimed by more than one save:"
              current=""
              while IFS=$'\t' read -r target src; do
                if [ "$target" != "$current" ]; then
                  printf '  %s\n' "$target"
                  current="$target"
                fi
                printf '      %s  %8s  %s\n' \
                  "$(date -r "$src" '+%Y-%m-%d %H:%M')" "$(stat -c '%s' "$src")" "$src"
              done < "$work/collisions"
              echo
              echo "  Both were kept and neither was chosen. Never newest-wins: the older"
              echo "  file is as likely to be the playthrough you care about, and one of"
              echo "  these pairs is the pilot game itself, written by both gpSP and mGBA."
              echo "  Open each under its core, confirm which save is the one you want, and"
              echo "  rerun with --pick '<target>=<source>'."
            fi

            echo
            echo "Selected: $(wc -l < "$work/planned") saves -> $WORK/seed/<system>/<stem>.<ext>"

            if [ "$APPLY" -eq 0 ]; then
              echo
              echo "Dry run. Rerun with --apply to write the seed tree."
              exit 0
            fi

            mkdir -p "$WORK/seed"
            cp -f "$work/collisions" "$WORK/collisions.tsv"
            {
              printf '# target\tsha256\tbytes\tsource\n'
              while IFS=$'\t' read -r target src; do
                case "$target" in
                  */*) mkdir -p "$WORK/seed/''${target%/*}" ;;
                  *) mkdir -p "$WORK/seed" ;;
                esac
                cp -n -- "$src" "$WORK/seed/$target"
                printf '%s\t%s\t%s\t%s\n' \
                  "$target" \
                  "$(sha256sum "$WORK/seed/$target" | cut -d' ' -f1)" \
                  "$(stat -c '%s' "$WORK/seed/$target")" \
                  "$src"
              done < "$work/planned"
            } > "$WORK/seed-manifest.tsv"

            echo
            echo "Wrote $WORK/seed. Every original under $SAVES is untouched."
            echo
            echo "What to do next"
            echo "  1. Resolve anything listed above as SKIPPED, AMBIGUOUS or NO LIBRARY"
            echo "     MATCH, then rerun. A save you leave unresolved is a save the"
            echo "     authority will never carry."
            echo "  2. Stage a credential:"
            echo "       nix run .#retroarch-credential-stage -- --client link"
            echo "  3. Seed the empty authority:"
            echo "       nix run .#retroarch-save-seed -- --credential-file <staged>"
          '';
        };

        retroarch-save-seed = pkgs.writeShellApplication {
          name = "retroarch-save-seed";
          meta.description = "Seed an empty WebDAV save authority from the selected tree and read every file back";
          runtimeInputs = with pkgs; [
            coreutils
            curl
            findutils
            gnugrep
            gnused
            jq
          ];
          text = ''
            WORK=${defaultWorkRoot}
            URL="${inventory.webdav.publicUrl}"
            CREDENTIAL=""
            APPLY=0

            while [ $# -gt 0 ]; do
              case "$1" in
                --work) WORK="$2"; shift 2 ;;
                --url) URL="$2"; shift 2 ;;
                --credential-file) CREDENTIAL="$2"; shift 2 ;;
                --apply) APPLY=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-save-seed --credential-file FILE [--work DIR] [--url URL] [--apply]

              Uploads the selected seed tree to an EMPTY save authority and reads
              every file back to prove it round-trips.

              Refuses if the authority already holds a saves/ collection. Starting
              from empty is what makes the first client sync a clean upload rather
              than a conflict: cloud_sync_destructive is false, so a server file
              that differs from the local one leaves RetroArch touching NEITHER
              copy and logging "Conflicting change of <file>." -- silent, and easy
              to mistake for "nothing to do".

              Dry run by default.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ -z "$CREDENTIAL" ] || [ ! -r "$CREDENTIAL" ]; then
              cat >&2 <<'EOF'
            --credential-file is required and must be readable.

            Stage one, on this machine, and delete it when you are done:

              nix run .#retroarch-credential-stage -- --client link
            EOF
              exit 1
            fi

            [ -d "$WORK/seed" ] || {
              echo "no seed tree at $WORK/seed" >&2
              echo "Run: nix run .#retroarch-save-select -- --apply" >&2
              exit 1
            }

            user="$(sed -n 's/^webdav_username = "\(.*\)"$/\1/p' "$CREDENTIAL")"
            pass="$(sed -n 's/^webdav_password = "\(.*\)"$/\1/p' "$CREDENTIAL")"
            if [ -z "$user" ] || [ -z "$pass" ]; then
              echo "$CREDENTIAL does not hold webdav_username and webdav_password." >&2
              exit 1
            fi

            # curl reads the credential from a mode-0600 config file rather than
            # argv: everything on a command line is readable in /proc by any
            # process on the box.
            curlrc="$(mktemp -p "''${XDG_RUNTIME_DIR:-/tmp}")"
            chmod 0600 "$curlrc"
            trap 'shred -u "$curlrc" 2>/dev/null || rm -f "$curlrc"' EXIT
            printf 'user = "%s:%s"\n' "$user" "$pass" > "$curlrc"

            base="''${URL%/}"
            dav() { curl -sS -K "$curlrc" "$@"; }
            status() { curl -sS -o /dev/null -w '%{http_code}' -K "$curlrc" "$@"; }

            # WebDAV paths are logical slash-separated paths, not URL strings.
            # Encode every segment separately so a space, reserved character or
            # UTF-8 filename is valid for curl while the separators that express
            # the remote hierarchy remain literal slashes.
            encode_path() { # <logical slash-separated path>
              local path="$1" segment encoded="" separator=""
              local IFS="/"
              local -a segments
              read -r -a segments <<< "$path"
              for segment in "''${segments[@]}"; do
                [ -n "$segment" ] || {
                  echo "refusing non-canonical remote path: $path" >&2
                  return 1
                }
                encoded="$encoded$separator$(printf '%s' "$segment" | jq -sRr @uri)"
                separator="/"
              done
              printf '%s' "$encoded"
            }
            remote_url() { printf '%s/%s' "$base" "$(encode_path "$1")"; }
            collection_url() { printf '%s/' "$(remote_url "$1")"; }

            root_code="$(status -X PROPFIND -H 'Depth: 0' "$base/" || echo 000)"
            case "$root_code" in
              207) ;;
              401|403)
                echo "the authority rejected this credential (HTTP $root_code)" >&2
                echo "Confirm this client's bcrypt entry is in the server's htpasswd." >&2
                exit 1 ;;
              000)
                echo "could not reach $base" >&2
                exit 1 ;;
              *)
                echo "unexpected HTTP $root_code from $base -- expected 207 to a PROPFIND" >&2
                exit 1 ;;
            esac

            saves_url="$(collection_url saves)"
            saves_code="$(status -X PROPFIND -H 'Depth: 1' "$saves_url" || echo 000)"
            if [ "$saves_code" = "207" ]; then
              cat >&2 <<EOF
            $base/saves/ already exists.

            This step requires an EMPTY authority. Whatever is up there was put
            there by a client or by an earlier run, and mixing it with a seed is
            how you get a conflict RetroArch resolves by touching nothing.

            Inspect it first:

              curl -K <your curl config> -X PROPFIND -H 'Depth: infinity' $base/saves/

            If it is genuinely disposable, delete it on the server -- from the
            server side, deliberately -- and rerun. Do not delete it from here.
            EOF
              exit 1
            fi

            mapfile -t files < <(cd "$WORK/seed" && find . -type f -printf '%P\n' | LC_ALL=C sort)
            if [ "''${#files[@]}" -eq 0 ]; then
              echo "seed tree at $WORK/seed is empty -- nothing to seed" >&2
              exit 1
            fi

            echo "authority: $base"
            echo "seed tree: $WORK/seed"
            echo "files:     ''${#files[@]}"
            echo

            if [ "$APPLY" -eq 0 ]; then
              for rel in "''${files[@]}"; do
                printf 'would PUT   saves/%s\n' "$rel"
              done
              echo
              echo "Dry run. Rerun with --apply to upload."
              exit 0
            fi

            # rclone's WebDAV server does not create parents implicitly, and MKCOL
            # on an existing collection answers 405 -- which is success here.
            mkcol() { status -X MKCOL "$(collection_url "$1")" >/dev/null || true; }
            mkcol saves
            for rel in "''${files[@]}"; do
              dirpart="''${rel%/*}"
              [ "$dirpart" = "$rel" ] || mkcol "saves/$dirpart"
            done

            # Not a pipeline: a failed PUT inside `{ ... } | tee` would exit a
            # subshell and the script would carry on reporting success.
            printf '# remote\tsha256\tbytes\n' > "$WORK/seeded.tsv"
            for rel in "''${files[@]}"; do
              src="$WORK/seed/$rel"
              remote="$(remote_url "saves/$rel")"
              printf 'PUT  saves/%s ... ' "$rel"
              code="$(status -T "$src" "$remote" || echo 000)"
              case "$code" in
                200|201|204) ;;
                *) echo "FAILED (HTTP $code)"; exit 1 ;;
              esac

              # Read back rather than trust the status code. rclone serves with
              # --vfs-cache-mode off by default, which streams straight to the
              # final name: a truncated write answers 201 and leaves a short
              # file behind.
              local_sum="$(sha256sum "$src" | cut -d' ' -f1)"
              remote_sum="$(dav "$remote" | sha256sum | cut -d' ' -f1)"
              if [ "$local_sum" != "$remote_sum" ]; then
                echo "FAILED (read-back mismatch)"
                echo "  local  $local_sum" >&2
                echo "  remote $remote_sum" >&2
                exit 1
              fi
              echo "ok"
              printf 'saves/%s\t%s\t%s\n' \
                "$rel" "$local_sum" "$(stat -c '%s' "$src")" >> "$WORK/seeded.tsv"
            done

            cat <<EOF

            Seeded ''${#files[@]} files and read every one of them back.

            What to do next
              1. On link, make the live save directory match this tree before
                 RetroArch syncs. The content-directory layout is saves/<system>/,
                 and the old core-name directories (mGBA/, gpSP/, ...) are still
                 sitting beside it -- Cloud Sync would upload those too, as a
                 second unrelated copy of every save. Nothing here moves them for
                 you; that cutover is yours to make deliberately.
              2. Start RetroArch on link and confirm the first sync reports no
                 conflict. Identical bytes on both sides is a no-op, which is the
                 whole reason the seed came from link's own files.
              3. Prove second-client retrieval:
                   nix run .#retroarch-save-plan
                 and follow step 6.
            EOF
          '';
        };
      };

      # Two layers, because they catch different things. The assertion refuses
      # at evaluation when the settings delta another module hands us names a
      # credential key -- that is the cheapest possible failure and it names the
      # client. The scan below then runs the SAME scanner the check set's
      # positive controls exercise over the bundle files as actually rendered,
      # which is what catches a credential that arrives through a path the
      # assertion does not model: a playlist entry, a README, a paths table, or
      # a spec.json field. A bundle is copied onto removable media and handed to
      # a device, so "secret-free" has to be a property of the bytes, not of the
      # inputs we happened to think of.
      checks.retroarch-save-bundles-secret-free =
        assert lib.assertMsg (leakingClients == [ ]) (
          lib.concatMapStringsSep "\n" (
            name:
            "flake.saveSyncClientSettings.${name} carries credential keys "
            + "(${lib.concatStringsSep ", " (leakedKeys name)}); bundles are copied onto removable media"
          ) leakingClients
        );
        pkgs.runCommand "retroarch-save-bundles-secret-free"
          {
            nativeBuildInputs = [ self'.packages.retroarch-saves-secret-scan ];
          }
          ''
            set -euo pipefail
            ${lib.concatStringsSep "\n" (
              lib.mapAttrsToList (name: client: ''
                echo "== bundle ${name} =="
                find ${staticBundle name client} -type f -print0 \
                  | xargs -0 retroarch-saves-secret-scan
              '') inventory.clients
            )}
            touch "$out"
          '';
    };
}
