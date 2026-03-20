{
  buildPythonApplication,
  fetchFromGitHub,
}:
buildPythonApplication {
  pname = "slskd-stats";
  version = "0.1.2";
  src = fetchFromGitHub {
    owner = "Arairon";
    repo = "slskd-stats";
    rev = "dbb8588e39bf93cae0dcf11316e50e3759268724";
    hash = "sha256-LtKUnTPeQMEh3wRTmTs7nBRCoXR063PRf5PGDH9An5Y=";
  };
  pyproject = false;

  installPhase = ''
    install -Dm755 main.py $out/bin/slskd-stats
  '';

  meta.mainProgram = "slskd-stats";
}
