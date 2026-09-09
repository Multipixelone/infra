# Pure projection of the Core policy and Client profiles onto the artifacts
# every sync client needs: Syncthing ignore patterns, RetroArch settings, and
# the derived save/state extension set.
#
# Pure on purpose, exactly like lib/service-publication.nix: it takes plain data
# and returns plain data, so `perSystem.checks.*` can drive it with synthetic
# fixtures without evaluating a NixOS system. Every rule that can fail is
# expressed as a string in `errors`; callers assert on that list rather than
# throwing from in here, which is what lets a check assert that a bad fixture
# produces a *specific* message.
{ lib }:
let
  inherit (lib)
    concatMap
    filter
    length
    optional
    ;

  # RetroArch writes save files next to the content directory name, never the
  # core name, once sort_savefiles_by_content_enable is on and
  # sort_savefiles_enable is off (runloop.c applies by-content first, then core
  # name). So the canonical system folder is the ONE identifier that has to
  # match byte-for-byte on every client: the Library's platform directory, the
  # client's ROM subdirectory, and the save subdirectory are all the same
  # string. Anything else silently splits one game's saves into two remote
  # paths, and Cloud Sync treats them as unrelated files rather than a conflict.
  contentIdentityOf = system: stem: "${system}/${stem}";

  systemOfIdentity =
    identity:
    let
      parts = lib.splitString "/" identity;
    in
    if length parts < 2 then null else builtins.head parts;

  # Save states are core- and build-specific, so their extensions come from
  # RetroArch itself rather than from any system: `.state`, `.state1`..`.stateN`
  # and the `.state.auto` written by savestate_auto_save. They are rejected from
  # the ROM channel alongside save files -- a state that reached a receive-only
  # ROM replica could be pushed back at the Library, and the Library is not
  # where progress lives.
  stateExtensions = [
    "state"
    "state.auto"
  ]
  ++ map (n: "state${toString n}") (lib.range 1 9);

  # Derived, never a hand-written literal: every system contributes the
  # extensions its emulated hardware actually writes, and the reject list is
  # their union plus the states above. Adding a system to the policy therefore
  # extends the ROM channel's rejection set in the same edit, which is the whole
  # point -- a hand-maintained second list is how `.dsv` gets forgotten.
  saveExtensionsOf =
    systems:
    lib.naturalSort (
      lib.unique (concatMap (system: system.saveExtensions) (builtins.attrValues systems))
    );

  rejectedExtensionsOf =
    systems: lib.naturalSort (lib.unique (saveExtensionsOf systems ++ stateExtensions));

  # Syncthing's ignore syntax gives `[`, `]`, `{`, `}`, `*`, `?` and `\` special
  # meaning and documents `\` as the escape. `(` `)` `!` `#` are special only at
  # the start of a line -- `!` negates, `#` introduces a directive, `(` opens a
  # `(?i)`/`(?d)` prefix -- and every pattern this module emits is either rooted
  # with `/` or prefixed with `(?i)`, so a leading literal can never be
  # misparsed. `#escape=\` is deliberately not emitted: it exists for Windows
  # receivers, and every declared client is Linux, Android or iOS.
  escapePattern =
    builtins.replaceStrings
      [
        "\\"
        "["
        "]"
        "{"
        "}"
        "*"
        "?"
      ]
      [
        "\\\\"
        "\\["
        "\\]"
        "\\{"
        "\\}"
        "\\*"
        "\\?"
      ];

  # Re-including a nested path means re-including every directory above it:
  # Syncthing decides a directory's fate by the first pattern that matches it,
  # and an ignored directory is never descended into, so `!/gba/Game.gba` alone
  # can never be reached. Deepest first, because a shallower `!/gba` placed
  # above would match `gba/Game.gba` first and re-include the whole system.
  parentReinclusions =
    path:
    let
      segments = lib.splitString "/" path;
      # Drop the leaf; keep every proper prefix, longest first.
      prefixes = map (n: lib.concatStringsSep "/" (lib.take n segments)) (
        lib.reverseList (lib.range 1 (length segments - 1))
      );
    in
    map (prefix: "!/${escapePattern prefix}") prefixes;

  # First match wins, so the file is a strict priority list and the order below
  # IS the semantics:
  #
  #   1. save/state extensions   nothing in this channel may carry progress,
  #                              not even a game that is otherwise included
  #   2. per-game exclusions     a named game beats its own system's include
  #   3. per-game inclusions     leaf first, then each parent directory
  #   4. whole-system inclusions contents then the directory itself
  #   5. `*`                     everything not named above is ignored
  #
  # Every negation is rooted, which the docs single out as the case that does
  # NOT force Syncthing to walk otherwise-ignored directories looking for a
  # match -- an unrooted `!Game.gba` would make every receiver scan the whole
  # Library on every rescan.
  renderStignore =
    {
      kind,
      systems,
      includeGames,
      excludeGames,
      rejectedExtensions,
    }:
    let
      header = [
        "// Generated by the Core policy -- do not edit."
        "// Receiver-local: Syncthing never syncs .stignore itself."
      ];
      rejects = map (ext: "(?i)*.${escapePattern ext}") rejectedExtensions;
      excludes = map (identity: "/${escapePattern identity}.*") (lib.naturalSort excludeGames);
      includes = concatMap (
        identity: [ "!/${escapePattern identity}.*" ] ++ parentReinclusions identity
      ) (lib.naturalSort includeGames);
      wholeSystems = concatMap (system: [
        "!/${escapePattern system}/**"
        "!/${escapePattern system}"
      ]) (lib.naturalSort systems);
    in
    lib.concatLines (
      header
      ++ lib.optional (kind == "roms") "// ROM channel: save and state extensions are rejected first."
      ++ rejects
      ++ excludes
      ++ includes
      ++ wholeSystems
      ++ [ "*" ]
    );

  # RetroArch parses `key = "value"` and nothing else; the live 3333-line file
  # on link has zero exceptions to that shape. Booleans are the literal strings
  # "true"/"false" and enums are decimal strings, so everything is rendered as
  # a quoted string and the option type is attrsOf str -- there is no second
  # representation to keep in sync.
  renderRetroarchConfig =
    settings:
    lib.concatLines (
      lib.mapAttrsToList (key: value: ''${key} = "${value}"'') (
        lib.filterAttrs (_: value: value != null) settings
      )
    );

  # The keys that carry a credential in RetroArch's own configuration, by exact
  # name. A substring match on password|token|key would be actively wrong here:
  # the live file also contains input_enable_hotkey, input_hotkey_block_delay,
  # input_keyboard_layout, keyboard_gamepad_enable, netplay_show_passworded and
  # vibrate_on_keypress, none of which are secrets, and redacting them would
  # silently reset the user's input configuration.
  secretKeys = [
    "access_key_id"
    "cheevos_password"
    "cheevos_token"
    "content_show_settings_password"
    "facebook_stream_key"
    "kiosk_mode_password"
    "netplay_password"
    "netplay_spectate_password"
    "secret_access_key"
    "twitch_stream_key"
    "webdav_password"
    "webdav_username"
    "youtube_stream_key"
  ];

  # Settings Nix owns unconditionally on every managed client. Rendered into the
  # store, so nothing here may ever hold a credential -- webdav_username and
  # webdav_password are deliberately absent and are injected at runtime into a
  # mode-0600 file outside the store.
  managedSettings =
    { url, savePathsOf }:
    {
      # RetroArch rewrites the whole config on exit, which is what left the live
      # file pointing libretro_directory at a 1.20.0 store path while the binary
      # was 1.22.2. Nix cannot own a file the program overwrites, so this goes
      # first: every persistent UI change from here on is a Nix edit.
      config_save_on_exit = "false";

      cloud_sync_enable = "true";
      cloud_sync_driver = "webdav";
      # 0 = CLOUD_SYNC_MODE_AUTOMATIC (configuration.h). 1.22.2 is the first
      # release with this key; on an older build it is ignored and automatic is
      # the only behaviour anyway.
      cloud_sync_sync_mode = "0";
      # Non-destructive: a server fetch that would overwrite a local file
      # renames the local copy into core_assets/cloud_backups/ instead of
      # discarding it. This is the setting that makes "conflicts preserve both
      # versions" true, and it must never be flipped.
      cloud_sync_destructive = "false";
      # One bool, two remote prefixes: task_cloud_sync_directory_map appends
      # both "saves" and "states" under this flag. There is no supported
      # battery-save-only toggle.
      cloud_sync_sync_saves = "true";
      # The config category would carry retroarch.cfg itself between clients,
      # which would both fight Nix's ownership here and move cheevos_token
      # off this machine.
      cloud_sync_sync_configs = "false";
      cloud_sync_sync_thumbs = "false";
      # NOT cloud_sync_sync_systemfiles -- that key does not exist in any
      # RetroArch release. BIOS reaches clients over the one-way Syncthing BIOS
      # dataset, never over the save authority.
      cloud_sync_sync_system = "false";

      webdav_url = url;

      # Core-name sorting off, content-directory sorting on. RetroArch applies
      # by-content first and core name second, so leaving both on would produce
      # saves/<system>/<CoreName>/ and reintroduce the core name into the remote
      # path -- and the core's *display* name is not stable across builds, so
      # two clients on different mGBA revisions would write to two paths.
      sort_savefiles_enable = "false";
      sort_savestates_enable = "false";
      sort_savefiles_by_content_enable = "true";
      sort_savestates_by_content_enable = "true";

      # Both off, unconditionally, and pinned even though "false" is already
      # RetroArch's default: the default is what a device drifts away from. On,
      # runloop_path_set_redirect swaps the save directory for the ROM's own
      # directory, while Cloud Sync keeps walking the CONFIGURED
      # savefile_directory -- so the client writes saves the authority never
      # sees and reads none of the ones it fetched, in both directions, while
      # looking perfectly healthy. Two clients did exactly this on 2026-09-07
      # and forked one game's save history four ways.
      savefiles_in_content_dir = "false";
      savestates_in_content_dir = "false";
    }
    // savePathsOf;

  # Validation. Every rule fails closed: a contradiction is an error string, and
  # the caller turns the list into an assertion or a failing check. Nothing here
  # warns, and nothing falls back to a default.
  validate =
    {
      systems,
      exceptions,
      clients,
      contentIdentities,
    }:
    let
      knownSystems = builtins.attrNames systems;
      knownIdentities = builtins.attrNames contentIdentities;

      isDetect = core: lib.toLower core == "detect";

      identityErrors =
        name: identity:
        let
          system = systemOfIdentity identity;
        in
        optional (system == null) "${name}: content identity ${identity} is not <system>/<stem>"
        ++ optional (
          system != null && !(builtins.elem system knownSystems)
        ) "${name}: content identity ${identity} names unknown system ${system}";

      systemErrors = concatMap (
        name:
        let
          system = systems.${name};
        in
        optional (isDetect system.core) "core policy: system ${name} uses DETECT; a prescribed core is never inferred"
        ++ optional (system.core == "") "core policy: system ${name} declares no core"
        ++
          optional (system.saveExtensions == [ ])
            "core policy: system ${name} declares no save extensions, so the ROM channel cannot reject its saves"
      ) knownSystems;

      exceptionErrors = concatMap (
        identity:
        let
          exception = exceptions.${identity};
        in
        optional (
          !(builtins.elem identity knownIdentities)
        ) "core policy: exception ${identity} names an unknown content identity"
        ++ identityErrors "core policy exception" identity
        ++ optional (isDetect exception.core) "core policy: exception ${identity} uses DETECT; a prescribed core is never inferred"
        ++ optional (exception.why == "") "core policy: exception ${identity} needs a justification"
      ) (builtins.attrNames exceptions);

      identityCatalogErrors = concatMap (
        identity: identityErrors "content identity" identity
      ) knownIdentities;

      clientErrors = concatMap (
        name:
        let
          client = clients.${name};
          enabled = client.systems;
          inSet = identity: builtins.elem (systemOfIdentity identity) enabled;
        in
        concatMap (
          system:
          optional (!(builtins.elem system knownSystems)) "client ${name}: selects unknown system ${system}"
        ) enabled
        ++ concatMap (
          identity:
          optional (
            !(builtins.elem identity knownIdentities)
          ) "client ${name}: per-game inclusion ${identity} names an unknown content identity"
          ++ identityErrors "client ${name} inclusion" identity
          ++ optional (inSet identity) "client ${name}: ${identity} is included individually but its system is already enabled"
          ++ optional (builtins.elem identity client.excludeGames) "client ${name}: ${identity} is both included and excluded"
        ) client.includeGames
        ++ concatMap (
          identity:
          optional (
            !(builtins.elem identity knownIdentities)
          ) "client ${name}: exclusion ${identity} names an unknown content identity"
          ++ identityErrors "client ${name} exclusion" identity
          ++ optional (
            !(inSet identity)
          ) "client ${name}: ${identity} is excluded from a system this client does not enable"
        ) client.excludeGames
      ) (builtins.attrNames clients);
    in
    systemErrors ++ exceptionErrors ++ identityCatalogErrors ++ clientErrors;

  # BIOS follows the games, not the whole-system selections: a client that
  # carries one GBA title through a per-game inclusion still needs the GBA BIOS,
  # and a client that enables no systems at all would otherwise receive an empty
  # BIOS projection and fail to boot the one game it was given.
  biosSystemsFor =
    client:
    lib.naturalSort (
      lib.unique (
        client.systems ++ filter (system: system != null) (map systemOfIdentity client.includeGames)
      )
    );

  # The core a client must have installed for one content identity: the
  # exception if there is one, otherwise the system default. Never DETECT, never
  # a fallback -- an identity whose system is unknown resolves to null, and the
  # caller has already failed validation by then.
  coreFor =
    {
      systems,
      exceptions,
      identity,
    }:
    let
      system = systemOfIdentity identity;
    in
    if exceptions ? ${identity} then
      exceptions.${identity}.core
    else if system != null && systems ? ${system} then
      systems.${system}.core
    else
      null;

  # Every core a client has to be able to load. Three contributions, and the
  # third is the one that is easy to miss: a client can carry a game WITHOUT
  # enabling its system, via a per-game inclusion, and it still needs that
  # game's core. Both pilot clients are exactly that shape -- systems = [ ],
  # includeGames = [ one GBA title ] -- so an implementation that only walked
  # `systems` and the exception table returned the empty list for them. An empty
  # required-core list on a handheld is the silent substitution this policy
  # exists to prevent: nothing fails, the game simply never loads.
  coresFor =
    {
      systems,
      exceptions,
      client,
    }:
    let
      carried = filter (
        identity:
        builtins.elem (systemOfIdentity identity) client.systems
        || builtins.elem identity client.includeGames
      ) (builtins.attrNames exceptions);
    in
    lib.naturalSort (
      lib.unique (
        map (system: systems.${system}.core) (filter (system: systems ? ${system}) client.systems)
        ++ map (identity: exceptions.${identity}.core) carried
        ++ filter (core: core != null) (
          map (identity: coreFor { inherit systems exceptions identity; }) client.includeGames
        )
      )
    );
in
{
  inherit
    biosSystemsFor
    contentIdentityOf
    coreFor
    coresFor
    escapePattern
    managedSettings
    parentReinclusions
    rejectedExtensionsOf
    renderRetroarchConfig
    renderStignore
    saveExtensionsOf
    secretKeys
    stateExtensions
    systemOfIdentity
    validate
    ;
}
