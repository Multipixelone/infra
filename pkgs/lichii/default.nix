{
  lib,
  stdenv,
  src,
  callPackage,
  cmake,
  ninja,
  glslang,
  pkg-config,
  python3,
  qt6,
  sdl3,
  boost,
  cubeb,
  enet,
  ffmpeg-headless,
  fmt,
  frozen-containers,
  gamemode,
  httplib,
  kdePackages,
  libglvnd,
  libusb1,
  lz4,
  nlohmann_json,
  openssl,
  simpleini,
  zlib,
  vulkan-loader,
  pipewire,
  fetchurl,
  runCommand,
  gnutar,
  gzip,
}:
let
  dependencies = callPackage ./dependencies.nix { inherit src; };
  tz = (builtins.fromJSON (builtins.readFile "${src}/cpmfile.json")).tzdb;
  tzArchive = fetchurl {
    url = "https://${tz.git_host}/${tz.repo}/releases/download/${tz.version}/${tz.version}.tar.gz";
    hash = "sha512-${
      builtins.convertHash {
        inherit (tz) hash;
        hashAlgo = "sha512";
        toHashFormat = "base64";
      }
    }";
  };
  tzdb =
    runCommand "lichii-tzdb-${tz.version}"
      {
        nativeBuildInputs = [
          gnutar
          gzip
        ];
      }
      ''
        mkdir -p $out
        tar xf ${tzArchive} --strip-components=1 -C $out
      '';
in
stdenv.mkDerivation {
  pname = "lichii";
  version = "125-unstable-${builtins.substring 0 7 src.rev}";
  inherit src;

  strictDeps = true;
  nativeBuildInputs = [
    cmake
    ninja
    glslang
    pkg-config
    python3
    qt6.qttools
    qt6.wrapQtAppsHook
  ];
  buildInputs = [
    sdl3
    boost
    cubeb
    enet
    ffmpeg-headless
    fmt
    frozen-containers
    gamemode
    httplib
    kdePackages.quazip
    libusb1
    lz4
    nlohmann_json
    openssl
    simpleini
    zlib
    qt6.qtbase
    qt6.qtcharts
    qt6.qtwayland
  ];

  cmakeFlags = [
    (lib.cmakeBool "BUILD_TESTING" false)
    (lib.cmakeBool "YUZU_TESTS" false)
    (lib.cmakeBool "DYNARMIC_TESTS" false)
    (lib.cmakeBool "ENABLE_WERROR" false)
    (lib.cmakeBool "ENABLE_UPDATE_CHECKER" false)
    (lib.cmakeBool "ENABLE_WEB_SERVICE" false)
    (lib.cmakeBool "USE_DISCORD_PRESENCE" false)
    (lib.cmakeBool "YUZU_CRASH_DUMPS" false)
    (lib.cmakeBool "ENABLE_DEBUG_TOOLS" false)
    (lib.cmakeBool "ENABLE_LTO" false)
    (lib.cmakeBool "YUZU_USE_BUNDLED_QT" false)
    (lib.cmakeBool "YUZU_USE_BUNDLED_SDL3" false)
    (lib.cmakeBool "YUZU_USE_BUNDLED_FFMPEG" false)
    (lib.cmakeBool "YUZU_USE_BUNDLED_OPENSSL" false)
    (lib.cmakeBool "YUZU_USE_BUNDLED_SIRIT" false)
    (lib.cmakeBool "YUZU_ROOM" false)
    (lib.cmakeBool "YUZU_ROOM_STANDALONE" false)
    (lib.cmakeBool "CPMUTIL_FORCE_SYSTEM" true)
    (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    (lib.cmakeFeature "YUZU_BUILD_PRESET" "generic")
    (lib.cmakeFeature "YUZU_TZDB_PATH" "${tzdb}")
    (lib.cmakeFeature "LICHII_BUILD_TAG" "build-125")
  ]
  ++ lib.concatMap (dep: [
    (lib.cmakeBool "${dep.package}_FORCE_BUNDLED" true)
    (lib.cmakeFeature "${dep.package}_CUSTOM_DIR" "${dep.source}")
  ]) dependencies;

  postPatch = ''
    printf '%s\n' '${src.rev}' > GIT-COMMIT
    printf '%s\n' 'nx2' > GIT-REFSPEC
    printf '%s\n' 'build-125' > GIT-TAG
  '';

  postInstall = ''
    install -Dm644 $src/dist/nx2_switches.txt $out/bin/nx2_switches.txt
  '';

  preFixup = ''
    qtWrapperArgs+=(--prefix LD_LIBRARY_PATH : ${
      lib.makeLibraryPath [
        libglvnd
        vulkan-loader
        pipewire
      ]
    })
  '';

  postFixup = ''
    # Steam loads its overlay before the Qt wrapper can set LD_LIBRARY_PATH.
    # Make libGL available during the wrapper's own loader startup.
    patchelf --add-needed "${lib.getLib libglvnd}/lib/libGL.so.1" "$out/bin/lichii"
  '';

  meta = {
    description = "Experimental Nintendo Switch and Switch 2 emulator";
    homepage = "https://github.com/zortos293/Lichii";
    license = with lib.licenses; [
      gpl3Plus
      lgpl3Plus
      gpl2Plus
    ];
    mainProgram = "lichii";
    platforms = [ "x86_64-linux" ];
  };
}
