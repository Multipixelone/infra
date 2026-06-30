{
  lib,
  stdenv,
  fetchurl,
}:

stdenv.mkDerivation {
  pname = "ntn";
  version = "0.18.1";

  src = fetchurl {
    url = "https://registry.npmjs.org/ntn/-/ntn-0.18.1.tgz";
    hash = "sha256-9iRX4bGAl17LbZRpwwi05l3trYOtGTyOAAFU4kS7EZw=";
  };

  dontBuild = true;
  dontConfigure = true;

  # npm tarballs extract to "package/"
  sourceRoot = "package";

  installPhase = ''
    runHook preInstall
    mkdir -p $out/bin
    install -m 755 dist/ntn-linux-x64/ntn $out/bin/ntn
    runHook postInstall
  '';

  meta = with lib; {
    description = "Notion CLI";
    homepage = "https://www.npmjs.com/package/ntn";
    license = licenses.mit;
    platforms = [ "x86_64-linux" ];
    mainProgram = "ntn";
  };
}
