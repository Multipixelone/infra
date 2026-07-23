{
  lib,
  inputs,
  withSystem,
  ...
}:
let
  # Parse catppuccin foot theme INI into a Nix attrset
  catppuccinColors =
    let
      themeContent = builtins.readFile "${inputs.catppuccin-foot}/themes/catppuccin-mocha.ini";
      lines = builtins.filter (l: l != "" && !(lib.hasPrefix "[" l)) (lib.splitString "\n" themeContent);
      parseKV =
        line:
        let
          parts = lib.splitString "=" line;
        in
        {
          name = builtins.head parts;
          value = lib.concatStringsSep "=" (builtins.tail parts);
        };
    in
    builtins.listToAttrs (map parseKV lines);
in
{
  flake-file.inputs.catppuccin-foot = {
    url = "github:catppuccin/foot";
    flake = false;
  };
  perSystem.wrappers.packages.foot = true;
  flake.wrappers.foot =
    { pkgs, wlib, ... }:
    {
      imports = [ wlib.wrapperModules.foot ];
      settings = {
        main = {
          box-drawings-uses-font-glyphs = "yes";
          pad = "4x4 center";
          selection-target = "clipboard";
          font = "PragmataPro Mono Liga:size=11";
        };
        desktop-notifications.command = "${lib.getExe pkgs.libnotify} -a \${app-id} -i \${app-id} \${title} \${body}";
        scrollback = {
          lines = 10000;
          multiplier = 3;
          indicator-position = "relative";
          indicator-format = "line";
        };
        url = {
          launch = "xdg-open \${url}";
          label-letters = "sadfjklewcmpgh";
          osc8-underline = "url-mode";
        };
        cursor = {
          style = "beam";
          beam-thickness = 1;
        };
        colors-dark = catppuccinColors // {
          alpha = "0.72";
          # only the default background is transparent (text/UI stay opaque) so
          # Hyprland's blur reads as frosted glass instead of a washed-out,
          # see-through surface. "all" made every cell alpha. The lower the
          # alpha, the more of Hyprland's (heavy, size=10) blur shows through.
          alpha-mode = "default";
        };
      };
    };
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    {
      stylix.targets.foot.enable = false;
      programs.foot = {
        enable = true;
        server.enable = true;
        package = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.foot);
      };
    };
}
