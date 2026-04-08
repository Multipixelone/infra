{
  flake.modules.homeManager.gaming =
    hmArgs@{ lib, ... }:
    let
      inherit (hmArgs.config.lib.stylix) colors;
      scale = "${colors.base05},${colors.base09},${colors.base08}";
    in
    {
      stylix.targets.mangohud.enable = false;
      programs.mangohud = {
        enable = true;
        enableSessionWide = true;
        settings = {
          # fix some weird stylix defaults
          background_alpha = lib.mkForce 0.0; # Background in horizontal for some reason stretches the whole screen?
          font_size = lib.mkForce 16;
          font_size_text = lib.mkForce 16;
          no_small_font = true;
          font_scale = lib.mkForce 1.0;
          font_scale_media_player = 1.0;
          # custom stuff
          hud_no_margin = true;
          text_outline_thickness = 1.5;
          horizontal = true;
          time = true;
          vram = true;

          time_no_label = true;
          time_format = "%H:%M";
          frame_timing = 0;
          media_player = true;
          media_player_format = "{artist} - {title}";

          fps_value = "90,144,240";
          fps_color_change = "${colors.base08},${colors.base09},${colors.base0B}";

          gpu = true;
          gpu_color = colors.base08;
          gpu_load_color = scale;

          cpu = true;
          cpu_color = colors.base0D;
          cpu_load_color = scale;

          ram = true;
          ram_color = "F5C2E7";
        };
      };
    };
}
