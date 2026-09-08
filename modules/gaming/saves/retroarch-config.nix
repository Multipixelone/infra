# Declarative RetroArch configuration for the managed client, plus the settings
# delta the two unmanaged clients are held to by hand.
#
# Three traps shape everything below.
#
# The first is that RetroArch REWRITES its own configuration on exit. That is
# how the live file on link ended up pointing `libretro_directory` at a 1.20.0
# store path while the running binary was 1.22.2: nix wrote a path, RetroArch
# saved it back into a file nix does not own, and the two drifted for two
# releases without a single error. Nix therefore cannot "manage some keys" of a
# file RetroArch also writes. Either `config_save_on_exit = "false"` and nix is
# authoritative, or nix keeps its hands off. `savesLib.managedSettings` puts
# that key first for exactly this reason, and the price is real: from the
# moment `saveSync.retroarch.manageConfig` flips, every persistent UI change is
# a nix edit.
#
# The second is that the live configuration CONTAINS A CREDENTIAL. `cheevos_token`
# is a real 16-character RetroAchievements token sitting in the middle of 3333
# otherwise-boring lines, and `webdav_username` / `webdav_password` are about to
# join it. Anything rendered into the nix store is world-readable forever, so
# the store only ever holds a template that has been PROVEN secret-free (see
# `guardSecrets` -- it throws at evaluation, it does not warn), and the real
# mode-0600 file is composed at runtime by a systemd oneshot in the shape of
# rclone-seed in modules/backup/rclone.nix. The credential reaches that file
# through a bash builtin, so it is never an argv, never an environment file and
# never visible in /proc.
#
# The third is that a substring scan for password|token|key is WRONG on this
# file. It matches input_enable_hotkey, input_hotkey_block_delay,
# input_keyboard_layout, input_nowinkey_enable, keyboard_gamepad_enable,
# keyboard_gamepad_mapping_type, netplay_show_passworded, vibrate_on_keypress
# and three input_enable_hotkey_* variants -- eleven benign keys whose
# redaction would silently reset the operator's controller configuration. The
# exact `savesLib.secretKeys` list is the authority; the entropy heuristic in
# `retroarch-config-scan` is additive on top of it and never replaces it.
#
# ---------------------------------------------------------------------------
# CONTRACT: flake.saveSyncClientSettings
#
# Read by the client-bundle writer. Keyed by client name, exactly the names in
# `saveSync.clients`. Each entry is:
#
#   managed     :: bool          nix already owns this client's retroarch.cfg
#   platform    :: str           "linux" | "ios" | "android"
#   delivery    :: str           how `settings` reaches the device:
#                                  "nix"           -- already applied, ship nothing
#                                  "append-config" -- writable as a file passed to
#                                                     `retroarch --appendconfig`
#                                  "manual"        -- typed in on the device
#   settings    :: attrsOf str   the settings this client must END UP with. For
#                                unmanaged clients this is a FOCUSED DELTA --
#                                the Cloud Sync keys, the sort_save* keys and
#                                webdav_url -- and deliberately carries NO path,
#                                input, video, audio or menu settings, because
#                                those are device facts the bundle must not
#                                overwrite. For the managed client it is the full
#                                set nix owns, in the POLICY's path vocabulary
#                                (a leading `~` is expanded per host, not here).
#   rendered    :: str           `settings` in RetroArch's own `key = "value"`
#                                syntax, newline-terminated. Proven free of every
#                                key in savesLib.secretKeys.
#   manualKeys  :: listOf str    keys deliberately NOT in `settings`, which the
#                                operator types into the device by hand.
#   notes       :: listOf str    operator instructions, safe to reproduce verbatim.
#
# The bundle writer must not add credentials to `rendered`, and must not present
# `settings` as a replacement configuration for an unmanaged client.
# ---------------------------------------------------------------------------
{
  config,
  lib,
  inputs,
  withSystem,
  ...
}:
let
  inherit (lib) mkOption types;

  savesLib = import ../../../lib/retroarch-saves.nix { inherit lib; };
  inventory = config.flake.saveSyncInventory;
  cfg = config.saveSync.retroarch;
  owner = config.flake.meta.owner.username;

  # The six RetroArch keys a client profile's `paths` pins. Named here rather
  # than in the policy because they are RetroArch's vocabulary, not the sync
  # authority's: `rgui_config_directory` is the per-core override directory and
  # `core_assets_directory` is where Cloud Sync keeps manifest.local /
  # manifest.server and the cloud_backups/ tree, which is the single least
  # guessable fact in the recovery runbook.
  pathSettingsOf = paths: {
    savefile_directory = paths.saves;
    savestate_directory = paths.states;
    system_directory = paths.system;
    playlist_directory = paths.playlists;
    rgui_config_directory = paths.config;
    core_assets_directory = paths.coreAssets;
  };

  # The KEY NAMES managedSettings owns, independent of any value. Driven with
  # empty strings on purpose: the import tool has to drop these keys from what
  # it emits, and deriving the list from the renderer means a key added to
  # managedSettings is dropped from the import in the same edit. A
  # hand-maintained second list is how a managed key ends up pasted into
  # baseSettings and then silently overridden.
  managedKeys = lib.attrNames (
    savesLib.managedSettings {
      url = "";
      savePathsOf = pathSettingsOf (
        lib.genAttrs [
          "saves"
          "states"
          "system"
          "playlists"
          "config"
          "coreAssets"
        ] (_: "")
      );
    }
  );

  # Fails the build, never warns. A credential that reaches the store cannot be
  # recalled: the path stays readable by every user on the machine and by
  # anything that ever substituted it.
  guardSecrets =
    what: settings: text:
    let
      # Line-split rather than `lib.hasInfix`. hasInfix compiles `.*<key>.*` and
      # matches it against the WHOLE string, and once baseSettings holds the
      # imported 3300 settings that string is ~120 KB -- which overflows nix's
      # evaluation stack outright, turning a safety check into a build failure
      # with an unrelated message. Splitting is linear, and unlike an
      # attribute-name check it also catches a key smuggled in through a VALUE
      # that contains a newline.
      renderedKeys = lib.concatMap (
        line:
        let
          parts = lib.splitString " = " line;
        in
        lib.optional (builtins.length parts > 1) (builtins.head parts)
      ) (lib.splitString "\n" text);
      leaked = lib.filter (
        key: (settings ? ${key}) || builtins.elem key renderedKeys
      ) savesLib.secretKeys;
    in
    lib.throwIf (leaked != [ ]) ''
      retroarch: ${what} would render credential keys into the nix store:
        ${lib.concatStringsSep ", " leaked}

      Nothing in savesLib.secretKeys may ever appear in a store path. These keys
      almost certainly came from saveSync.retroarch.baseSettings; remove them
      there. retroarch-config-import drops them for you -- if they are present,
      the attrset was pasted from something other than its output.

      webdav_username and webdav_password are supplied at runtime by
      retroarch-config-seed.service, never here.
    '' text;

  renderSettings =
    what: settings: guardSecrets what settings (savesLib.renderRetroarchConfig settings);

  # The delta an UNMANAGED client is held to. `savePathsOf = { }` is the whole
  # point: iOS and Android have their own path vocabulary, their own input maps,
  # their own video drivers and their own menu state, and a bundle that shipped
  # a full configuration would replace all of it in order to change six Cloud
  # Sync keys.
  #
  # config_save_on_exit goes back to "true" here, overriding managedSettings. On
  # the managed client "false" is what stops RetroArch fighting nix for the
  # file. On an unmanaged client nix owns nothing, so "false" would instead
  # discard the WebDAV credentials the operator just typed into the menu the
  # moment the app is closed -- the exact opposite of the intent.
  unmanagedDelta =
    savesLib.managedSettings {
      url = inventory.webdav.publicUrl;
      savePathsOf = { };
    }
    // {
      config_save_on_exit = "true";
    };

  managedSettingsFor =
    client:
    savesLib.managedSettings {
      url = inventory.webdav.publicUrl;
      savePathsOf = pathSettingsOf client.paths;
    };

  deltaNotes = [
    "Apply this as a DELTA, key by key. Do NOT replace the device's retroarch.cfg: its input, video, audio, menu and path settings are device facts and are not represented here."
    "config_save_on_exit stays \"true\" on this client. Nix owns nothing here, and turning it off would discard the WebDAV credentials on the next app close."
    "webdav_username and webdav_password are entered BY HAND, once, under Settings -> Services -> Cloud Sync. Neither platform has a reliable credential-file importer: dropping a file next to retroarch.cfg does not apply it."
    "Verify with Settings -> Services -> Cloud Sync -> Sync Now, then confirm manifest.server appeared in this client's core_assets directory."
  ];

  clientSettings = lib.mapAttrs (
    name: client:
    let
      settings = if client.managed then managedSettingsFor client else unmanagedDelta;
    in
    {
      inherit (client) managed platform;
      inherit settings;
      rendered = renderSettings "the settings delta for client ${name}" settings;
      manualKeys = [
        "webdav_username"
        "webdav_password"
      ];
      delivery =
        if client.managed then
          "nix"
        else if client.platform == "android" then
          "append-config"
        else
          "manual";
      notes =
        if client.managed then
          [
            "Nix owns this client's retroarch.cfg. Ship nothing: retroarch-config-seed.service composes it from ${generatedPath} and the agenix WebDAV credentials."
            "Review the effect before flipping saveSync.retroarch.manageConfig with retroarch-config-diff."
          ]
        else if client.platform == "android" then
          [
            "If the RG Slide launcher passes command-line arguments through to RetroArch, ship `rendered` as a file and add `--appendconfig <path>`. Launch once and confirm the values under Settings before trusting it."
            "If it does not, merge these keys into the device's retroarch.cfg by hand, ONCE. Do not build a launcher and do not fork RetroArch for this."
            "Never put the credentials in an --appendconfig file: the launcher may back up or sync its own data directory."
          ]
          ++ deltaNotes
        else
          [
            "App Store RetroArch is sandboxed and has no command line, so there is no append-config path at all: every key below is entered through the menu."
          ]
          ++ deltaNotes;
    }
  ) inventory.clients;

  # Where the review artifact lives on the managed host. /etc rather than a bare
  # store path so the diff tool has one stable default to name in its refusal
  # message, and so `cat` shows the operator the same bytes the seed unit reads.
  generatedPath = "/etc/retroarch/retroarch.cfg.generated";

  # A policy path with a leading `~` turned into a shell expression. RetroArch
  # does accept `~` for these keys -- the live file uses it -- but it expands
  # against RetroArch's own notion of home at read time, which is not the same
  # thing under a systemd unit or a changed HOME. Expanding here and on the host
  # removes the question entirely, and the rendered file never carries a `~`.
  shellHomePath =
    path: if lib.hasPrefix "~/" path then ''"$HOME${lib.removePrefix "~" path}"'' else ''"${path}"'';

  secretKeysSpaced = lib.concatStringsSep " " savesLib.secretKeys;
  secretKeysLines = lib.concatStringsSep "\n" savesLib.secretKeys;
  managedKeysLines = lib.concatStringsSep "\n" managedKeys;

  # RetroArch's parser accepts exactly `key = "value"`, and the live 3333-line
  # file has zero exceptions. A line that does not match means the parse is
  # INCOMPLETE, and an incomplete parse that proceeds is how a setting silently
  # disappears from an imported attrset. Line numbers only -- the offending line
  # could be the one holding a credential.
  configLineRegex = "^[a-z0-9_]+ = \".*\"$";

  refuseUnparsable = ''
    bad=$(grep -cvE '${configLineRegex}' "$CONFIG" || true)
    if [ "$bad" -ne 0 ]; then
      {
        echo "$CONFIG has $bad line(s) that are not RetroArch's key = \"value\" form."
        echo
        echo "Line numbers (contents withheld -- one of them may hold a credential):"
        grep -nvE '${configLineRegex}' "$CONFIG" | cut -d: -f1 | paste -sd' ' -
        echo
        echo "Parsing it anyway would silently drop those settings. Fix or remove"
        echo "the lines, or point --config at a snapshot taken before the file was"
        echo "edited by hand:"
        echo "  retroarch-config-snapshot"
      } >&2
      exit 1
    fi
  '';

  # gawk fragment: split the current record into key/val.
  parseLine = ''
    eq = index($0, " = ")
    key = substr($0, 1, eq - 1)
    val = substr($0, eq + 4, length($0) - eq - 4)
  '';
in
{
  options.saveSync.retroarch = {
    injectCredentials = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether the agenix WebDAV credentials exist yet. Defaults off because an
        `age.secrets` entry whose `.age` file is absent from the secrets input
        BREAKS EVALUATION of every host, not just this one. The declaration it
        gates is otherwise complete: create `games/retroarch-webdav-username.age`
        and `games/retroarch-webdav-password.age` in the private secrets
        repository, bump the input, then flip this.
      '';
    };

    injectCheevos = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether to seed the RetroAchievements account password alongside the
        WebDAV credentials.

        This exists because making nix authoritative LOGS THE MACHINE OUT of
        RetroAchievements. The live configuration holds a real `cheevos_token`,
        which is a credential and therefore cannot be rendered into the store,
        and `cheevos_password` there is empty -- so once the token is dropped
        RetroArch has nothing left to authenticate with and cannot mint a new
        one. Seeding the password instead lets it log in on its own.

        Gated separately from `injectCredentials` so RetroAchievements is
        opt-in: a machine that does not use it should not carry the secret.
        Create `games/retroarch-cheevos-password.age`, bump the input, then flip
        this.
      '';
    };

    configFile = mkOption {
      type = types.str;
      default = "~/.config/retroarch/retroarch.cfg";
      description = ''
        The managed client's real configuration file. A leading `~` is expanded
        against the owner's home directory on the host and against `$HOME` in
        the operator tools; it is never written into the file itself, because
        RetroArch expands `~` for some path settings and not others.
      '';
    };

    verifiedVersion = mkOption {
      type = types.str;
      default = "1.22.2";
      description = ''
        The RetroArch version the Cloud Sync smoke test was last run against.
        RetroArch is a compatibility event on every update: `cloud_sync_sync_mode`
        only exists from 1.22.2, `cloud_sync_sync_systemfiles` never existed in
        any release, and `config_save_on_exit` quietly rewrote `libretro_directory`
        to a 1.20.0 store path while the binary was already 1.22.2. When the
        package moves past this version the build warns; the fix is to rerun the
        smoke test and then bump this, never to silence it.
      '';
    };
  };

  options.flake.saveSyncClientSettings = mkOption {
    type = types.raw;
    description = ''
      Per-client RetroArch settings, keyed by client name. See the CONTRACT
      block at the top of modules/gaming/saves/retroarch-config.nix.
    '';
  };

  config = {
    flake.saveSyncClientSettings = clientSettings;

    # The version gate lives with Cloud Sync rather than with the core list: it
    # is the sync contract that breaks across releases, not the emulators.
    flake.modules.homeManager.gaming =
      { pkgs, ... }:
      {
        warnings = lib.optional (pkgs.retroarch.version != cfg.verifiedVersion) ''
          RetroArch moved from ${cfg.verifiedVersion} to ${pkgs.retroarch.version}.

          Every upgrade is a Cloud Sync compatibility event -- keys have been
          added and removed across releases and the manifest format carries no
          stability promise. Before trusting saves again:

            1. Launch RetroArch, Settings -> Services -> Cloud Sync -> Sync Now.
            2. Confirm manifest.server and manifest.local both updated under the
               client's core_assets directory.
            3. Change a save on one client, sync both, confirm it travels. Then
               change BOTH copies and confirm the conflict is only logged
               ("Conflicting change of ...") and NEITHER copy is touched.
            4. Set saveSync.retroarch.verifiedVersion = "${pkgs.retroarch.version}".
        '';
      };

    # Deliberately perSystem rather than link-only. All four are pure functions
    # of a path: each takes --config, none reads a host fact, and as perSystem
    # packages they are `nix run .#<name>`-able from anywhere and each becomes a
    # shellcheck'd `packages/<name>` check via modules/package-checks.nix --
    # which is worth more than a hardcoded default, given that the thing being
    # parsed is the file holding the credentials. link puts them on PATH below.
    # The only host fact any of them carries is a DEFAULT, and every default is
    # refused loudly when the file behind it is absent.
    perSystem =
      { pkgs, ... }:
      let
        retroarch-config-snapshot = pkgs.writeShellApplication {
          name = "retroarch-config-snapshot";
          meta.description = "Copy the live RetroArch configuration to a timestamped mode-0600 work directory outside git and outside the nix store";
          runtimeInputs = with pkgs; [
            coreutils
            git
          ];
          text = ''
            CONFIG=${shellHomePath cfg.configFile}
            WORK="''${XDG_STATE_HOME:-$HOME/.local/state}/retroarch-config/snapshots"

            while [ $# -gt 0 ]; do
              case "$1" in
                --config) CONFIG="$2"; shift 2 ;;
                --work-dir) WORK="$2"; shift 2 ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-config-snapshot [--config PATH] [--work-dir DIR]

              Copies the live RetroArch configuration to WORK/<timestamp>/ at mode
              0600 under a 0700 directory, next to a MANIFEST recording the source,
              its mtime, its line count and its sha256.

              The original is never touched. The COPY holds every credential the
              original holds -- cheevos_token at minimum -- so this refuses to write
              into the nix store or into a git working tree.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ ! -r "$CONFIG" ]; then
              {
                echo "Cannot read the live RetroArch configuration at $CONFIG"
                echo
                echo "Pass --config PATH if it lives elsewhere. RetroArch writes the file"
                echo "on first launch; if it does not exist there is nothing to snapshot"
                echo "and nothing to import."
              } >&2
              exit 1
            fi

            case "$WORK" in
              /nix/store/*)
                {
                  echo "Refusing to snapshot into the nix store: $WORK"
                  echo
                  echo "The snapshot is a verbatim copy of a file containing credentials."
                  echo "Store paths are world-readable and cannot be recalled. Pass"
                  echo "--work-dir with a path under your home directory instead."
                } >&2
                exit 1 ;;
            esac

            # Walk to the nearest existing ancestor: WORK itself does not exist
            # yet on the first run, and `git -C` on a missing directory says
            # nothing useful.
            probe="$WORK"
            while [ ! -d "$probe" ] && [ "$probe" != "/" ]; do
              probe=$(dirname "$probe")
            done
            if git -C "$probe" rev-parse --show-toplevel >/dev/null 2>&1; then
              {
                echo "Refusing to snapshot into a git working tree: $WORK"
                echo
                echo "  repository: $(git -C "$probe" rev-parse --show-toplevel)"
                echo
                echo "That is one 'git add -A' away from committing cheevos_token."
                echo "Pass --work-dir with a path outside every repository:"
                echo "  retroarch-config-snapshot --work-dir \"\$HOME/.local/state/retroarch-config/snapshots\""
              } >&2
              exit 1
            fi

            umask 077
            dest="$WORK/$(date +%Y%m%d-%H%M%S)"
            mkdir -p "$dest"
            chmod 0700 "$WORK" "$dest"

            install -m 0600 "$CONFIG" "$dest/retroarch.cfg"
            {
              echo "source: $CONFIG"
              echo "taken:  $(date -Is)"
              echo "mtime:  $(date -Is -r "$CONFIG")"
              echo "lines:  $(wc -l < "$CONFIG")"
              echo "sha256: $(sha256sum < "$CONFIG" | cut -d' ' -f1)"
            } > "$dest/MANIFEST"
            chmod 0600 "$dest/MANIFEST"

            echo "$dest/retroarch.cfg"
            {
              echo
              echo "This copy holds every credential the live file holds. It is mode 0600"
              echo "under a 0700 directory. Do not move it into the repository."
            } >&2
          '';
        };

        retroarch-config-scan = pkgs.writeShellApplication {
          name = "retroarch-config-scan";
          meta.description = "Report which RetroArch settings hold credentials, by key name only, never printing a value";
          runtimeInputs = with pkgs; [
            coreutils
            gawk
            gnugrep
          ];
          text = ''
            CONFIG=${shellHomePath cfg.configFile}
            LIST=0
            # The exact list from lib/retroarch-saves.nix. A substring match on
            # password|token|key flags eleven benign input and netplay keys in
            # this very file, and redacting those would reset the operator's
            # controller configuration.
            KNOWN="${secretKeysSpaced}"

            while [ $# -gt 0 ]; do
              case "$1" in
                --config) CONFIG="$2"; shift 2 ;;
                --list) LIST=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-config-scan [--config PATH] [--list]

              Reports, BY KEY NAME ONLY, which settings hold a credential:

                exact    a key in lib/retroarch-saves.nix's secretKeys that is
                         present and non-empty
                entropy  any other key whose value looks like a token: at least 16
                         characters, at least 10 distinct ones, drawn only from
                         [A-Za-z0-9+/=_-], containing both a letter and a digit

              No value is ever printed, and neither is any value's length.

              --list prints just the flagged key names, one per line, which is what
              retroarch-config-import and retroarch-config-diff consume.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ ! -r "$CONFIG" ]; then
              echo "Cannot read $CONFIG -- pass --config PATH." >&2
              exit 1
            fi

            ${refuseUnparsable}

            findings=$(gawk -v known="$KNOWN" '
              BEGIN { n = split(known, k, " "); for (i = 1; i <= n; i++) knownset[k[i]] = 1 }
              {
                ${parseLine}
                if (key in knownset) { if (val != "") print "exact\t" key; next }
                if (length(val) < 16) next
                # Paths, URLs and shader references are long and varied but all
                # carry characters this charset excludes; the suffix guard below
                # covers the directory keys that would otherwise slip through.
                if (val !~ /^[A-Za-z0-9+\/=_-]+$/) next
                if (val !~ /[A-Za-z]/) next
                if (val !~ /[0-9]/) next
                if (key ~ /(_directory|_dir|_path|_url)$/) next
                delete seen
                d = 0
                m = split(val, ch, "")
                for (i = 1; i <= m; i++) if (!(ch[i] in seen)) { seen[ch[i]] = 1; d++ }
                if (d >= 10) print "entropy\t" key
              }
            ' "$CONFIG")

            if [ "$LIST" -eq 1 ]; then
              echo "$findings" | gawk -F'\t' 'NF == 2 { print $2 }' | sort -u
              exit 0
            fi

            exact=$(echo "$findings" | gawk -F'\t' '$1 == "exact" { print $2 }' | sort -u)
            entropy=$(echo "$findings" | gawk -F'\t' '$1 == "entropy" { print $2 }' | sort -u)

            # Key names only, one per line, indented. Never the value, and never
            # the value's length -- a reported length is a brute-force hint.
            report() {
              if [ -z "$1" ]; then
                echo "  (none)"
                return
              fi
              while IFS= read -r name; do
                echo "  $name"
              done <<< "$1"
            }

            echo "$CONFIG: $(wc -l < "$CONFIG") settings"
            echo
            echo "credential keys (exact list, lib/retroarch-saves.nix) present and NON-EMPTY:"
            report "$exact"
            echo
            echo "high-entropy values (heuristic, additive to the list above):"
            report "$entropy"
            echo
            echo "No values were printed. retroarch-config-import drops every key named"
            echo "above, so anything mis-flagged here has to be re-added to"
            echo "saveSync.retroarch.baseSettings by hand. Read the list before pasting."
          '';
        };

        retroarch-config-import = pkgs.writeShellApplication {
          name = "retroarch-config-import";
          meta.description = "Emit the live RetroArch settings as a secret-free Nix attrset for saveSync.retroarch.baseSettings";
          runtimeInputs = with pkgs; [
            coreutils
            gawk
            gnugrep
            retroarch-config-scan
          ];
          text = ''
            CONFIG=${shellHomePath cfg.configFile}

            while [ $# -gt 0 ]; do
              case "$1" in
                --config) CONFIG="$2"; shift 2 ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-config-import [--config PATH]

              Prints the live configuration as a Nix attrset to paste into
              saveSync.retroarch.baseSettings. The attrset goes to stdout and the
              notes to stderr, so

                retroarch-config-import > base-settings.nix

              leaves a clean fragment.

              Three classes of key are DROPPED and never emitted:
                * every key in lib/retroarch-saves.nix's secretKeys, INCLUDING the
                  ones that are currently empty -- an empty netplay_password in
                  baseSettings is a credential key in a store path waiting for
                  someone to fill it in, and the store guard rejects it on sight
                * everything retroarch-config-scan additionally flags, which is
                  the entropy heuristic
                * every key savesLib.managedSettings owns, because managed keys
                  override baseSettings anyway and pasting them in only creates a
                  second place to edit them
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ ! -r "$CONFIG" ]; then
              echo "Cannot read $CONFIG -- pass --config PATH." >&2
              exit 1
            fi

            ${refuseUnparsable}

            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT

            # Same scanner, same verdict: the tool that reports a credential and
            # the tool that refuses to emit it must never disagree, so import
            # calls scan instead of reimplementing it.
            retroarch-config-scan --config "$CONFIG" --list > "$work/flagged"
            # scan reports only what is present AND NON-EMPTY, which is the right
            # answer for a report and the wrong one for an emitter: the live file
            # carries eleven EMPTY credential keys, and every one of them would
            # land in a world-readable store path via baseSettings. The exact list
            # is dropped wholesale on top of the scan's verdict.
            printf '%s\n' "${secretKeysLines}" > "$work/secret"
            printf '%s\n' "${managedKeysLines}" > "$work/managed"
            cat "$work/flagged" "$work/secret" "$work/managed" | sed '/^$/d' | sort -u > "$work/drop"

            gawk '
              NR == FNR { drop[$0] = 1; next }
              {
                ${parseLine}
                if (key in drop) next
                print key "\t" val
              }
            ' "$work/drop" "$CONFIG" > "$work/pairs"

            # Nix double-quoted strings escape backslash, double quote and the
            # start of an interpolation. Done with bash parameter expansion so the
            # value is never handed to another process.
            while IFS=$'\t' read -r key val; do
              val=''${val//\\/\\\\}
              val=''${val//\"/\\\"}
              val=''${val//\$\{/\\\$\{}
              printf '  "%s" = "%s";\n' "$key" "$val"
            done < "$work/pairs" > "$work/body"

            total=$(wc -l < "$CONFIG")
            kept=$(wc -l < "$work/body")
            flagged=$(grep -c . "$work/flagged" || true)

            echo "saveSync.retroarch.baseSettings = {"
            echo "  # Generated by retroarch-config-import from $CONFIG"
            echo "  # $kept of $total settings; the rest are credentials or managed keys."
            cat "$work/body"
            echo "};"

            {
              echo
              echo "kept:    $kept"
              echo "dropped: $(( total - kept ))  credential keys (empty ones included)"
              echo "         and keys savesLib.managedSettings owns"
              if [ "$flagged" -gt 0 ]; then
                echo
                echo "$flagged of those held a live value (names only, never printed elsewhere):"
                sed 's/^/  /' "$work/flagged"
              fi
              echo
              echo "Next: paste the attrset into modules/gaming/saves/policy.nix, deploy,"
              echo "run retroarch-config-diff, and only then set"
              echo "saveSync.retroarch.manageConfig = true."
            } >&2
          '';
        };

        retroarch-config-diff = pkgs.writeShellApplication {
          name = "retroarch-config-diff";
          meta.description = "Diff the generated RetroArch configuration against the live one, key by key, without printing credential values";
          runtimeInputs = with pkgs; [
            coreutils
            gawk
            gnugrep
            retroarch-config-scan
          ];
          text = ''
            GENERATED="${generatedPath}"
            LIVE=${shellHomePath cfg.configFile}
            LIMIT=40

            while [ $# -gt 0 ]; do
              case "$1" in
                --generated) GENERATED="$2"; shift 2 ;;
                --live) LIVE="$2"; shift 2 ;;
                --all) LIMIT=0; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-config-diff [--generated PATH] [--live PATH] [--all]

              Key-by-key review of what flipping saveSync.retroarch.manageConfig
              would do to the live configuration:

                +  a key nix ADDS
                ~  a key whose value nix CHANGES
                -  a key nix DROPS -- the dangerous column. With an empty
                   baseSettings that is every hand-tuned setting on the machine.

              Values are shown except for the keys retroarch-config-scan flags,
              which print as <redacted>. The `-` list is capped; pass --all for it
              in full.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ ! -r "$GENERATED" ]; then
              {
                echo "No generated configuration at $GENERATED"
                echo
                echo "It is written by modules/gaming/saves/retroarch-config.nix on the"
                echo "managed client (link), and it is written there regardless of"
                echo "saveSync.retroarch.manageConfig precisely so this diff can be read"
                echo "BEFORE the flip. On another host, pass --generated with a copy."
              } >&2
              exit 1
            fi

            if [ ! -r "$LIVE" ]; then
              echo "Cannot read the live configuration at $LIVE -- pass --live PATH." >&2
              exit 1
            fi

            for CONFIG in "$GENERATED" "$LIVE"; do
              ${refuseUnparsable}
            done

            redact=$(retroarch-config-scan --config "$LIVE" --list | paste -sd' ' -)

            gawk -v redact="$redact" -v limit="$LIMIT" '
              function show(k, v) { return (k in secret) ? "<redacted>" : "\"" v "\"" }
              BEGIN { n = split(redact, r, " "); for (i = 1; i <= n; i++) secret[r[i]] = 1 }
              FNR == NR {
                ${parseLine}
                g[key] = val
                gk[++gn] = key
                next
              }
              {
                ${parseLine}
                l[key] = val
                lk[++ln] = key
              }
              END {
                for (i = 1; i <= gn; i++) {
                  key = gk[i]
                  if (!(key in l)) { printf "+ %s = %s\n", key, show(key, g[key]); added++ }
                  else if (l[key] != g[key]) {
                    printf "~ %s: %s -> %s\n", key, show(key, l[key]), show(key, g[key])
                    changed++
                  }
                }
                for (i = 1; i <= ln; i++) {
                  key = lk[i]
                  if (key in g) continue
                  removed++
                  if (key in secret) lost[++lostn] = key
                  if (limit == 0 || removed <= limit) printf "- %s = %s\n", key, show(key, l[key])
                }
                if (limit > 0 && removed > limit)
                  printf "- ... and %d more (pass --all)\n", removed - limit
                printf "\nadded %d   changed %d   dropped %d\n", added, changed, removed
                if (removed > 0) {
                  print ""
                  print "Every dropped key reverts to the RetroArch default the moment"
                  print "saveSync.retroarch.manageConfig is true. Run retroarch-config-import"
                  print "and paste its output into saveSync.retroarch.baseSettings first."
                }
                if (lostn > 0) {
                  print ""
                  printf "%d dropped key(s) currently hold a LIVE credential:\n", lostn
                  for (i = 1; i <= lostn; i++) print "  " lost[i]
                  print ""
                  print "webdav_username and webdav_password are re-supplied at runtime by"
                  print "retroarch-config-seed.service. Anything else in that list is simply"
                  print "gone after the flip -- cheevos_token in particular means being logged"
                  print "out of RetroAchievements, and cheevos_password is empty in this file,"
                  print "so RetroArch cannot log back in on its own. Log in again from the"
                  print "menu after the first managed launch, or add the value to agenix and"
                  print "extend retroarch-config-seed the way it already handles WebDAV."
                }
              }
            ' "$GENERATED" "$LIVE"
          '';
        };
      in
      {
        packages = {
          inherit
            retroarch-config-snapshot
            retroarch-config-scan
            retroarch-config-import
            retroarch-config-diff
            ;
        };
      };

    configurations.nixos.link.module =
      {
        config,
        pkgs,
        lib,
        ...
      }:
      let
        linkClient =
          inventory.clients.link or (throw ''
            retroarch: saveSync.clients.link is not declared, but
            modules/gaming/saves/retroarch-config.nix wires the managed client
            onto link. Declare it in modules/gaming/saves/policy.nix, or delete
            the link wiring here.
          '');

        home = config.users.users.${owner}.home;
        expandHome = path: if lib.hasPrefix "~/" path then home + lib.removePrefix "~" path else path;

        configFile = expandHome cfg.configFile;
        stateDir = "${home}/.local/state/retroarch-config";

        # baseSettings first, managed second: the managed keys are the contract
        # and must win. A managed key that also appears in baseSettings is
        # already dropped by retroarch-config-import, so this ordering is a
        # backstop rather than the mechanism.
        generatedText = renderSettings "link's generated retroarch.cfg" (
          cfg.baseSettings
          // savesLib.managedSettings {
            url = inventory.webdav.publicUrl;
            savePathsOf = pathSettingsOf (lib.mapAttrs (_: expandHome) linkClient.paths);
          }
        );

        retroarch-config-seed = pkgs.writeShellApplication {
          name = "retroarch-config-seed";
          meta.description = "Compose the real retroarch.cfg from the store template and the agenix WebDAV credentials, mode 0600 and outside the nix store";
          runtimeInputs = with pkgs; [ coreutils ];
          text = ''
            template="${generatedPath}"
            out="${configFile}"
            backups="${stateDir}/pre-nix"
            user_file="${config.age.secrets."games/retroarch-webdav-username".path}"
            pass_file="${config.age.secrets."games/retroarch-webdav-password".path}"
            cheevos_file="${
              if cfg.injectCheevos then config.age.secrets."games/retroarch-cheevos-password".path else ""
            }"

            for f in "$template" "$user_file" "$pass_file"; do
              if [ ! -r "$f" ]; then
                {
                  echo "retroarch-config-seed: cannot read $f"
                  echo
                  echo "The WebDAV credentials come from agenix. In the private secrets repo:"
                  echo "  agenix -e games/retroarch-webdav-username.age  # the rclone --htpasswd user"
                  echo "  agenix -e games/retroarch-webdav-password.age  # its plaintext password"
                  echo "one line each, then push, bump the input (just update), set"
                  echo "saveSync.retroarch.injectCredentials = true and redeploy."
                } >&2
                exit 1
              fi
            done

            user=$(tr -d '\r\n' < "$user_file")
            pass=$(tr -d '\r\n' < "$pass_file")

            if [ -z "$user" ] || [ -z "$pass" ]; then
              {
                echo "retroarch-config-seed: the decrypted username or password is empty."
                echo "Re-encrypt it with the value on one line and no trailing blank line."
              } >&2
              exit 1
            fi

            # RetroArch's parser reads a value as the text between the quotes and
            # has NO escape sequence. A credential containing a double quote or a
            # backslash is silently truncated, and Cloud Sync then fails
            # authentication with nothing in the log to explain why.
            case "$user$pass" in
              *'"'*|*\\*)
                {
                  echo "retroarch-config-seed: the WebDAV credential contains a double quote"
                  echo "or a backslash, and RetroArch's config format cannot represent either."
                  echo "Choose a credential without them and re-encrypt both .age files."
                } >&2
                exit 1 ;;
            esac

            umask 077
            mkdir -p "$(dirname "$out")" "$backups"

            # Same directory as the target, so the final rename(2) is atomic, and
            # created under umask 077 so the file is never world-readable -- not
            # even for the instant between creation and chmod.
            tmp=$(mktemp "$out.nix-seed.XXXXXXXX")
            trap 'rm -f "$tmp"' EXIT

            cat "$template" > "$tmp"
            # printf is a bash builtin, so the credential never becomes an argv and
            # never appears in /proc/*/cmdline. `sed -i "s/X/$pass/"` here would
            # publish it to every process on the machine for the life of the call.
            printf 'webdav_username = "%s"\n' "$user" >> "$tmp"
            printf 'webdav_password = "%s"\n' "$pass" >> "$tmp"

            # RetroAchievements, when enabled. The password rather than the
            # token: RetroArch exchanges it for a fresh cheevos_token on login
            # and writes that token back -- which it can only do because this
            # file is 0600 and outside the store. Without this the machine is
            # permanently logged out, because managedSettings drops the token
            # the live config carried and cheevos_password there is empty.
            if [ -n "$cheevos_file" ]; then
              if [ ! -r "$cheevos_file" ]; then
                {
                  echo "retroarch-config-seed: cannot read $cheevos_file"
                  echo "  agenix -e games/retroarch-cheevos-password.age"
                  echo "then push, bump the input, and redeploy. Or set"
                  echo "saveSync.retroarch.injectCheevos = false."
                } >&2
                exit 1
              fi
              cheevos=$(tr -d '\r\n' < "$cheevos_file")
              case "$cheevos" in
                *'"'*|*\\*)
                  {
                    echo "retroarch-config-seed: the RetroAchievements password contains a"
                    echo "double quote or a backslash, which RetroArch's config format cannot"
                    echo "represent. Change it on retroachievements.org and re-encrypt."
                  } >&2
                  exit 1 ;;
              esac
              if [ -n "$cheevos" ]; then
                printf 'cheevos_password = "%s"\n' "$cheevos" >> "$tmp"
              fi
            fi
            chmod 0600 "$tmp"

            if [ -e "$out" ] && cmp -s "$tmp" "$out"; then
              echo "retroarch.cfg already current"
              exit 0
            fi

            # Never destroy an original. Until baseSettings covers everything, the
            # live file is the only copy of the settings nix does not yet know
            # about, and the backup goes OUTSIDE RetroArch's config directory so
            # the program never reads it back in.
            if [ -e "$out" ]; then
              install -m 0600 "$out" "$backups/retroarch.cfg.$(date +%Y%m%d-%H%M%S)"
            fi

            mv -f "$tmp" "$out"
            trap - EXIT
            echo "wrote $out (0600); takes effect at RetroArch's next launch"
          '';
        };

        tool = name: withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.${name});
      in
      {
        assertions = [
          {
            assertion = linkClient.managed;
            message = ''
              saveSync.clients.link.managed is false, but link renders a full
              retroarch.cfg and runs retroarch-config-seed.service. An unmanaged
              client is held to the FOCUSED DELTA in
              flake.saveSyncClientSettings.link, not to a generated file. Either
              set managed = true in modules/gaming/saves/policy.nix, or delete
              the link wiring in modules/gaming/saves/retroarch-config.nix.
            '';
          }
          {
            # A password with no account name is not a login. `cheevos_username`
            # is NOT in savesLib.secretKeys -- it is an account name, not a
            # credential -- so it is never dropped and never seeded: it rides in
            # with the rest of the imported settings. That means the two halves
            # of one login arrive by two different routes, and nothing else
            # notices if only one of them shows up. RetroArch's failure here is
            # silent: it simply never authenticates, and achievements quietly
            # stop unlocking.
            assertion = !cfg.injectCheevos || (cfg.baseSettings.cheevos_username or "") != "";
            message = ''
              saveSync.retroarch.injectCheevos is true but
              saveSync.retroarch.baseSettings has no non-empty cheevos_username.

              The .age file holds only the RetroAchievements PASSWORD. The
              account name is not a secret and is carried in baseSettings --
              on link the live configuration already has

                cheevos_username = "tunnelmaker"

              so running retroarch-config-import and pasting its output into
              saveSync.retroarch.baseSettings supplies it. Do that, or set
              injectCheevos = false.
            '';
          }
          {
            assertion = !cfg.manageConfig || cfg.injectCredentials;
            message = ''
              saveSync.retroarch.manageConfig is true but
              saveSync.retroarch.injectCredentials is false.

              Nix would then own a retroarch.cfg that has cloud_sync_enable =
              "true" and no credentials at all: every sync attempt fails
              authentication against ${inventory.webdav.publicUrl}, and because
              RetroArch has no retry-on-reconnect and no durable queue, nothing
              ever retries it. Create games/retroarch-webdav-username.age and
              games/retroarch-webdav-password.age in the secrets repository,
              bump the input, and set injectCredentials = true first.
            '';
          }
        ];

        # Owned by the login user, not by root: the seed unit runs as the user
        # so it can write into their home, and nothing decrypts these on a
        # service's behalf. Same shape as romm-api-token in
        # modules/link/romm-migration.nix.
        # The optionalAttrs goes INSIDE the mkIf, not after it. `mkIf c {...}`
        # evaluates to `{ _type = "if"; condition = c; content = {...}; }`, so
        # `mkIf c {...} // optionalAttrs d {...}` grafts the second attrset onto
        # that wrapper as a sibling of `_type`/`condition`/`content`, where the
        # module system never looks at it. The secret is then silently absent:
        # evaluation succeeds, the unit is built, and the seed fails at runtime
        # reading a path agenix was never told to create.
        age.secrets = lib.mkIf cfg.injectCredentials (
          {
            "games/retroarch-webdav-username" = {
              file = "${inputs.secrets}/games/retroarch-webdav-username.age";
              mode = "400";
              inherit owner;
              group = "users";
            };
            "games/retroarch-webdav-password" = {
              file = "${inputs.secrets}/games/retroarch-webdav-password.age";
              mode = "400";
              inherit owner;
              group = "users";
            };
          }
          // lib.optionalAttrs cfg.injectCheevos {
            "games/retroarch-cheevos-password" = {
              file = "${inputs.secrets}/games/retroarch-cheevos-password.age";
              mode = "400";
              inherit owner;
              group = "users";
            };
          }
        );

        # Present whether or not manageConfig is on. It is not the config: it is
        # the REVIEW ARTIFACT, and the whole migration workflow depends on being
        # able to diff it against the live file before nix becomes authoritative.
        # Secret-free by construction -- guardSecrets throws otherwise -- which
        # is what makes it safe to leave world-readable in /etc.
        environment.etc."retroarch/retroarch.cfg.generated".text = generatedText;

        environment.systemPackages = map tool [
          "retroarch-config-snapshot"
          "retroarch-config-scan"
          "retroarch-config-import"
          "retroarch-config-diff"
        ];

        # Not a template rendered by home-manager: home-manager would install a
        # world-readable symlink into the store, and the file has to hold the
        # credentials at 0600. Ordered after agenix so the secrets exist, and
        # RemainAfterExit so a redeploy re-runs it (a changed template or a
        # rotated credential both land here).
        systemd.services.retroarch-config-seed = lib.mkIf (cfg.manageConfig && cfg.injectCredentials) {
          description = "Compose ${configFile} from the nix template and the agenix WebDAV credentials";
          wantedBy = [ "multi-user.target" ];
          after = [ "agenix.service" ];
          wants = [ "agenix.service" ];
          onFailure = [ "notify-telegram@%n.service" ];
          environment.HOME = home;
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            User = owner;
            Group = "users";
            UMask = "0077";
            ExecStart = lib.getExe retroarch-config-seed;
          };
        };
      };
  };
}
