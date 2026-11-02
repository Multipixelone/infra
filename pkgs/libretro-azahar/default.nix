{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  pkg-config,
  python3,
}:

stdenv.mkDerivation (finalAttrs: {
  pname = "libretro-azahar";
  version = "2126.2";

  src = fetchFromGitHub {
    owner = "azahar-emu";
    repo = "azahar";
    rev = "219d743a1e698101fe1ab8bef43e6563126c3c27";
    fetchSubmodules = true;
    hash = "sha256-FY70WDj/h80v5VNGLckjOF2vHsayx1Zoq/WQBkcWOjw=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    pkg-config
    python3
  ];

  postPatch = ''
    # Release archives lack .git; upstream reads these files for its build info.
    printf '%s\n' '${finalAttrs.src.rev}' > GIT-COMMIT
    printf '%s\n' '${finalAttrs.version}' > GIT-TAG
  '';

  cmakeFlags = [
    (lib.cmakeBool "ENABLE_LIBRETRO" true)
    # Libretro disables the standalone frontends, networking services and audio
    # backends itself. Keep the normal x86_64 Dynarmic JIT and both GPU renderers.
    (lib.cmakeBool "ENABLE_TESTS" false)
    (lib.cmakeBool "ENABLE_OPENGL" true)
    (lib.cmakeBool "ENABLE_VULKAN" true)
    (lib.cmakeBool "ENABLE_DISCORD_RPC" false)
    (lib.cmakeBool "ENABLE_NATIVE_OPTIMIZATION" false)
    (lib.cmakeBool "ENABLE_SSE42" false)
    (lib.cmakeBool "ENABLE_LTO" false)
    (lib.cmakeBool "CITRA_WARNINGS_AS_ERRORS" false)
    # Use the recursively pinned vendored dependencies, not configure-time fetches.
    (lib.cmakeBool "USE_SYSTEM_LIBS" false)
    (lib.cmakeBool "DYNARMIC_TESTS" false)
    (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
    # The core's custom version-string command needs the tag in the cache too.
    (lib.cmakeFeature "GIT_TAG" finalAttrs.version)
    (lib.cmakeFeature "CMAKE_POLICY_VERSION_MINIMUM" "3.5")
  ];

  buildFlags = [ "citra_libretro" ];

  installPhase = ''
    runHook preInstall
    install -Dm755 bin/Release/azahar_libretro.so "$out/lib/retroarch/cores/azahar_libretro.so"
    runHook postInstall
  '';

  passthru = {
    core = "azahar";
    libretroCore = "/lib/retroarch/cores";
  };

  meta = {
    description = "Azahar Nintendo 3DS emulator libretro core";
    homepage = "https://github.com/azahar-emu/azahar";
    license = lib.licenses.gpl2Plus;
    platforms = [ "x86_64-linux" ];
  };
})
