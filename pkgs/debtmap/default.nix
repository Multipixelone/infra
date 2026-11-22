{
  lib,
  stdenvNoCC,
  fetchurl,
}:
let
  releases = {
    x86_64-linux = {
      target = "x86_64-unknown-linux-musl";
      hash = "sha256-ctnJLoaSjh2GPiFfusnnd21KncQ55NO+Api/q/TFHQE=";
    };
    aarch64-darwin = {
      target = "aarch64-apple-darwin";
      hash = "sha256-w/Di+zHB5KvxG3w7keuBE1i/3jhGjeX2qv2G9xcWTNU=";
    };
    x86_64-darwin = {
      target = "x86_64-apple-darwin";
      hash = "sha256-9DU04M/6+TZ9X8kTtf6fWw3+fMOA8pqPcDqOIlih2+0=";
    };
  };
  release = releases.${stdenvNoCC.hostPlatform.system};
in
stdenvNoCC.mkDerivation (finalAttrs: {
  pname = "debtmap";
  version = "0.24.1";

  src = fetchurl {
    url = "https://github.com/iepathos/debtmap/releases/download/${finalAttrs.version}/debtmap-${release.target}.tar.gz";
    inherit (release) hash;
  };

  # Upstream packages the executable and license at the archive root.
  sourceRoot = ".";
  dontConfigure = true;
  dontBuild = true;
  dontStrip = true;

  installPhase = ''
    runHook preInstall

    install -Dm755 debtmap "$out/bin/debtmap"
    install -Dm644 LICENSE "$out/share/licenses/debtmap/LICENSE"

    runHook postInstall
  '';

  meta = {
    description = "Identifies and prioritizes technical debt in codebases";
    homepage = "https://github.com/iepathos/debtmap";
    license = lib.licenses.mit;
    mainProgram = "debtmap";
    platforms = builtins.attrNames releases;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
  };
})
