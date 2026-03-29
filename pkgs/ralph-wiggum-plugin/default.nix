{
  lib,
  stdenvNoCC,
  bash,
  python3,
  src,
}:

stdenvNoCC.mkDerivation {
  pname = "ralph-wiggum-plugin";
  version = "unstable";

  inherit src;

  nativeBuildInputs = [
    bash
    python3
  ];

  dontBuild = true;

  installPhase = ''
    runHook preInstall
    cp -r plugins/ralph-wiggum $out
    chmod +x $out/hooks/stop-hook.sh $out/scripts/setup-ralph-loop.sh
    patchShebangs $out
    runHook postInstall
  '';

  meta = with lib; {
    description = "Ralph Wiggum loop plugin for Claude Code — self-referential agentic loops";
    homepage = "https://github.com/anthropics/claude-code";
    platforms = platforms.all;
  };
}
