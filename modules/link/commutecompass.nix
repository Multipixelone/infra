{ inputs, ... }:
{
  flake-file.inputs.commutecompass = {
    url = "github:Multipixelone/commutecompass";
  };

  configurations.nixos.link.module =
    {
      config,
      lib,
      pkgs,
      ...
    }:
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
        owner = "tunnel";
        group = "users";
        # Group-readable so tunnel (added to commutecompass via skill.users
        # below) can source the env file through the commutecompass-skill
        # wrapper. Without this, on-demand chat dispatch can't load the API
        # keys the systemd timers get via EnvironmentFile=.
        mode = "0440";
      };

      services.commutecompass = {
        enable = true;
        # Run as the tunnel login user so the service can reach openclaw's
        # npm install at /home/tunnel/.npm-global and its per-user state at
        # /home/tunnel/.openclaw (both 0700, owned by tunnel).
        user = "tunnel";
        group = "users";
        createUser = false;
        createGroup = false;

        configFile = "${inputs.secrets}/commutecompass/config.toml";
        venuesFile = "${inputs.secrets}/commutecompass/known_venues.yaml";
        environmentFile = config.age.secrets."commutecompass".path;

        # Default upstream is 20:45, which misses calendar events added later
        # in the evening (observed: 2026-05-26 22:01 + 00:27 additions silently
        # produced "no plan-able commutes tomorrow"). 22:30 catches typical
        # late-evening adds while still leaving margin before quiet_hours_start
        # (23:00) and any iOS Shortcut poll later in the night.
        tomorrowTime = "22:30:00";

        # Lets tunnel (the openclaw gateway user) invoke skill scripts
        # directly: installs `commutecompass-skill` on PATH and joins tunnel
        # to the commutecompass group so it can read the env file above.
        skill.users = [ "tunnel" ];

        openclaw = {
          package = openclawPkg;
          # The real chat id is sourced from OPENCLAW_TARGET in tokens.age so
          # it stays out of /nix/store. EnvironmentFile= is processed after
          # Environment= in the generated unit, so the env file wins.
          target = "set-via-OPENCLAW_TARGET-in-env-file";
        };
      };

      # Loosen two upstream hardening defaults so the openclaw (Node.js)
      # stage can run:
      #   * ProtectHome=true → read-only, plus a ReadWritePaths carve-out
      #     so openclaw can read its credentials and write its delivery
      #     queue under /home/tunnel/.openclaw.
      #   * MemoryDenyWriteExecute=true → false. V8 needs W^X mappings to
      #     bring up its JIT; with MDWE on, node aborts in
      #     v8::base::OS::SetPermissions before main().
      systemd.services =
        let
          openclawHardening = {
            serviceConfig = {
              ProtectHome = lib.mkForce "read-only";
              ReadWritePaths = [ "/home/tunnel/.openclaw" ];
              MemoryDenyWriteExecute = lib.mkForce false;
            };
          };
        in
        {
          "commutecompass-morning" = openclawHardening;
          "commutecompass-poll" = openclawHardening;
        };
    };
}
