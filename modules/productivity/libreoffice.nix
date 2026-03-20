{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        libreoffice-fresh
        jdk # Required for LibreOffice macros and Java-based extensions
        evince
      ];
    };
}
