{ config, ... }:
let
  infra = config;
in
{
  gitignore = [
    "/pkgs/games-dashboard/**/node_modules/"
    "/pkgs/games-dashboard/**/dist/"
    "/pkgs/games-dashboard/**/.venv/"
    "/pkgs/games-dashboard/**/__pycache__/"
    "/pkgs/games-dashboard/**/.pytest_cache/"
  ];

  perSystem =
    { pkgs, ... }:
    let
      python = pkgs.python3.withPackages (
        ps: with ps; [
          fastapi
          uvicorn
          pydantic
          watchfiles
          pytest
          httpx
        ]
      );
      # This is the existing real NixOS module output under evaluation-only
      # secret/backup overrides, not a second handwritten schema or manifest.
      fixture = pkgs.writeText "games-dashboard-mock-manifest.json" (
        builtins.toJSON infra.flake.checks.x86_64-linux.games-contract.fixtureData.enabled.manifest
      );
      launcher = pkgs.writeShellApplication {
        name = "games-dashboard-dev";
        meta.description = "Run the loopback dashboard skeleton with Python reload and Vite HMR";
        runtimeInputs = [
          python
          pkgs.nodejs_24
        ];
        text = ''
          export GAMES_DASHBOARD_MOCK_MANIFEST=${fixture}
          exec ${python}/bin/python "$PWD/pkgs/games-dashboard/backend/dev.py"
        '';
      };
    in
    {
      packages.games-dashboard-dev = launcher;
      devShells.games-dashboard = pkgs.mkShell {
        packages = [
          python
          pkgs.nodejs_24
          pkgs.just
          launcher
        ];
        GAMES_DASHBOARD_MOCK_MANIFEST = fixture;
      };
      checks.games-dashboard-backend =
        pkgs.runCommand "games-dashboard-backend-check"
          {
            nativeBuildInputs = [ python ];
            GAMES_DASHBOARD_MOCK_MANIFEST = fixture;
          }
          ''
            export PYTHONDONTWRITEBYTECODE=1
            pytest -p no:cacheprovider -c ${../../pkgs/games-dashboard/backend}/pyproject.toml ${../../pkgs/games-dashboard/backend}/tests
            touch "$out"
          '';
      # The repository formatter has no Svelte parser. Keep this single plain
      # skeleton component excluded until frontend formatting is introduced.
      treefmt.settings.global.excludes = [ "pkgs/games-dashboard/frontend/src/*.svelte" ];
    };
}
