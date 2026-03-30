{
  lib,
  stdenvNoCC,
  fetchzip,
}:
stdenvNoCC.mkDerivation {
  pname = "pragmata-pro";
  version = "0.827";

  src = fetchzip {
    url = "https://blusky.s3.us-west-2.amazonaws.com/pragmata.zip";
    stripRoot = false;
    hash = "sha256-p7Kvc1lpnqwu7HkyKottMKN8ZZoNDTDxeZJJT+nDilI=";
  };

  # only extract the variable font because everything else is a duplicate
  installPhase = ''
    runHook preInstall

    install -Dm644 PragmataPro_*.ttf -t $out/share/fonts/truetype

    runHook postInstall
  '';

  meta = with lib; {
    homepage = "https://fsd.it/shop/fonts/pragmatapro/";
    description = "Condensed monospace font with programming ligatures";
    license = licenses.unfree;
    platforms = platforms.all;
  };
}
