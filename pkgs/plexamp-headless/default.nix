{
  lib,
  stdenvNoCC,
  fetchurl,
  makeWrapper,
  nodejs,
}:
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "plexamp-headless";
  version = "4.13.0";

  src = fetchurl {
    url = "https://plexamp.plex.tv/headless/Plexamp-Linux-headless-v${finalAttrs.version}.tar.bz2";
    hash = lib.fakeHash;
  };

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/plexamp-headless"
    cp -r . "$out/lib/plexamp-headless/"

    mkdir -p "$out/bin"
    makeWrapper "${lib.getExe nodejs}" "$out/bin/plexamp-headless" \
      --chdir "$out/lib/plexamp-headless/plexamp" \
      --add-flags "$out/lib/plexamp-headless/plexamp/js/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Headless Plexamp player";
    homepage = "https://plexamp.plex.tv/headless/";
    mainProgram = "plexamp-headless";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
