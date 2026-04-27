{
  lib,
  ...
}:
{
  flake-file.inputs.nixpkgs-xr.url = "github:nix-community/nixpkgs-xr";

  flake.modules.homeManager.gaming =
    { pkgs, ... }:
    let
      inherit (lib) getExe;
    in
    {
      xdg.configFile."openxr/1/active_runtime.json".source =
        "${pkgs.monado}/share/openxr/1/openxr_monado.json";
      home.packages = [ pkgs.wayvr ];

      systemd.user.services.wlx-overlay-s-openxr = {
        Unit = {
          Description = "OpenXR Overlay";
          After = [
            "graphical-session.target"
            "monado.service"
          ];

          PartOf = [
            "monado.service"
            "graphical-session.target"
          ];

          Requisite = [
            "graphical-session.target"
            "monado.service"
            "monado.socket"
          ];
        };

        Service = {
          ExecStart = "${getExe pkgs.wayvr} --show";
        };

        Install.WantedBy = [ "monado.service" ];
      };
      systemd.user.services.wlx-overlay-s-openvr = {
        Unit = {
          Description = "OpenVR Overlay";
          After = [ "graphical-session.target" ];
          PartOf = [ "graphical-session.target" ];
          Requisite = [ "graphical-session.target" ];
        };

        Service = {
          ExecStart = "${getExe pkgs.wayvr} --openvr --show";
        };
      };
      # xdg.configFile."openvr/openvrpaths.vrpath".text =
      #   let
      #     steam = "${config.xdg.dataHome}/Steam";
      #   in
      #   builtins.toJSON {
      #     version = 1;
      #     jsonid = "vrpathreg";

      #     external_drivers = null;
      #     config = [ "${steam}/config" ];

      #     log = [ "${steam}/logs" ];

      #     "runtime" = [
      #       "${pkgs.xrizer}/lib/xrizer"
      #       # OR
      #       #"${pkgs.opencomposite}/lib/opencomposite"
      #     ];
      #   };
    };
}
