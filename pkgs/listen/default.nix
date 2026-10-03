{
  buildPythonApplication,
  setuptools,
  beets,
  plexapi,
}:
buildPythonApplication {
  pname = "listen";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ setuptools ];
  dependencies = [
    beets
    plexapi
  ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';
  pythonImportsCheck = [ "listen_queue.cli" ];
  meta.mainProgram = "listen";
}
