{
  lib,
  stdenvNoCC,
  imagemagick,
  xcursorgen,
}:
stdenvNoCC.mkDerivation {
  pname = "transparent-cursor-theme";
  version = "1.0";

  dontUnpack = true;

  nativeBuildInputs = [
    imagemagick
    xcursorgen
  ];

  installPhase = ''
        runHook preInstall

        themeName=Transparent
        themeDir=$out/share/icons/$themeName
        mkdir -p $themeDir/cursors

        cat > $themeDir/index.theme << 'EOF'
    [Icon Theme]
    Name=Transparent
    Comment=Transparent cursor for Cage/Wayland
    EOF

        ${lib.getExe' imagemagick "magick"} -size 1x1 xc:none "$TMPDIR/transparent.png"

        cat > "$TMPDIR/left_ptr.cursor" << 'EOF'
    1 0 0 transparent.png
    EOF

        ${lib.getExe xcursorgen} "$TMPDIR/left_ptr.cursor" "$themeDir/cursors/left_ptr"

        for cursor in \
          right_ptr center_ptr draft draft_inversa circle plus hand2 \
          left_side right_side top_left_corner top_right_corner \
          bottom_left_corner bottom_right_corner top_left top_right \
          top_side bottom_side pointer xterm text beam ibeam \
          crosshair fleur move grab grabbing dnd-none \
          resize_cyt resize_cyb resize_cxl resize_cxr \
          sb_h_double_arrow sb_v_double_arrow; do
          ln -s left_ptr "$themeDir/cursors/$cursor"
        done

        mkdir -p "$out/share/icons/default"
        cat > "$out/share/icons/default/index.theme" << 'EOF'
    [Icon Theme]
    Inherits=Transparent
    EOF

        runHook postInstall
  '';

  meta = with lib; {
    description = "Transparent cursor theme for Cage/Wayland sessions";
    platforms = platforms.all;
  };
}
