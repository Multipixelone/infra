{
  perSystem =
    { pkgs, ... }:
    let
      screenshot-pkgs = [
        pkgs.grimblast
        pkgs.tesseract
        pkgs.wl-clipboard
        pkgs.libnotify
      ];
    in
    {
      packages.screenshot-area = pkgs.writeShellApplication {
        name = "screenshot-area";
        runtimeInputs = screenshot-pkgs;
        text = ''
          hyprctl keyword animation "fadeOut,0,0,default"
          grimblast --notify copysave area
          hyprctl keyword animation "fadeOut,1,4,default"'';
      };
      packages.screenshot-area-ocr = pkgs.writeShellApplication {
        name = "screenshot-area-ocr";
        runtimeInputs = screenshot-pkgs;
        text = ''
          hyprctl keyword animation "fadeOut,0,0,default"
          TEXT=$(grimblast save area - | tesseract -l eng - -)
          wl-copy "$TEXT"
          notify-send "Text Copied" "$TEXT"
          hyprctl keyword animation "fadeOut,1,4,default"'';
      };
    };
}
