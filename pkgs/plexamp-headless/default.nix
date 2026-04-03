{
  lib,
  stdenvNoCC,
  makeWrapper,
  # treble.node is compiled for Node.js ABI v115 (node_register_module_v115)
  nodejs_20,
  squashfsTools,
  nodePackages,
  plexamp,
}:
let
  # Reuse the source and version from the nixpkgs plexamp desktop package
  inherit (plexamp) version src;

  # Extract the squashfs filesystem from the AppImage
  appimageContents = stdenvNoCC.mkDerivation {
    pname = "plexamp-appimage-contents";
    inherit version src;

    nativeBuildInputs = [ squashfsTools nodePackages.asar ];

    unpackPhase = ''
      unsquashfs "$src"
    '';

    installPhase = ''
      mkdir -p "$out"
      cd squashfs-root/resources

      # Extract JS source from the asar archive
      if [ -f app.asar ]; then
        asar extract app.asar "$out/app"
      elif [ -d app ]; then
        cp -r app "$out/app"
      fi

      # Copy native modules (e.g. treble.node) that live outside the asar
      if [ -d app.asar.unpacked ]; then
        cp -rn app.asar.unpacked/* "$out/app/" || true
      fi
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "plexamp-headless";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/plexamp-headless"
    cp -r ${appimageContents}/app/* "$out/lib/plexamp-headless/"

    mkdir -p "$out/bin"
    makeWrapper "${lib.getExe nodejs_20}" "$out/bin/plexamp-headless" \
      --add-flags "$out/lib/plexamp-headless/js/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Headless Plexamp player (extracted from desktop AppImage)";
    homepage = "https://plexamp.plex.tv/";
    mainProgram = "plexamp-headless";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
}
