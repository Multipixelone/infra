{ inputs, ... }:
{
  flake-file.inputs.commutecompass = {
    url = "github:Multipixelone/commutecompass";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      # Reuse the openclaw binary that modules/link/openclaw.nix installs into
      # tunnel's home via `npm install -g openclaw`. The wrapper adds nodejs to
      # PATH so the binary's `#!/usr/bin/env node` shebang resolves inside the
      # commutecompass systemd sandbox.
      openclawPkg = pkgs.writeShellApplication {
        name = "openclaw";
        runtimeInputs = [ pkgs.nodejs ];
        text = ''
          exec /home/tunnel/.npm-global/bin/openclaw "$@"
        '';
      };
    in
    {
      imports = [ inputs.commutecompass.nixosModules.default ];

      age.secrets."commutecompass" = {
        file = "${inputs.secrets}/commutecompass/tokens.age";
        owner = "commutecompass";
        group = "commutecompass";
        mode = "0400";
      };

      services.commutecompass = {
        enable = true;
        configFile = "${inputs.secrets}/commutecompass/config.toml";
        venuesFile = "${inputs.secrets}/commutecompass/known_venues.yaml";
        environmentFile = config.age.secrets."commutecompass".path;

        openclaw = {
          package = openclawPkg;
          # The real chat id is sourced from OPENCLAW_TARGET in tokens.age so
          # it stays out of /nix/store. EnvironmentFile= is processed after
          # Environment= in the generated unit, so the env file wins.
          target = "set-via-OPENCLAW_TARGET-in-env-file";
        };
      };

      # Upstream sets ProtectHome=true, which hides /home/tunnel from the unit.
      # Re-expose tunnel's npm prefix + openclaw state dir so the wrapper above
      # can exec the binary and openclaw can read its channel config.
      systemd.services =
        let
          bind = {
            serviceConfig.BindReadOnlyPaths = [
              "/home/tunnel/.npm-global"
              "/home/tunnel/.openclaw"
            ];
          };
        in
        {
          "commutecompass-morning" = bind;
          "commutecompass-poll" = bind;
        };
    };
}
