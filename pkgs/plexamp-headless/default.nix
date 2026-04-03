{
  lib,
  stdenvNoCC,
  nodejs,
}:
stdenvNoCC.mkDerivation {
  pname = "plexamp-headless";
  version = "4.13.0";

  src = null;
  dontUnpack = true;

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/bin"
    cat > "$out/bin/plexamp-headless" <<'EOF'
    #!/usr/bin/env sh
    exec ${lib.getExe nodejs} /var/lib/plexamp-headless/plexamp/js/index.js "$@"
    EOF
    chmod +x "$out/bin/plexamp-headless"

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
}
