{
  inputs,
  lib,
  rootPath,
  withSystem,
  ...
}:
{
  perSystem =
    { system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") {
      # Match the custom beets build's Python interpreter and dependencies.
      packages.listen =
        inputs.beets-plugins.inputs.nixpkgs.legacyPackages.${system}.python3Packages.callPackage
          "${rootPath}/pkgs/listen"
          { beets = inputs.beets-plugins.packages.${system}.default; };
    };

  configurations.nixos.link.module =
    { pkgs, ... }:
    let
      package = withSystem pkgs.stdenv.hostPlatform.system (args: args.config.packages.listen);
    in
    {
      home-manager.users.tunnel =
        { config, ... }:
        {
          # Assistant services need these paths even without a login shell.
          home.packages = [
            (pkgs.writeShellApplication {
              name = "listen";
              text = ''
                export LISTEN_BEETS_CONFIG=${lib.escapeShellArg "${config.xdg.configHome}/beets/config.yaml"}
                export LISTEN_BEETS_LOCK=${lib.escapeShellArg "${config.xdg.configHome}/beets/.import.lock"}
                export PLEXAPI_CONFIG_PATH=${lib.escapeShellArg config.age.secrets.plexapi.path}
                exec ${lib.getExe package} "$@"
              '';
            })
          ];
        };
    };
}
