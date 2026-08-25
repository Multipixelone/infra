{
  config,
  inputs,
  lib,
  ...
}:
let
  # Shared by services.calibre-web and the publication route below; the route is
  # resolved at flake level, where the NixOS module's own config is out of
  # scope, so the port cannot be read back from services.calibre-web. Set
  # explicitly rather than relying on the nixpkgs default so the two cannot
  # drift apart.
  webPort = 8083;
in
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

  # Published as calibre.nyc.finnrut.is (internal only). Defined here rather
  # than in modules/service-publication/registry.nix so the listen port has one
  # source of truth.
  servicePublication.applications.calibre = {
    site = "nyc";
    homepage = {
      name = "Calibre-Web";
      group = "Media";
      description = "Ebook library and reader";
      icon = "calibre-web";
    };
    routes.root = {
      backend = {
        host = "link";
        port = webPort;
      };
      health = {
        # / answers 302 to the login form; the form itself is the unauthenticated
        # page that proves the app rendered. Confirmed 200 against the running
        # service.
        path = "/login";
        expectedStatuses = [ 200 ];
        timeoutSeconds = 8;
      };
    };
  };

  configurations.nixos.link.module =
    let
      username = config.flake.meta.owner.username;
      libraryLink = "/home/${username}/calibre-library";
    in
    {
      # Symlink avoids spaces-in-path issues with systemd ReadWritePaths
      systemd.tmpfiles.rules = [
        "L+ ${libraryLink} - - - - /home/${username}/Calibre Library"
      ];
      services.calibre-web = {
        enable = true;
        user = username;
        group = "users";
        listen = {
          ip = "0.0.0.0";
          port = webPort;
        };
        openFirewall = true;
        options = {
          calibreLibrary = libraryLink;
          enableBookUploading = true;
        };
      };
      systemd.services.calibre-web.serviceConfig.ProtectHome = lib.mkForce "read-only";
    };
}
