{
  buildPythonApplication,
  setuptools,
  beets,
  listen,
}:
buildPythonApplication {
  pname = "beets-embed-backfill";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ setuptools ];
  dependencies = [
    beets
    listen
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    export PYTHONDONTWRITEBYTECODE=1
    python -m unittest discover -s tests -v
    runHook postCheck
  '';
  pythonImportsCheck = [ "beets_embed_backfill" ];
  meta.mainProgram = "beets-embed-backfill-run";
}
