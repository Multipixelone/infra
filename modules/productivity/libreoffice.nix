{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      home.packages = with pkgs; [
        libreoffice-stable
        jdk # Required for LibreOffice macros and Java-based extensions
        evince
      ];
    };
}
