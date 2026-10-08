{
  lib,
  buildNpmPackage,
  nodejs_24,
  python3Packages,
}:
let
  frontend = buildNpmPackage {
    pname = "games-dashboard-frontend";
    version = "0.1.0";
    src = ./frontend;
    nodejs = nodejs_24;
    npmDepsHash = "sha256-Q5151Ege+3ZQcu1Uj9yjL18DDEW07Iur0W18GW7SRHg=";
    preBuild = "npm run check";
    installPhase = ''
      runHook preInstall
      mkdir -p "$out"
      cp -r dist/. "$out/"
      runHook postInstall
    '';
  };
in
python3Packages.buildPythonApplication {
  pname = "games-dashboard";
  version = "0.1.0";
  pyproject = true;
  src = ./backend;
  build-system = [ python3Packages.setuptools ];
  dependencies = with python3Packages; [
    fastapi
    uvicorn
    pydantic
  ];
  preBuild = ''
    mkdir -p games_dashboard/static
    cp -r ${frontend}/. games_dashboard/static/
  '';
  # The flake check supplies the evaluated Nix manifest required by the tests.
  doCheck = false;
  pythonImportsCheck = [
    "games_dashboard.app"
    "games_dashboard.cli"
  ];
  passthru = { inherit frontend; };
  meta = {
    description = "Private game server dashboard with packaged frontend";
    mainProgram = "games-dashboard";
    platforms = lib.platforms.linux;
  };
}
