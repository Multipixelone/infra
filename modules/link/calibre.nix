{ config, inputs, ... }:
{
  flake-file.inputs.calibre-plugins.url = "github:nydragon/calibre-plugins";
  flake.modules.homeManager.gui =
    { pkgs, lib, ... }:
    let
      pluginPkgs = inputs.calibre-plugins.packages.${pkgs.stdenv.hostPlatform.system};
    in
    {
      home.packages = [ pkgs.calibre ];
      home.activation.installCalibrePlugins = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        plugin_hash="${pluginPkgs.acsm-calibre-plugin}${pluginPkgs.dedrm-plugin}"
        marker="$HOME/.config/calibre/.plugins-installed-hash"
        if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$plugin_hash" ]; then
          for plugin in ${pluginPkgs.acsm-calibre-plugin} ${pluginPkgs.dedrm-plugin}; do
            $DRY_RUN_CMD ${lib.getExe' pkgs.calibre "calibre-customize"} -a "$plugin"
          done
          echo -n "$plugin_hash" > "$marker"
        fi
      '';
    };

  configurations.nixos.link.module = {
    services.calibre-web = {
      enable = true;
      user = config.flake.meta.owner.username;
      group = "users";
      listen.ip = "0.0.0.0";
      openFirewall = true;
      options = {
        calibreLibrary = "/home/${config.flake.meta.owner.username}/Calibre Library";
        enableBookUploading = true;
      };
    };
  };
}
