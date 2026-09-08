# Contract tests for the Core policy projection, driven by synthetic fixtures.
#
# The trap this file exists to avoid is that every failure mode in a save-sync
# fabric is SILENT. A .stignore whose negation is unrooted still syncs -- it
# just makes every receiver walk the whole Library on each rescan. A save
# extension rejected BELOW an inclusion still syncs -- it just carries a .srm
# into the ROM channel, where a receive-only replica can push it back at the
# Library. A rendered configuration that emits `cloud_sync_sync_systemfiles`
# is accepted without complaint, because RetroArch ignores keys it does not
# know, and the BIOS category is then simply never synced. None of those three
# produce an error at deploy time and the first symptom of all three is a lost
# save, months later, on a device nobody is looking at.
#
# So the assertions below are about ORDER, ROOTING and EXACT KEY NAMES, never
# about whether the generator ran. lib/retroarch-saves.nix is pure and returns
# `errors` as strings rather than throwing precisely so a fixture can prove a
# SPECIFIC message: a check that only asserted `errors != [ ]` would pass just
# as happily against a validator that rejected everything.
#
# Nothing here touches the real Library, the real save tree or a real
# credential. The WebDAV checks start an actual `rclone serve webdav` on
# loopback inside the build sandbox, against a temporary directory and an
# htpasswd file generated in the same build with an obviously-fake password --
# hermetic, no VM, no network, and it exercises the protocol rather than a
# model of it.
{ config, lib, ... }:
let
  savesLib = import ../../../lib/retroarch-saves.nix { inherit lib; };
  inventory = config.flake.saveSyncInventory;

  # ---------------------------------------------------------------------------
  # Synthetic fixtures. Deliberately NOT the real policy: a check driven by
  # policy.nix would start passing for the wrong reason the moment the policy
  # grew the case it was meant to catch.
  # ---------------------------------------------------------------------------
  fixtureSystems = {
    gba = {
      core = "mgba";
      libraryName = "mGBA";
      canonicalDir = "gba";
      romExtensions = [ "gba" ];
      saveExtensions = [
        "srm"
        "sav"
      ];
    };
    nds = {
      core = "melonds";
      libraryName = "melonDS DS";
      canonicalDir = "nds";
      romExtensions = [ "nds" ];
      saveExtensions = [
        "dsv"
        "sav"
        "srm"
      ];
    };
    n64 = {
      core = "mupen64plus";
      libraryName = "Mupen64Plus-Next";
      canonicalDir = "n64";
      romExtensions = [ "z64" ];
      saveExtensions = [
        "srm"
        "eep"
        "mpk"
      ];
    };
  };

  identity = why: {
    title = why;
    inherit why;
  };

  fixtureIdentities = {
    "gba/Alpha Quest" = identity "carried by the fixture pilot client";
    "gba/Beta Quest" = identity "excluded by the fixture whole-system client";
    "nds/Gamma Quest" = identity "carried individually from a disabled system";
    "n64/Delta Quest" = identity "excluded from an enabled system";
  };

  client =
    args:
    {
      platform = "linux";
      managed = false;
      systems = [ ];
      includeGames = [ ];
      excludeGames = [ ];
    }
    // args;

  validateWith =
    {
      systems ? fixtureSystems,
      exceptions ? { },
      clients ? { },
    }:
    savesLib.validate {
      inherit systems exceptions clients;
      contentIdentities = fixtureIdentities;
    };

  validateClients = clients: validateWith { inherit clients; };

  # ---------------------------------------------------------------------------
  # 1. Client-profile contradictions.
  # ---------------------------------------------------------------------------
  profileEvidence = {
    inventoryErrors = inventory.errors;
    pilot = {
      identity = inventory.pilot.emeraldContentIdentity;
      title = inventory.contentIdentities.${inventory.pilot.emeraldContentIdentity}.title;
      romFilename = "${lib.last (lib.splitString "/" inventory.pilot.emeraldContentIdentity)}.gba";
      ios = inventory.clients.ios.includeGames;
      rgSlide = inventory.clients.rg-slide.includeGames;
    };
    clean = validateClients {
      carry = client { includeGames = [ "nds/Gamma Quest" ]; };
      whole = client {
        systems = [ "gba" ];
        excludeGames = [ "gba/Beta Quest" ];
      };
    };
    bothWays = validateClients {
      pilot-both = client {
        includeGames = [ "gba/Alpha Quest" ];
        excludeGames = [ "gba/Alpha Quest" ];
      };
    };
    strayExclusion = validateClients {
      pilot-stray = client {
        systems = [ "nds" ];
        excludeGames = [ "gba/Beta Quest" ];
      };
    };
    unknownInclusion = validateClients {
      pilot-unknown = client { includeGames = [ "gba/Missing Quest" ]; };
    };
    redundantInclusion = validateClients {
      pilot-redundant = client {
        systems = [ "gba" ];
        includeGames = [ "gba/Alpha Quest" ];
      };
    };
    unknownSystem = validateClients {
      pilot-alien = client { systems = [ "dreamcast" ]; };
    };
    malformedIdentity = validateClients {
      pilot-flat = client { includeGames = [ "AlphaQuest" ]; };
    };
  };

  # `contains` over each error string, so the assertion pins the offending
  # PROFILE and the offending IDENTITY, not merely that something failed.
  profileFilter = ''
    (.inventoryErrors == [])
    and (.pilot.identity == "gba/Pokemon - Emerald-R 260525")
    and (.pilot.title == "Pokémon Revelation (v260525)")
    and (.pilot.romFilename == "Pokemon - Emerald-R 260525.gba")
    and (.pilot.ios == [.pilot.identity])
    and (.pilot.rgSlide == [.pilot.identity])
    and (.clean == [])
    and (.bothWays | any(contains("pilot-both") and contains("gba/Alpha Quest") and contains("both included and excluded")))
    and (.strayExclusion | any(contains("pilot-stray") and contains("gba/Beta Quest") and contains("excluded from a system this client does not enable")))
    and (.unknownInclusion | any(contains("pilot-unknown") and contains("gba/Missing Quest") and contains("per-game inclusion") and contains("unknown content identity")))
    and (.redundantInclusion | any(contains("pilot-redundant") and contains("gba/Alpha Quest") and contains("its system is already enabled")))
    and (.unknownSystem | any(contains("pilot-alien") and contains("selects unknown system dreamcast")))
    and (.malformedIdentity | any(contains("pilot-flat") and contains("AlphaQuest") and contains("is not <system>/<stem>")))
  '';

  # ---------------------------------------------------------------------------
  # 2. Core-policy exceptions, and DETECT rejected everywhere.
  # ---------------------------------------------------------------------------
  exceptionFixture = {
    "gba/Alpha Quest" = {
      core = "gpsp";
      why = "gpSP wrote this cartridge's existing battery save and is the only core proven to read it back";
    };
  };

  withGbaCore =
    core:
    fixtureSystems
    // {
      gba = fixtureSystems.gba // {
        inherit core;
      };
    };
  detectException = core: {
    "gba/Alpha Quest" = {
      inherit core;
      why = "fixture";
    };
  };

  corePolicyEvidence = {
    exceptionCore = savesLib.coreFor {
      systems = fixtureSystems;
      exceptions = exceptionFixture;
      identity = "gba/Alpha Quest";
    };
    defaultCore = savesLib.coreFor {
      systems = fixtureSystems;
      exceptions = exceptionFixture;
      identity = "gba/Beta Quest";
    };
    unknownSystemCore = savesLib.coreFor {
      systems = fixtureSystems;
      exceptions = { };
      identity = "dreamcast/Whatever";
    };
    acceptedException = validateWith { exceptions = exceptionFixture; };
    unknownException = validateWith {
      exceptions = {
        "gba/Missing Quest" = {
          core = "gpsp";
          why = "fixture";
        };
      };
    };
    unjustifiedException = validateWith {
      exceptions = {
        "gba/Alpha Quest" = {
          core = "gpsp";
          why = "";
        };
      };
    };
    detectSystemUpper = validateWith { systems = withGbaCore "DETECT"; };
    detectSystemLower = validateWith { systems = withGbaCore "detect"; };
    detectSystemMixed = validateWith { systems = withGbaCore "DeTeCt"; };
    detectExceptionUpper = validateWith { exceptions = detectException "DETECT"; };
    detectExceptionLower = validateWith { exceptions = detectException "detect"; };
    detectExceptionMixed = validateWith { exceptions = detectException "dEtEcT"; };
    emptyCore = validateWith { systems = withGbaCore ""; };
    coresWholeSystem = savesLib.coresFor {
      systems = fixtureSystems;
      exceptions = exceptionFixture;
      client = client { systems = [ "gba" ]; };
    };
    coresCarriedGame = savesLib.coresFor {
      systems = fixtureSystems;
      exceptions = exceptionFixture;
      client = client { includeGames = [ "gba/Alpha Quest" ]; };
    };
    coresUncarriedException = savesLib.coresFor {
      systems = fixtureSystems;
      exceptions = exceptionFixture;
      client = client { systems = [ "nds" ]; };
    };
    biosFollowsGames = savesLib.biosSystemsFor (client {
      systems = [ "n64" ];
      includeGames = [ "gba/Alpha Quest" ];
    });
  };

  corePolicyFilter = ''
    (.exceptionCore == "gpsp")
    and (.defaultCore == "mgba")
    and (.unknownSystemCore == null)
    and (.acceptedException == [])
    and (.unknownException | any(contains("exception gba/Missing Quest") and contains("unknown content identity")))
    and (.unjustifiedException | any(contains("exception gba/Alpha Quest") and contains("needs a justification")))
    and ([.detectSystemUpper, .detectSystemLower, .detectSystemMixed] | all(any(contains("system gba uses DETECT"))))
    and ([.detectExceptionUpper, .detectExceptionLower, .detectExceptionMixed] | all(any(contains("exception gba/Alpha Quest uses DETECT"))))
    and (.emptyCore | any(contains("system gba declares no core")))
    and (.coresWholeSystem == ["gpsp", "mgba"])
    and (.coresCarriedGame == ["gpsp"])
    and (.coresUncarriedException == ["melonds"])
    and (.biosFollowsGames == ["gba", "n64"])
  '';

  # ---------------------------------------------------------------------------
  # 3. .stignore generation, parent re-inclusions, and the load-bearing order.
  # ---------------------------------------------------------------------------
  rejectPair = [
    "srm"
    "state"
  ];

  stignoreCases = [
    {
      name = "whole-system";
      args = {
        kind = "roms";
        systems = [ "gba" ];
        includeGames = [ ];
        excludeGames = [ ];
        rejectedExtensions = rejectPair;
      };
      expected = ''
        // Generated by the Core policy -- do not edit.
        // Receiver-local: Syncthing never syncs .stignore itself.
        // ROM channel: save and state extensions are rejected first.
        (?i)*.srm
        (?i)*.state
        !/gba/**
        !/gba
        *
      '';
    }
    {
      name = "single-game-include";
      args = {
        kind = "roms";
        systems = [ ];
        includeGames = [ "gba/Alpha Quest" ];
        excludeGames = [ ];
        rejectedExtensions = rejectPair;
      };
      expected = ''
        // Generated by the Core policy -- do not edit.
        // Receiver-local: Syncthing never syncs .stignore itself.
        // ROM channel: save and state extensions are rejected first.
        (?i)*.srm
        (?i)*.state
        !/gba/Alpha Quest.*
        !/gba
        *
      '';
    }
    {
      name = "single-game-exclude";
      args = {
        kind = "roms";
        systems = [ "gba" ];
        includeGames = [ ];
        excludeGames = [ "gba/Beta Quest" ];
        rejectedExtensions = rejectPair;
      };
      expected = ''
        // Generated by the Core policy -- do not edit.
        // Receiver-local: Syncthing never syncs .stignore itself.
        // ROM channel: save and state extensions are rejected first.
        (?i)*.srm
        (?i)*.state
        /gba/Beta Quest.*
        !/gba/**
        !/gba
        *
      '';
    }
    {
      name = "deep-parent-reinclusions";
      args = {
        kind = "roms";
        systems = [ "n64" ];
        includeGames = [
          "gba/Alpha Quest"
          "nds/Region A/Sub B/Gamma Quest"
        ];
        excludeGames = [ ];
        rejectedExtensions = rejectPair;
      };
      expected = ''
        // Generated by the Core policy -- do not edit.
        // Receiver-local: Syncthing never syncs .stignore itself.
        // ROM channel: save and state extensions are rejected first.
        (?i)*.srm
        (?i)*.state
        !/gba/Alpha Quest.*
        !/gba
        !/nds/Region A/Sub B/Gamma Quest.*
        !/nds/Region A/Sub B
        !/nds/Region A
        !/nds
        !/n64/**
        !/n64
        *
      '';
    }
    {
      name = "bios-channel";
      args = {
        kind = "bios";
        systems = [
          "gba"
          "nds"
        ];
        includeGames = [ ];
        excludeGames = [ ];
        rejectedExtensions = rejectPair;
      };
      expected = ''
        // Generated by the Core policy -- do not edit.
        // Receiver-local: Syncthing never syncs .stignore itself.
        (?i)*.srm
        (?i)*.state
        !/gba/**
        !/gba
        !/nds/**
        !/nds
        *
      '';
    }
  ];

  linesOf = text: lib.filter (line: line != "") (lib.splitString "\n" text);

  indexOf =
    lines: needle:
    lib.findFirst (i: i != null) (-1) (lib.imap0 (i: line: if line == needle then i else null) lines);

  orderingRendered = savesLib.renderStignore {
    kind = "roms";
    systems = [ "n64" ];
    includeGames = [ "nds/Sub/Gamma Quest" ];
    excludeGames = [ "n64/Delta Quest" ];
    rejectedExtensions = rejectPair;
  };
  orderingLines = linesOf orderingRendered;
  orderingIndex = indexOf orderingLines;

  stignoreEvidence = {
    lines = orderingLines;
    rejectFirst = orderingIndex "(?i)*.srm";
    rejectSecond = orderingIndex "(?i)*.state";
    exclusion = orderingIndex "/n64/Delta Quest.*";
    includeLeaf = orderingIndex "!/nds/Sub/Gamma Quest.*";
    includeParentNear = orderingIndex "!/nds/Sub";
    includeParentFar = orderingIndex "!/nds";
    wholeSystemContents = orderingIndex "!/n64/**";
    wholeSystemDirectory = orderingIndex "!/n64";
    catchAll = orderingIndex "*";
    lineCount = lib.length orderingLines;
    unrootedNegations = lib.filter (
      line: lib.hasPrefix "!" line && !(lib.hasPrefix "!/" line)
    ) orderingLines;
    deepParents = savesLib.parentReinclusions "nds/Region A/Sub B/Deep C/Game";
    shallowParents = savesLib.parentReinclusions "gba/Game";
  };

  stignoreFilter = ''
    (.rejectFirst == 3)
    and (.rejectFirst < .rejectSecond)
    and (.rejectSecond < .exclusion)
    and (.exclusion < .includeLeaf)
    and (.includeLeaf < .includeParentNear)
    and (.includeParentNear < .includeParentFar)
    and (.includeParentFar < .wholeSystemContents)
    and (.wholeSystemContents < .wholeSystemDirectory)
    and (.wholeSystemDirectory < .catchAll)
    and (.catchAll == (.lineCount - 1))
    and (.unrootedNegations == [])
    and (.deepParents == ["!/nds/Region A/Sub B/Deep C", "!/nds/Region A/Sub B", "!/nds/Region A", "!/nds"])
    and (.shallowParents == ["!/gba"])
  '';

  # ---------------------------------------------------------------------------
  # 4. Special characters and nested paths.
  #
  # The stems are the ones actually present on this machine's Library and save
  # tree, which is why they are better fixtures than invented ones: they are
  # the exact shapes that will reach a receiver.
  # ---------------------------------------------------------------------------
  awkwardIdentities = [
    "gba/WarioWare, Inc. Mega Microgame$!"
    "nds/Homebrew [unsorted]/Rhythm Heaven Silver (Japan) [T-En by ShaffySwitcher Beta 14] [n]"
    "gba/Mario & Luigi Superstar Saga"
    "snes/Super Mario World 2 Yoshi's Island"
    "gba/Pokémon Emerald Version 2"
    "gba/pokémon emerald version 2"
    "n64/Sets/Test {alt} *star* who?.v1"
    "n64/Back\\slash Quest"
  ];

  escapedAwkward = map savesLib.escapePattern awkwardIdentities;

  awkwardRendered = savesLib.renderStignore {
    kind = "roms";
    systems = [ ];
    includeGames = awkwardIdentities;
    excludeGames = [ ];
    rejectedExtensions = [ "srm" ];
  };
  awkwardLines = linesOf awkwardRendered;

  countOf = needle: haystack: (lib.length (lib.splitString needle haystack)) - 1;

  # Every syntactically special character must appear only in its escaped form.
  # Counting `[` against `\[` is the direct test for "this pattern is not a
  # character range": a bare `[` would make Syncthing read the bracket group as
  # a class and silently stop matching the file it names.
  specialsBalanced = lib.all (
    pattern:
    lib.all (special: countOf special pattern == countOf ("\\" + special) pattern) [
      "["
      "]"
      "{"
      "}"
      "*"
      "?"
    ]
  ) escapedAwkward;

  # `(` `)` `!` `#` `&` `$` `'` `,` are special only at the START of a line,
  # and every pattern emitted is rooted with `/` or prefixed with `(?i)`, so
  # escaping them would corrupt the filename instead of protecting it.
  benignLeaks =
    lib.concatMap (special: lib.filter (pattern: countOf ("\\" + special) pattern > 0) escapedAwkward)
      [
        "("
        ")"
        "!"
        "#"
        "&"
        "$"
        "'"
        ","
      ];

  rhythmIdentity = "nds/Homebrew [unsorted]/Rhythm Heaven Silver (Japan) [T-En by ShaffySwitcher Beta 14] [n]";

  escapingEvidence = {
    bracketsEscaped = savesLib.escapePattern "a[b]c" == "a\\[b\\]c";
    bracesEscaped = savesLib.escapePattern "a{b}c" == "a\\{b\\}c";
    starEscaped = savesLib.escapePattern "a*c" == "a\\*c";
    questionEscaped = savesLib.escapePattern "a?c" == "a\\?c";
    backslashEscaped = savesLib.escapePattern "a\\c" == "a\\\\c";
    benignUntouched = savesLib.escapePattern "(!#&$',) x" == "(!#&$',) x";
    inherit specialsBalanced benignLeaks;
    everyIdentityRendered = lib.all (
      id: lib.elem ("!/" + savesLib.escapePattern id + ".*") awkwardLines
    ) awkwardIdentities;
    everyNegationRooted = lib.all (
      line: !(lib.hasPrefix "!" line) || lib.hasPrefix "!/" line
    ) awkwardLines;
    # Nested depth: the bracketed intermediate directory has to be re-included
    # in its own escaped form or Syncthing never descends into it.
    nestedParents = savesLib.parentReinclusions rhythmIdentity;
    rhythmLeaf = "!/" + savesLib.escapePattern rhythmIdentity + ".*";
    rhythmLeafPresent = lib.elem ("!/" + savesLib.escapePattern rhythmIdentity + ".*") awkwardLines;
    unicodePreserved = lib.elem "!/gba/Pokémon Emerald Version 2.*" awkwardLines;
    # Case is NOT folded for content: two case variants must stay two patterns,
    # because a case-insensitive receiver that collapsed them would sync one
    # game's ROM under the other game's save directory.
    caseVariantsDistinct =
      lib.elem "!/gba/Pokémon Emerald Version 2.*" awkwardLines
      && lib.elem "!/gba/pokémon emerald version 2.*" awkwardLines;
    # Extensions, by contrast, ARE case-insensitive: `.SRM` off a Windows tool
    # must be rejected by the same rule as `.srm`.
    extensionRejectIsCaseInsensitive = lib.elem "(?i)*.srm" awkwardLines;
  };

  escapingFilter = ''
    (.bracketsEscaped and .bracesEscaped and .starEscaped and .questionEscaped and .backslashEscaped)
    and .benignUntouched
    and .specialsBalanced
    and (.benignLeaks == [])
    and .everyIdentityRendered
    and .everyNegationRooted
    and .rhythmLeafPresent
    and .unicodePreserved
    and .caseVariantsDistinct
    and .extensionRejectIsCaseInsensitive
    and (.nestedParents == ["!/nds/Homebrew \\[unsorted\\]", "!/nds"])
  '';

  # ---------------------------------------------------------------------------
  # 5. Save and state exclusion from the ROM and BIOS channels.
  # ---------------------------------------------------------------------------
  derivedSaveExtensions = savesLib.saveExtensionsOf fixtureSystems;
  derivedRejects = savesLib.rejectedExtensionsOf fixtureSystems;

  # Derived from the fixture, never restated: this is the whole point of
  # rejectedExtensionsOf, and a hardcoded expectation here would be exactly the
  # hand-maintained second list the library exists to abolish.
  expectedSaveExtensions = lib.naturalSort (
    lib.unique (lib.concatMap (system: system.saveExtensions) (builtins.attrValues fixtureSystems))
  );
  expectedRejects = lib.naturalSort (lib.unique (expectedSaveExtensions ++ savesLib.stateExtensions));

  extendedRejects = savesLib.rejectedExtensionsOf (
    fixtureSystems
    // {
      dc = {
        core = "flycast";
        libraryName = "Flycast";
        canonicalDir = "dc";
        romExtensions = [ "gdi" ];
        saveExtensions = [ "vmu" ];
      };
    }
  );

  romChannelLines = linesOf (
    savesLib.renderStignore {
      kind = "roms";
      systems = [ "gba" ];
      includeGames = [ "nds/Sub/Gamma Quest" ];
      excludeGames = [ "gba/Beta Quest" ];
      rejectedExtensions = derivedRejects;
    }
  );
  biosChannelLines = linesOf (
    savesLib.renderStignore {
      kind = "bios";
      systems = [
        "gba"
        "nds"
      ];
      includeGames = [ ];
      excludeGames = [ ];
      rejectedExtensions = derivedRejects;
    }
  );

  rejectLineFor = ext: "(?i)*." + ext;
  # `//` opens a comment in Syncthing's ignore syntax, so a leading `/` alone
  # does not make a line a pattern -- the header comments would otherwise count
  # as the first exclusion and the ordering assertion would pass vacuously.
  isPatternLine =
    line: lib.hasPrefix "!" line || (lib.hasPrefix "/" line && !(lib.hasPrefix "//" line));

  channelEvidence =
    lines:
    let
      rejectIndices = map (ext: indexOf lines (rejectLineFor ext)) derivedRejects;
      patternIndices = lib.imap0 (i: line: if isPatternLine line then i else null) lines;
      firstPattern = lib.findFirst (i: i != null) (lib.length lines) patternIndices;
    in
    {
      missing = lib.filter (ext: !(lib.elem (rejectLineFor ext) lines)) derivedRejects;
      lastReject = lib.foldl' (a: b: if b > a then b else a) (-1) rejectIndices;
      inherit firstPattern;
    };

  rejectEvidence = {
    derived = derivedRejects;
    expected = expectedRejects;
    saveExtensions = derivedSaveExtensions;
    inherit expectedSaveExtensions;
    stateExtensions = lib.naturalSort savesLib.stateExtensions;
    expectedStateExtensions = lib.naturalSort (
      [
        "state"
        "state.auto"
      ]
      ++ map (n: "state${toString n}") (lib.range 1 9)
    );
    statesCovered = lib.all (ext: lib.elem ext derivedRejects) savesLib.stateExtensions;
    roms = channelEvidence romChannelLines;
    bios = channelEvidence biosChannelLines;
    newSystemExtendsRejects = lib.elem "vmu" extendedRejects;
    newSystemKeepsOldRejects = lib.all (ext: lib.elem ext extendedRejects) derivedRejects;
    noSaveExtensions = validateWith {
      systems = fixtureSystems // {
        gba = fixtureSystems.gba // {
          saveExtensions = [ ];
        };
      };
    };
  };

  rejectFilter = ''
    (.derived == .expected)
    and (.saveExtensions == .expectedSaveExtensions)
    and (.stateExtensions == .expectedStateExtensions)
    and .statesCovered
    and (.roms.missing == [])
    and (.bios.missing == [])
    and (.roms.lastReject >= 0)
    and (.roms.lastReject < .roms.firstPattern)
    and (.bios.lastReject >= 0)
    and (.bios.lastReject < .bios.firstPattern)
    and .newSystemExtendsRejects
    and .newSystemKeepsOldRejects
    and (.noSaveExtensions | any(contains("system gba declares no save extensions")))
  '';

  # ---------------------------------------------------------------------------
  # 6. Secret-free public artifacts.
  # ---------------------------------------------------------------------------
  fixtureSavePaths = {
    savefile_directory = "/home/fixture/.config/retroarch/saves";
    savestate_directory = "/home/fixture/.config/retroarch/states";
  };

  managedRendered = savesLib.renderRetroarchConfig (
    savesLib.managedSettings {
      url = inventory.webdav.publicUrl;
      savePathsOf = fixtureSavePaths;
    }
  );

  # The shape of the operator-facing validation report: what a client profile
  # resolves to, with no credential anywhere in it by construction.
  validationReport = {
    schemaVersion = 1;
    containsSecrets = false;
    inherit (inventory)
      requiredCores
      rejectedExtensions
      saveExtensions
      stateExtensions
      ;
    webdavUrl = inventory.webdav.publicUrl;
    clients = lib.mapAttrs (_: profile: {
      inherit (profile)
        platform
        managed
        systems
        includeGames
        excludeGames
        paths
        ;
      biosSystems = savesLib.biosSystemsFor profile;
      cores = savesLib.coresFor {
        inherit (inventory) systems exceptions;
        client = profile;
      };
    }) inventory.clients;
  };

  # ---------------------------------------------------------------------------
  # 7. Generated RetroArch settings.
  # ---------------------------------------------------------------------------
  expectedManagedLines = [
    ''config_save_on_exit = "false"''
    ''cloud_sync_enable = "true"''
    ''cloud_sync_destructive = "false"''
    ''cloud_sync_sync_saves = "true"''
    ''cloud_sync_sync_configs = "false"''
    ''cloud_sync_sync_thumbs = "false"''
    ''cloud_sync_sync_system = "false"''
    ''cloud_sync_driver = "webdav"''
    ''cloud_sync_sync_mode = "0"''
    ''sort_savefiles_enable = "false"''
    ''sort_savestates_enable = "false"''
    ''sort_savefiles_by_content_enable = "true"''
    ''sort_savestates_by_content_enable = "true"''
    ''webdav_url = "${inventory.webdav.publicUrl}"''
  ];

  # `cloud_sync_sync_systemfiles` is not a RetroArch key. Emitting it would be
  # accepted and ignored, and the BIOS category would never sync -- a silent
  # no-op is worse than a build failure, so it is a hard absence here.
  forbiddenManagedTokens = [ "cloud_sync_sync_systemfiles" ] ++ savesLib.secretKeys;
in
{
  perSystem =
    { pkgs, ... }:
    let
      jqContract =
        name: evidence: filter:
        pkgs.runCommand name
          {
            nativeBuildInputs = [ pkgs.jq ];
            evidenceJson = builtins.toJSON evidence;
          }
          ''
            set -euo pipefail
            printf '%s\n' "$evidenceJson" > evidence.json
            if ! jq -e ${lib.escapeShellArg filter} evidence.json > /dev/null; then
              echo "FAIL: ${name}: the projection no longer satisfies its contract." >&2
              echo "FIX: read the evidence below against lib/retroarch-saves.nix; every rule here" >&2
              echo "     is a save-loss mode, not a style preference." >&2
              jq . evidence.json >&2
              exit 1
            fi
            touch "$out"
          '';

      # Registered as a local package rather than a tracked shell script:
      # writeShellApplication shellchecks it at build time and inherits
      # `set -euo pipefail`.
      secretScanner = pkgs.writeShellApplication {
        name = "retroarch-saves-secret-scan";
        meta.description = "Refuses a generated save-sync artifact that names a credential-bearing RetroArch key, carries a non-empty webdav_password, or contains a high-entropy token.";
        runtimeInputs = with pkgs; [
          coreutils
          gnugrep
        ];
        text = ''
          # The EXACT key list from lib/retroarch-saves.nix. A substring match on
          # password|token|key would be actively wrong: the live configuration on
          # link has eleven benign keys that such a regex hits, and redacting
          # input_enable_hotkey would silently reset the user's controls.
          secret_keys=(${lib.concatStringsSep " " savesLib.secretKeys})
          status=0

          for file in "$@"; do
            for key in "''${secret_keys[@]}"; do
              # Anchored on the ASSIGNMENT, not the bare name. A generated
              # bundle has to be able to say, in prose, "webdav_username and
              # webdav_password are entered by hand under Settings -> Services
              # -> Cloud Sync" -- that instruction is the whole reason the
              # credential stays manual on iOS, and a scanner that forbade
              # naming the key would make the correct artifact unshippable while
              # catching nothing: a leak is a VALUE, and a value arrives through
              # an assignment.
              #
              # Deliberately still fires on an assignment with an EMPTY value.
              # `webdav_password = ""` in a world-readable store path is a
              # credential-shaped slot one edit away from being filled, and the
              # import tool drops those keys precisely so this never appears.
              # A commented-out assignment is caught too: `# key = "..."` still
              # matches, because a secret does not stop being a secret when
              # someone puts a hash in front of it.
              if grep -qE "(^|[^A-Za-z0-9_])''${key}[[:space:]]*=" "$file"; then
                echo "LEAK: $file assigns the credential-bearing key ''${key}" >&2
                status=1
              fi
            done

            if grep -qE 'webdav_password[[:space:]"]*[:=][[:space:]]*"[^"]+"' "$file"; then
              echo "LEAK: $file carries a non-empty webdav_password" >&2
              status=1
            fi

            # Entropy heuristic, deliberately narrow: long, mixed-case,
            # digit-bearing, high-alphabet tokens. Store paths and content
            # identities split on / and . and never reach this shape.
            while read -r token; do
              [ -n "$token" ] || continue
              distinct=$(printf '%s' "$token" | fold -w1 | sort -u | tr -d '\n' | wc -c)
              if [ "$distinct" -ge 12 ] \
                && printf '%s' "$token" | grep -q '[0-9]' \
                && printf '%s' "$token" | grep -q '[a-z]' \
                && printf '%s' "$token" | grep -q '[A-Z]'; then
                echo "LEAK: $file carries a high-entropy token of $distinct distinct characters" >&2
                status=1
              fi
            done < <({ grep -oE '[A-Za-z0-9+=_-]{20,}' "$file" || true; } | sort -u)
          done

          if [ "$status" -ne 0 ]; then
            echo "FIX: regenerate the artifact from lib/retroarch-saves.nix managedSettings, which" >&2
            echo "     emits no credential at all, and inject webdav_username/webdav_password at" >&2
            echo "     runtime into a mode-0600 file outside the nix store." >&2
          fi
          exit "$status"
        '';
      };

      managedConfigFile = pkgs.writeText "retroarch-managed.cfg" managedRendered;
      inventoryFile = pkgs.writeText "save-sync-inventory.json" (builtins.toJSON inventory);
      reportFile = pkgs.writeText "save-sync-report.json" (builtins.toJSON validationReport);
      stignoreFiles = lib.concatLists (
        lib.mapAttrsToList (name: channels: [
          (pkgs.writeText "stignore-${name}-roms" channels.roms)
          (pkgs.writeText "stignore-${name}-bios" channels.bios)
        ]) inventory.stignore
      );

      # Positive controls. Every planted value is an obviously-fake repeated
      # character or a literally "Fake"-prefixed string -- never anything that
      # resembles a credential.
      poisonSecretKey = pkgs.writeText "poisoned-cheevos.cfg" ''
        cloud_sync_enable = "true"
        cheevos_token = "AAAAAAAAAAAAAAAA"
      '';
      poisonWebdavPassword = pkgs.writeText "poisoned-webdav.cfg" ''
        webdav_url = "https://saves.example.invalid/"
        webdav_password = "BBBBBBBBBBBBBBBB"
      '';
      poisonEntropy = pkgs.writeText "poisoned-report.json" ''
        {"note": "planted control value, not a credential", "value": "FakeSecretFake0123456789AbCdEfGh"}
      '';

      # Negative control, and it earns its place: the first version of the
      # assignment rule matched the bare key name, and it red-flagged the iOS
      # bundle's own instruction to type the credentials in by hand. That
      # instruction is correct and load-bearing -- App Store RetroArch has no
      # credential-file importer -- so a rule that forbids naming the key
      # forbids the right artifact. This fixture fails the check if anyone
      # tightens the rule back.
      cleanProseMention = pkgs.writeText "clean-prose.cfg" ''
        # webdav_username and webdav_password are entered BY HAND, once, under
        # Settings -> Services -> Cloud Sync. Neither platform has a reliable
        # credential-file importer.
        #   webdav_username, webdav_password
        cloud_sync_enable = "true"
        webdav_url = "https://saves.example.invalid/"
      '';

      expectedLinesFile = pkgs.writeText "retroarch-expected-lines" (
        lib.concatLines expectedManagedLines
      );
      forbiddenTokensFile = pkgs.writeText "retroarch-forbidden-tokens" (
        lib.concatLines forbiddenManagedTokens
      );

      # rclone, curl and an htpasswd generated in-build. apacheHttpd is
      # referenced by store path rather than put on PATH so its setup hooks stay
      # out of the build environment.
      webdavTools = with pkgs; [
        rclone
        curl
        coreutils
        findutils
        gnugrep
      ];
      htpasswd = "${pkgs.apacheHttpd}/bin/htpasswd";

      webdavPrelude = ''
        set -euo pipefail
        export HOME="$PWD/home"
        mkdir -p "$HOME" data cache
        : > rclone.conf

        fail() {
          echo "FAIL: $*" >&2
          if [ -f server.log ]; then
            echo "--- rclone serve webdav log ---" >&2
            cat server.log >&2
          fi
          exit 1
        }

        expect() { # <label> <expected> <actual>
          if [ "$2" != "$3" ]; then
            fail "$1: expected $2, got $3"
          fi
          printf 'ok  %-48s %s\n' "$1" "$3"
        }

        # Serves the SAME directory on a fresh port with a fresh htpasswd, which
        # is how revocation is modelled: rclone reads --htpasswd at startup, so
        # a credential change is a restart, not a live reload.
        start_server() { # <port> <htpasswd-file>
          rclone serve webdav "$PWD/data" \
            --addr "127.0.0.1:$1" \
            --htpasswd "$2" \
            --vfs-cache-mode writes \
            --vfs-write-back 8s \
            --cache-dir "$PWD/cache" \
            --config "$PWD/rclone.conf" \
            --log-file server.log --log-level INFO &
          server_pid=$!
        }

        wait_ready() { # <port> <user:pass>
          local i code
          for i in $(seq 1 300); do
            code=$(curl -s -o /dev/null -w '%{http_code}' -u "$2" "http://127.0.0.1:$1/" || true)
            if [ "$code" = 200 ]; then
              return 0
            fi
            sleep 0.2
          done
          fail "rclone serve webdav never became ready on port $1 (last code $code, iteration $i)"
        }

        stop_server() {
          kill -9 "$server_pid" 2> /dev/null || true
          wait "$server_pid" 2> /dev/null || true
        }
      '';
    in
    {
      # Exposed as a package, not just a check fixture, for two reasons: it puts
      # the scanner on `nix run .#retroarch-saves-secret-scan` for an operator
      # who wants to check a bundle by hand before copying it onto removable
      # media, and it lets modules/gaming/saves/bundles.nix scan the bundles it
      # actually renders instead of re-implementing the rule. One scanner, one
      # key list, one set of positive controls.
      packages.retroarch-saves-secret-scan = secretScanner;

      # 1. A profile that contradicts itself must fail by NAME, not generically.
      checks.retroarch-saves-client-profiles =
        jqContract "retroarch-saves-client-profiles" profileEvidence
          profileFilter;

      # 2. Per-game core overrides, and DETECT refused wherever it appears.
      checks.retroarch-saves-core-policy =
        jqContract "retroarch-saves-core-policy" corePolicyEvidence
          corePolicyFilter;

      # 3. Literal .stignore output plus the priority order that gives it meaning.
      checks.retroarch-saves-stignore-order =
        pkgs.runCommand "retroarch-saves-stignore-order"
          {
            nativeBuildInputs = [ pkgs.jq ];
            evidenceJson = builtins.toJSON stignoreEvidence;
          }
          (
            lib.concatMapStrings (case: ''
              echo "== ${case.name} =="
              if ! diff -u ${pkgs.writeText "expected-${case.name}" case.expected} ${pkgs.writeText "actual-${case.name}" (savesLib.renderStignore case.args)}; then
                echo "FAIL: rendered .stignore for ${case.name} drifted from its contract." >&2
                echo "FIX: the left column is what every receiver must see. First match wins, so" >&2
                echo "     a moved line is a behaviour change, not a formatting change." >&2
                exit 1
              fi
            '') stignoreCases
            + ''
              printf '%s\n' "$evidenceJson" > evidence.json
              if ! jq -e ${lib.escapeShellArg stignoreFilter} evidence.json > /dev/null; then
                echo "FAIL: .stignore priority order or negation rooting regressed." >&2
                echo "FIX: rejects, then exclusions, then inclusions leaf-before-parents, then whole" >&2
                echo "     systems, then '*'. Every negation must start '!/': an unrooted one makes" >&2
                echo "     Syncthing walk otherwise-ignored directories on every rescan." >&2
                jq . evidence.json >&2
                exit 1
              fi
              touch "$out"
            ''
          );

      # 4. Real-world stems: spaces, brackets, parens, Unicode, case, nesting.
      checks.retroarch-saves-pattern-escaping =
        jqContract "retroarch-saves-pattern-escaping" escapingEvidence
          escapingFilter;

      # 5. Save and state extensions rejected from the ROM and BIOS channels.
      checks.retroarch-saves-rom-channel-rejects =
        jqContract "retroarch-saves-rom-channel-rejects" rejectEvidence
          rejectFilter;

      # 6. No generated artifact may carry a credential -- with a positive
      #    control, because a scanner that never fires is indistinguishable from
      #    one that is broken.
      checks.retroarch-saves-artifact-secret-scan =
        pkgs.runCommand "retroarch-saves-artifact-secret-scan"
          {
            nativeBuildInputs = [ secretScanner ];
          }
          ''
            set -euo pipefail

            echo "== clean artifacts =="
            retroarch-saves-secret-scan \
              ${managedConfigFile} \
              ${inventoryFile} \
              ${reportFile} \
              ${lib.concatStringsSep " " (map toString stignoreFiles)}

            control() { # <file> <expected reason fragment>
              local out
              if out=$(retroarch-saves-secret-scan "$1" 2>&1); then
                echo "FAIL: the scanner ACCEPTED the poisoned fixture $1." >&2
                echo "FIX: a scanner that cannot fail proves nothing. Restore the rule it lost." >&2
                exit 1
              fi
              case "$out" in
                *"$2"*) printf 'ok  rejected %-32s (%s)\n' "$(basename "$1")" "$2" ;;
                *)
                  echo "FAIL: $1 was rejected for the wrong reason:" >&2
                  echo "$out" >&2
                  exit 1
                  ;;
              esac
            }

            echo "== positive controls =="
            control ${poisonSecretKey} "credential-bearing key"
            control ${poisonWebdavPassword} "non-empty webdav_password"
            control ${poisonEntropy} "high-entropy token"

            echo "== negative control: prose naming the keys must be ACCEPTED =="
            if ! retroarch-saves-secret-scan ${cleanProseMention}; then
              echo "FAIL: the scanner rejected an artifact that only DOCUMENTS the credential keys." >&2
              echo "FIX: anchor the key rule on the assignment. Every unmanaged client's bundle has" >&2
              echo "     to tell the operator to enter webdav_username/webdav_password by hand." >&2
              exit 1
            fi
            echo "ok  accepted prose that names the keys without assigning them"

            touch "$out"
          '';

      # 7. The managed RetroArch settings, key by key.
      checks.retroarch-saves-retroarch-settings =
        pkgs.runCommand "retroarch-saves-retroarch-settings"
          {
            nativeBuildInputs = [ pkgs.gnugrep ];
          }
          ''
            set -euo pipefail

            while IFS= read -r line; do
              [ -n "$line" ] || continue
              if ! grep -Fqx -- "$line" ${managedConfigFile}; then
                echo "FAIL: the managed RetroArch settings no longer set: $line" >&2
                echo "FIX: managedSettings in lib/retroarch-saves.nix owns this key unconditionally." >&2
                exit 1
              fi
            done < ${expectedLinesFile}

            while IFS= read -r token; do
              [ -n "$token" ] || continue
              if grep -Fq -- "$token" ${managedConfigFile}; then
                echo "FAIL: the managed RetroArch settings emit the forbidden key: $token" >&2
                echo "FIX: cloud_sync_sync_systemfiles does not exist in RetroArch and would be a" >&2
                echo "     silent no-op; every other name here carries a credential and must be" >&2
                echo "     injected at runtime outside the nix store." >&2
                exit 1
              fi
            done < ${forbiddenTokensFile}

            # RetroArch parses key = "value" and nothing else.
            if grep -nvE '^[a-z0-9_]+ = ".*"$' ${managedConfigFile}; then
              echo "FAIL: a rendered line does not match RetroArch's key = \"value\" shape." >&2
              exit 1
            fi

            touch "$out"
          '';

      # 8. The WebDAV protocol itself, against a real rclone on loopback.
      checks.retroarch-saves-webdav-methods =
        pkgs.runCommand "retroarch-saves-webdav-methods"
          {
            nativeBuildInputs = webdavTools;
          }
          (
            webdavPrelude
            + ''
              port=18631
              user=link-test
              pass=not-a-real-password-for-tests
              cred="$user:$pass"
              base="http://127.0.0.1:$port"

              ${htpasswd} -Bbc htpasswd "$user" "$pass"
              grep -q '^link-test:\$2[aby]\$' htpasswd \
                || fail "htpasswd -B did not produce a bcrypt hash; rclone --htpasswd would then be storing a weaker digest"

              start_server "$port" "$PWD/htpasswd"
              trap stop_server EXIT
              wait_ready "$port" "$cred"

              code() { curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 -u "$cred" "$@"; }

              echo "== methods =="
              expect "OPTIONS /" 200 "$(code -X OPTIONS "$base/")"
              curl -s -D headers.txt -o /dev/null -X OPTIONS -u "$cred" "$base/"
              tr -d '\r' < headers.txt > headers-clean.txt
              grep -qi '^Dav: 1, 2$' headers-clean.txt \
                || fail "the server did not advertise DAV class 2; LOCK/UNLOCK are what let a second client fail loudly instead of interleaving writes"
              grep -qi '^Allow:.*PROPFIND' headers-clean.txt || fail "OPTIONS did not advertise PROPFIND"
              grep -qi '^Allow:.*MOVE' headers-clean.txt || fail "OPTIONS did not advertise MOVE"

              expect "PROPFIND / (Depth: 1)" 207 "$(code -X PROPFIND -H 'Depth: 1' "$base/")"
              expect "MKCOL /gba/" 201 "$(code -X MKCOL "$base/gba/")"
              expect "PUT /gba/alpha.srm" 201 "$(code -X PUT --data-binary 'SAVE-ONE' "$base/gba/alpha.srm")"
              expect "GET /gba/alpha.srm" 200 "$(code "$base/gba/alpha.srm")"
              expect "GET body" "SAVE-ONE" "$(curl -s -u "$cred" "$base/gba/alpha.srm")"
              expect "HEAD /gba/alpha.srm" 200 "$(code -I "$base/gba/alpha.srm")"
              expect "PUT overwrite" 201 "$(code -X PUT --data-binary 'SAVE-TWO' "$base/gba/alpha.srm")"
              expect "GET after overwrite" "SAVE-TWO" "$(curl -s -u "$cred" "$base/gba/alpha.srm")"

              echo "== trailing slashes survive unredirected =="
              # rclone issues NO redirects. A directory GET without the slash is a
              # hard 405, so a client that strips the slash gets an error rather
              # than a silently different resource.
              expect "GET /gba (no trailing slash)" 405 "$(code "$base/gba")"
              expect "GET /gba/ (trailing slash)" 200 "$(code "$base/gba/")"
              expect "no-slash redirect count" 0 "$(curl -s -o /dev/null -w '%{num_redirects}' --max-redirs 0 -u "$cred" "$base/gba")"
              expect "slash redirect count" 0 "$(curl -s -o /dev/null -w '%{num_redirects}' --max-redirs 0 -u "$cred" "$base/gba/")"
              expect "no-slash redirect target" "" "$(curl -s -o /dev/null -w '%{redirect_url}' --max-redirs 0 -u "$cred" "$base/gba")"
              expect "PROPFIND /gba (no trailing slash)" 207 "$(code -X PROPFIND -H 'Depth: 1' "$base/gba")"

              echo "== MOVE and DELETE =="
              expect "MOVE alpha -> beta" 201 "$(code -X MOVE -H "Destination: $base/gba/beta.srm" "$base/gba/alpha.srm")"
              expect "GET moved target" "SAVE-TWO" "$(curl -s -u "$cred" "$base/gba/beta.srm")"
              expect "GET moved source" 404 "$(code "$base/gba/alpha.srm")"
              expect "DELETE beta" 204 "$(code -X DELETE "$base/gba/beta.srm")"
              expect "GET after DELETE" 404 "$(code "$base/gba/beta.srm")"
              expect "DELETE absent" 404 "$(code -X DELETE "$base/gba/never-existed.srm")"
              # No implicit mkdir -p: a client that typos a system directory gets a
              # 409, not a second silently-forked save prefix.
              expect "PUT into absent collection" 409 "$(code -X PUT --data-binary 'X' "$base/nds/deep/x.srm")"

              echo "== unauthenticated =="
              # Assembled from parts rather than written as a `-u name:secret`
              # literal. The value is meaningless -- it is an identity that must
              # NOT exist in the htpasswd -- but the literal form is what
              # gitleaks' curl-auth-user rule matches, and a scanner finding in
              # a test fixture trains the reader to skim real findings.
              unknown_identity="nobody:$(printf 'not-a-real-%s' credential)"
              expect "GET / with no credentials" 401 "$(curl -s -o /dev/null -w '%{http_code}' "$base/")"
              expect "GET / with an unknown identity" 401 "$(curl -s -o /dev/null -w '%{http_code}' -u "$unknown_identity" "$base/")"

              echo "== nothing partial is ever visible in the served tree =="
              # This is what --vfs-cache-mode writes buys, and it is what btrbk and
              # restic depend on: the backend directory only ever gains COMPLETE
              # objects, at rename(2) time, after the whole body has arrived.
              for _ in $(seq 1 20000); do printf 'RETROARCH-SAVE-FIXTURE-0123456789\n'; done > big.bin
              expect "PUT a large body" 201 "$(code -X PUT --data-binary @big.bin "$base/gba/big.srm")"
              [ ! -e data/gba/big.srm ] \
                || fail "the served directory gained data/gba/big.srm before writeback; a snapshot taken now would capture a partial object"
              expect "GET the large body while it is still only in cache" 200 "$(code "$base/gba/big.srm")"

              landed=0
              for _ in $(seq 1 120); do
                if [ -e data/gba/big.srm ]; then landed=1; break; fi
                sleep 0.5
              done
              [ "$landed" = 1 ] || fail "the large body never reached the served directory"
              cmp big.bin data/gba/big.srm || fail "the object that landed on disk is not byte-identical to what was PUT"

              echo "== an interrupted PUT leaves the namespace consistent =="
              mkfifo slow.fifo
              ( printf 'PARTIAL-BODY-'; sleep 120 ) > slow.fifo &
              producer=$!
              curl -s -u "$cred" -T slow.fifo "$base/gba/slow.srm" > /dev/null 2>&1 &
              uploader=$!
              sleep 3
              [ ! -e data/gba/slow.srm ] \
                || fail "an in-flight PUT exposed a partially written object at the final on-disk name"
              kill -9 "$uploader" "$producer" 2> /dev/null || true
              wait "$uploader" 2> /dev/null || true
              wait "$producer" 2> /dev/null || true
              sleep 12

              expect "PROPFIND after the aborted PUT" 207 "$(code -X PROPFIND -H 'Depth: 1' "$base/gba/")"
              residue=$(find data \( -name '*.partial' -o -name '*.tmp' -o -name '.*.swp' \) -print | tr '\n' ' ')
              [ -z "$residue" ] || fail "the aborted PUT left temporary residue in the served tree: $residue"

              # The honest part: rclone's WebDAV handler still closes the VFS file
              # when the client vanishes, so a SHORT object can be committed at the
              # final name. Nothing corrupt is ever visible mid-flight, but byte
              # count is not proof of completeness -- which is exactly why the
              # read-only snapshot chain in check 10 exists.
              if [ -e data/gba/slow.srm ]; then
                aborted_size=$(stat -c %s data/gba/slow.srm)
                full_size=$(stat -c %s big.bin)
                [ "$aborted_size" -lt "$full_size" ] \
                  || fail "an aborted PUT committed a full-length object, which would make truncation undetectable"
                echo "note: the aborted PUT committed a short object of $aborted_size bytes"
              fi

              expect "re-PUT the aborted path" 201 "$(code -X PUT --data-binary @big.bin "$base/gba/slow.srm")"
              for _ in $(seq 1 120); do
                if [ -e data/gba/slow.srm ] && cmp -s big.bin data/gba/slow.srm; then break; fi
                sleep 0.5
              done
              cmp big.bin data/gba/slow.srm || fail "a complete PUT did not repair the path an aborted PUT had touched"

              touch "$out"
            ''
          );

      # 9. Two identities, one namespace, and revocation.
      checks.retroarch-saves-webdav-credentials =
        pkgs.runCommand "retroarch-saves-webdav-credentials"
          {
            nativeBuildInputs = webdavTools;
          }
          (
            webdavPrelude
            + ''
              link_cred="link-test:not-a-real-password-for-link"
              ios_cred="ios-test:not-a-real-password-for-ios"

              ${htpasswd} -Bbc htpasswd-both link-test not-a-real-password-for-link
              ${htpasswd} -Bb  htpasswd-both ios-test  not-a-real-password-for-ios
              # Revocation is a rewritten htpasswd, not an edit of the namespace:
              # nothing about removing an identity may touch a byte of save data.
              ${htpasswd} -Bbc htpasswd-revoked link-test not-a-real-password-for-link

              listing() { # <credential> <output file>
                curl -s -X PROPFIND -H 'Depth: 1' -u "$1" "$base/" \
                  | grep -oE 'href>[^<]*<' | sort > "$2"
              }

              port=18641
              base="http://127.0.0.1:$port"
              start_server "$port" "$PWD/htpasswd-both"
              trap stop_server EXIT
              wait_ready "$port" "$link_cred"

              code() { curl -s -o /dev/null -w '%{http_code}' --max-redirs 0 "$@"; }

              echo "== both identities reach the same namespace =="
              expect "link PUT manifest.server" 201 "$(code -X PUT --data-binary 'MANIFEST-V1' -u "$link_cred" "$base/manifest.server")"
              expect "link MKCOL /gba/" 201 "$(code -X MKCOL -u "$link_cred" "$base/gba/")"
              expect "link PUT shared save" 201 "$(code -X PUT --data-binary 'SAVE-FROM-LINK' -u "$link_cred" "$base/gba/shared.srm")"
              expect "ios GET the same manifest" "MANIFEST-V1" "$(curl -s -u "$ios_cred" "$base/manifest.server")"
              expect "ios GET the same save" "SAVE-FROM-LINK" "$(curl -s -u "$ios_cred" "$base/gba/shared.srm")"

              expect "ios PUT the shared manifest" 201 "$(code -X PUT --data-binary 'MANIFEST-V2' -u "$ios_cred" "$base/manifest.server")"
              expect "link sees the ios manifest write" "MANIFEST-V2" "$(curl -s -u "$link_cred" "$base/manifest.server")"
              expect "ios PUT the shared save" 201 "$(code -X PUT --data-binary 'SAVE-FROM-IOS' -u "$ios_cred" "$base/gba/shared.srm")"
              expect "link sees the ios save write" "SAVE-FROM-IOS" "$(curl -s -u "$link_cred" "$base/gba/shared.srm")"

              listing "$link_cred" listing-link.txt
              listing "$ios_cred" listing-ios.txt
              diff -u listing-link.txt listing-ios.txt \
                || fail "the two identities see different root listings; a per-identity namespace would split one game's save history in two"
              grep -q 'href>/manifest.server<' listing-link.txt \
                || fail "the shared manifest is missing from the root listing"

              echo "== unknown and malformed identities are refused =="
              expect "no credentials" 401 "$(code "$base/gba/shared.srm")"
              expect "unknown identity" 401 "$(code -u "rg-slide:not-enrolled" "$base/gba/shared.srm")"
              expect "known identity, wrong password" 401 "$(code -u "ios-test:wrong" "$base/gba/shared.srm")"

              stop_server
              trap - EXIT

              echo "== revoking one identity leaves the other working =="
              port=18642
              base="http://127.0.0.1:$port"
              start_server "$port" "$PWD/htpasswd-revoked"
              trap stop_server EXIT
              wait_ready "$port" "$link_cred"

              expect "link still reads the shared save" "SAVE-FROM-IOS" "$(curl -s -u "$link_cred" "$base/gba/shared.srm")"
              expect "link still reads the shared manifest" "MANIFEST-V2" "$(curl -s -u "$link_cred" "$base/manifest.server")"
              expect "revoked identity GET" 401 "$(code -u "$ios_cred" "$base/gba/shared.srm")"
              expect "revoked identity PUT" 401 "$(code -X PUT --data-binary 'SHOULD-NEVER-LAND' -u "$ios_cred" "$base/gba/shared.srm")"
              expect "the save the revoked identity tried to overwrite" "SAVE-FROM-IOS" "$(curl -s -u "$link_cred" "$base/gba/shared.srm")"

              listing "$link_cred" listing-after-revocation.txt
              diff -u listing-link.txt listing-after-revocation.txt \
                || fail "revoking an identity changed the namespace; revocation must be a credential change and nothing else"

              touch "$out"
            ''
          );

      # 10. Seed URLs encode each logical path segment, rather than treating a
      #     slash-separated save path as an already-valid URL.
      checks.retroarch-saves-seed-url-encoding =
        pkgs.runCommand "retroarch-saves-seed-url-encoding"
          {
            nativeBuildInputs = webdavTools ++ [ pkgs.jq ];
          }
          (
            webdavPrelude
            + ''
              encode_path() { # <logical slash-separated path>
                local path="$1" segment encoded="" separator=""
                local IFS="/"
                local -a segments
                read -r -a segments <<< "$path"
                for segment in "''${segments[@]}"; do
                  [ -n "$segment" ] || fail "accepted non-canonical logical path: $path"
                  encoded="$encoded$separator$(printf '%s' "$segment" | jq -sRr @uri)"
                  separator="/"
                done
                printf '%s' "$encoded"
              }
              remote_url() { printf '%s/%s' "$base" "$(encode_path "$1")"; }
              collection_url() { printf '%s/' "$(remote_url "$1")"; }

              port=18651
              user=url-encoding-test
              pass=not-a-real-password-for-url-tests
              cred="$user:$pass"
              base="http://127.0.0.1:$port"
              ${htpasswd} -Bbc htpasswd "$user" "$pass"
              start_server "$port" "$PWD/htpasswd"
              trap stop_server EXIT
              wait_ready "$port" "$cred"

              code() { curl -s -o /dev/null -w '%{http_code}' -u "$cred" "$@"; }
              put() { code -X PUT --data-binary "$2" "$(remote_url "$1")"; }
              get() { curl -s -u "$cred" "$(remote_url "$1")"; }

              pilot="saves/gba/Pokemon - Emerald-R 260525.srm"
              pilot_encoded="$(encode_path "$pilot")"
              expect "pilot path percent-encodes spaces" \
                "saves/gba/Pokemon%20-%20Emerald-R%20260525.srm" "$pilot_encoded"
              expect "pilot logical path is unchanged" \
                "saves/gba/Pokemon - Emerald-R 260525.srm" "$pilot"

              special="saves/GBA & More/Pokémon #1?.srm"
              special_encoded="$(encode_path "$special")"
              expect "reserved and UTF-8 segment encoding" \
                "saves/GBA%20%26%20More/Pok%C3%A9mon%20%231%3F.srm" "$special_encoded"
              expect "special logical path is unchanged" \
                "saves/GBA & More/Pokémon #1?.srm" "$special"

              expect "MKCOL saves" 201 "$(code -X MKCOL "$(collection_url saves)")"
              expect "MKCOL gba" 201 "$(code -X MKCOL "$(collection_url saves/gba)")"
              expect "PUT encoded pilot filename" 201 "$(put "$pilot" PILOT-SAVE)"
              expect "GET encoded pilot filename" "PILOT-SAVE" "$(get "$pilot")"
              expect "MKCOL encoded directory" 201 "$(code -X MKCOL "$(collection_url "saves/GBA & More")")"
              expect "PUT encoded filename" 201 "$(put "$special" SPECIAL-SAVE)"
              expect "GET encoded filename" "SPECIAL-SAVE" "$(get "$special")"
              expect "PROPFIND encoded directory" 207 \
                "$(code -X PROPFIND -H 'Depth: 1' "$(collection_url "saves/GBA & More")")"

              touch "$out"
            ''
          );

      # 11. Snapshot selection and the freshness guard, without btrfs.
      #
      # Modelled as directories carrying btrbk's `long` timestamp format and a
      # read-only marker, because the ALGORITHM is what can be wrong: btrbk
      # snapshots are always read-only when complete, so a read-write directory
      # in the snapshot tree is an interrupted run and restoring from it would
      # restore a half-copied save tree.
      checks.retroarch-saves-snapshot-freshness =
        pkgs.runCommand "retroarch-saves-snapshot-freshness"
          {
            nativeBuildInputs = with pkgs; [ coreutils ];
          }
          ''
            set -euo pipefail

            subvol=retroarch-saves
            # A fixed reference instant: reading the wall clock would make this
            # check pass or fail depending on when it ran.
            now=$(date -u -d "2026-03-14 06:00" +%s)
            max_age_minutes=1500

            fail() { echo "FAIL: $*" >&2; exit 1; }
            expect() {
              if [ "$2" != "$3" ]; then fail "$1: expected $2, got $3"; fi
              printf 'ok  %-52s %s\n' "$1" "$3"
            }

            mk() { # <tree> <name> <ro|rw>
              mkdir -p "$1/$2"
              printf '%s\n' "$3" > "$1/$2/.btrfs-readonly"
            }

            # Newest COMPLETED read-only snapshot for one subvolume name.
            # Lexical order over btrbk's `long` format is chronological order,
            # which is the entire reason the timestamp_format matters.
            select_snapshot() { # <tree> <subvolume name>
              local path stamp candidate="" best=""
              for path in "$1/$2".*; do
                [ -d "$path" ] || continue
                stamp=''${path##*.}
                # BOTH of btrbk's timestamp formats, because the instance in
                # modules/link/saves-storage.nix is configured `long-iso`
                # (YYYYMMDDThhmmss±hhmm) while btrbk's own default is `long`
                # (YYYYMMDDThhmm). A selector that recognised only one of them
                # would silently find NO snapshots the day the format changed --
                # which reads exactly like "no backup has ever run" and is the
                # failure this check exists to make impossible.
                case "$stamp" in
                  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9]) ;;
                  [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]T[0-9][0-9][0-9][0-9][0-9][0-9][-+][0-9][0-9][0-9][0-9]) ;;
                  *) continue ;;
                esac
                [ "$(cat "$path/.btrfs-readonly" 2> /dev/null || echo rw)" = ro ] || continue
                if [ -z "$candidate" ] || [ "$stamp" \> "$best" ]; then
                  candidate=$path
                  best=$stamp
                fi
              done
              [ -n "$candidate" ] || return 1
              printf '%s\n' "$candidate"
            }

            snapshot_age_minutes() { # <path> <reference epoch>
              local stamp epoch
              stamp=''${1##*.}
              epoch=$(date -u -d "''${stamp:0:4}-''${stamp:4:2}-''${stamp:6:2} ''${stamp:9:2}:''${stamp:11:2}" +%s)
              echo $(( ( $2 - epoch ) / 60 ))
            }

            freshness_guard() { # <tree> <subvolume name> <reference epoch> <max age minutes>
              local chosen age
              if ! chosen=$(select_snapshot "$1" "$2"); then
                echo "no completed read-only snapshot of $2 exists under $1" >&2
                echo "FIX: run 'systemctl start btrbk-<instance>.service' and confirm snapshot_dir exists." >&2
                return 1
              fi
              age=$(snapshot_age_minutes "$chosen" "$3")
              if [ "$age" -gt "$4" ]; then
                echo "newest completed snapshot $chosen is $age minutes old, over the $4 minute budget" >&2
                echo "FIX: check the btrbk timer, and remember snapshot_preserve is inert unless" >&2
                echo "     snapshot_preserve_min is set alongside it." >&2
                return 1
              fi
              printf '%s\n' "$chosen"
            }

            echo "== healthy tree: newest completed read-only snapshot wins =="
            mk healthy "$subvol.20260314T0300" ro
            mk healthy "$subvol.20260313T0300" ro
            mk healthy "$subvol.20260314T0530" rw
            mk healthy "$subvol.20260314T0400.tmp" ro
            mk healthy "other-subvolume.20260314T0559" ro
            expect "selection skips the in-progress read-write snapshot" \
              "healthy/$subvol.20260314T0300" "$(select_snapshot healthy "$subvol")"
            expect "age of the selected snapshot" 180 \
              "$(snapshot_age_minutes "healthy/$subvol.20260314T0300" "$now")"
            expect "freshness guard passes" "healthy/$subvol.20260314T0300" \
              "$(freshness_guard healthy "$subvol" "$now" "$max_age_minutes")"

            echo "== stale tree: the guard must refuse =="
            mk stale "$subvol.20260312T0300" ro
            mk stale "$subvol.20260314T0550" rw
            expect "selection still finds the newest completed snapshot" \
              "stale/$subvol.20260312T0300" "$(select_snapshot stale "$subvol")"
            if freshness_guard stale "$subvol" "$now" "$max_age_minutes" > /dev/null 2>&1; then
              fail "the freshness guard accepted a 47 hour old snapshot"
            fi
            freshness_guard stale "$subvol" "$now" "$max_age_minutes" 2> guard-stale.log > /dev/null || true
            grep -q 'over the 1500 minute budget' guard-stale.log \
              || fail "the stale-snapshot refusal did not name the budget it breached"
            grep -q 'snapshot_preserve_min' guard-stale.log \
              || fail "the refusal printed the fault without printing the fix"

            echo "== no completed snapshot at all: the guard must refuse loudly =="
            mk empty "$subvol.20260314T0500" rw
            mk empty "$subvol.20260314T0530" rw
            if select_snapshot empty "$subvol" > /dev/null 2>&1; then
              fail "selection returned a read-write snapshot, which is an interrupted btrbk run"
            fi
            if freshness_guard empty "$subvol" "$now" "$max_age_minutes" > /dev/null 2>&1; then
              fail "the freshness guard accepted a tree with no completed snapshot"
            fi
            freshness_guard empty "$subvol" "$now" "$max_age_minutes" 2> guard-empty.log > /dev/null || true
            grep -q 'no completed read-only snapshot' guard-empty.log \
              || fail "the empty-tree refusal did not say what was missing"
            grep -q 'btrbk-' guard-empty.log \
              || fail "the empty-tree refusal did not print the command that fixes it"

            echo "== lexical order over the long format is chronological =="
            mk rollover "$subvol.20251231T2359" ro
            mk rollover "$subvol.20260101T0001" ro
            expect "year rollover" "rollover/$subvol.20260101T0001" \
              "$(select_snapshot rollover "$subvol")"
            mk months "$subvol.20260901T0900" ro
            mk months "$subvol.20261001T0900" ro
            expect "month rollover past a single digit" "months/$subvol.20261001T0900" \
              "$(select_snapshot months "$subvol")"

            echo "== the configured long-iso format is selected and aged correctly =="
            mk iso "$subvol.20260314T030000+0100" ro
            mk iso "$subvol.20260313T030000+0100" ro
            mk iso "$subvol.20260314T053000+0100" rw
            expect "long-iso names are recognised, not silently skipped" \
              "iso/$subvol.20260314T030000+0100" "$(select_snapshot iso "$subvol")"
            expect "long-iso age parses from the leading YYYYMMDDThhmm" 180 \
              "$(snapshot_age_minutes "iso/$subvol.20260314T030000+0100" "$now")"

            # The DST fold is precisely where lexical order over a name stops
            # being chronological order: 02:30 occurs twice, and the second
            # occurrence carries the SMALLER offset, so the later snapshot sorts
            # EARLIER. modules/link/saves-storage.nix's real selector is immune
            # because it reads btrfs otime via `stat -c %W` and never parses a
            # name. This case pins that reasoning in place: if anyone ever
            # "simplifies" that tool into name parsing, the property asserted
            # here is the one they will break.
            echo "== DST fold: name order and real time disagree =="
            mk dst "$subvol.20261025T023000+0200" ro
            mk dst "$subvol.20261025T023000+0100" ro
            expect "lexical selection picks the +0100 name" \
              "dst/$subvol.20261025T023000+0200" "$(select_snapshot dst "$subvol")"
            if [ "$(date -u -d '2026-10-25 02:30:00 +0100' +%s)" \
                 -le "$(date -u -d '2026-10-25 02:30:00 +0200' +%s)" ]; then
              fail "the +0100 instant is not later than +0200; the DST premise is wrong"
            fi
            echo "ok  name order is NOT chronological across the fold -- otime is authoritative"

            touch "$out"
          '';
    };
}
