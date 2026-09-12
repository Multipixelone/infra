{
  lib,
  stdenv,
  stdenvNoCC,
  fetchurl,
  autoPatchelfHook,
  makeWrapper,
  alsa-lib,
  zlib,
}:
stdenvNoCC.mkDerivation (_finalAttrs: {
  pname = "caldera-headless";
  version = "1.0.47";

  # The publisher currently exposes this release only through its mutable
  # `latest` path. The fixed hash makes a changed upstream payload fail closed.
  src = fetchurl {
    url = "https://releases.caldera.homes/music/headless/latest/caldera-music-linux-x86_64.tar.gz";
    hash = "sha256-tJfm8X2LTy4fepVFTyNvjfDMijaAXqv9c6zzKryv0JA=";
  };

  # The archive intentionally contains several top-level files and directories.
  sourceRoot = ".";

  nativeBuildInputs = [
    autoPatchelfHook
    makeWrapper
  ];
  buildInputs = [
    alsa-lib
    stdenv.cc.cc
    zlib
  ];

  installPhase = ''
    runHook preInstall

    install -Dm755 bin/caldera-music "$out/libexec/caldera-headless/caldera-music"
    cp -dR lib "$out/libexec/caldera-headless/lib"

    runHook postInstall
  '';

  preFixup = ''
    # The upstream ELF has a build-time RUNPATH. Keep its bundled FFmpeg
    # libraries adjacent to the binary and make them visible to autoPatchelf.
    addAutoPatchelfSearchPath "$out/libexec/caldera-headless/lib"
  '';

  postFixup = ''
    # This mirrors the archive's wrapper, which sets LD_LIBRARY_PATH for its
    # adjacent bundled libraries. Deliberately do not install upgrade.sh or the
    # upstream wrapper: the daemon cannot replace this immutable Nix payload.
    makeWrapper "$out/libexec/caldera-headless/caldera-music" "$out/bin/caldera-headless" \
      --prefix LD_LIBRARY_PATH : "$out/libexec/caldera-headless/lib"
  '';

  meta = {
    description = "Caldera Music headless Plex-compatible player";
    homepage = "https://caldera.homes/";
    mainProgram = "caldera-headless";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
