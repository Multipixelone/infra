{
  buildPythonApplication,
  ffmpeg,
  setuptools,
}:
buildPythonApplication {
  pname = "openclaw-music";
  version = "0.1.0";
  pyproject = true;
  src = ./.;
  build-system = [ setuptools ];
  doCheck = true;
  nativeCheckInputs = [ ffmpeg ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -p 'test_*.py' -v
    runHook postCheck
  '';

  meta.mainProgram = "openclaw-music";
}
