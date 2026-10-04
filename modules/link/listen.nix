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
    { config, pkgs, ... }:
    let
      package = withSystem pkgs.stdenv.hostPlatform.system (args: args.config.packages.listen);
      # Upstream exposes no skill package option; reuse its installed wrapper.
      commutecompassSkill = lib.findFirst (
        package: lib.getName package == "commutecompass-skill"
      ) null config.environment.systemPackages;
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
                # The CLI locks only mutations and supplies bounded timeout
                # defaults; preserve caller-provided timeout overrides here.
                export PLEXAPI_CONFIG_PATH=${lib.escapeShellArg config.age.secrets.plexapi.path}
                export LISTEN_PLEX_SOURCE=${lib.escapeShellArg "listen list:)"}
                export LISTEN_PLEX_DONE_SOURCE=${lib.escapeShellArg "albums im rocking w"}
                ${lib.optionalString (commutecompassSkill != null) ''
                  export LISTEN_COMMUTECOMPASS=${lib.escapeShellArg (lib.getExe' commutecompassSkill "commutecompass-skill")}
                ''}
                exec ${lib.getExe package} "$@"
              '';
            })
          ];
        };
    };
}
