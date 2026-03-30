{
  lib,
  buildPythonApplication,
  setuptools,
  requests,
  beautifulsoup4,
  yt-dlp,
  genanki,
  ffmpeg,
  gifski,
}:
buildPythonApplication {
  pname = "asl-anki";
  version = "0.1.0";
  src = ./.;
  pyproject = true;

  build-system = [ setuptools ];

  propagatedBuildInputs = [
    requests
    beautifulsoup4
    yt-dlp
    genanki
  ];

  # Inject ffmpeg and gifski into the wrapper's PATH so subprocess calls work
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    "${lib.makeBinPath [
      ffmpeg
      gifski
    ]}"
  ];

  doCheck = false;

  meta = {
    description = "Generate Anki flashcards for ASL vocabulary from signasl.org";
    homepage = "https://www.signasl.org";
    license = lib.licenses.mit;
    maintainers = with lib.maintainers; [ Multipixelone ];
    mainProgram = "asl-anki";
  };
}
