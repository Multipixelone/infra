{
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { pkgs, ... }:
    {
      packages.anki-tools = pkgs.python3Packages.callPackage "${rootPath}/pkgs/anki-tools" { };
    };

  # Ship the CLI alongside the Anki GUI (and its anki-connect add-on).
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      anki-tools = withSystem pkgs.stdenv.hostPlatform.system (
        psArgs: psArgs.config.packages.anki-tools
      );
    in
    {
      home.packages = [ anki-tools ];
    };
}
