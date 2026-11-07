{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      cfg = config.flake.nixosConfigurations.link.config;
      services = cfg.systemd.services;
      senders = [
        "commutecompass-morning"
        "commutecompass-poll"
        "commutecompass-alarm-publish"
      ];
      plainJobs = [
        "commutecompass-gtfs-refresh"
        "commutecompass-tomorrow"
      ];
      serviceConfig = name: services.${name}.serviceConfig or { };
      commonHardening =
        sc:
        (sc.ProtectSystem or null) == "strict"
        && (sc.NoNewPrivileges or null) == true
        && (sc.ProtectProc or null) == "invisible"
        && (sc.ProtectKernelTunables or null) == true
        && lib.elem cfg.services.commutecompass.dataDir (sc.ReadWritePaths or [ ]);
      senderHardening =
        name:
        let
          sc = serviceConfig name;
        in
        builtins.hasAttr name services
        && commonHardening sc
        && (sc.ProtectHome or null) == "read-only"
        && (sc.MemoryDenyWriteExecute or null) == false
        && (sc.ProcSubset or null) == "all"
        && lib.elem "/home/tunnel/.openclaw" (sc.ReadWritePaths or [ ]);
      plainHardening =
        name:
        let
          sc = serviceConfig name;
        in
        builtins.hasAttr name services
        && commonHardening sc
        && (sc.ProtectHome or null) == true
        && (sc.MemoryDenyWriteExecute or null) == true
        && (sc.ProcSubset or null) == "pid"
        && !(lib.elem "/home/tunnel/.openclaw" (sc.ReadWritePaths or [ ]));
      # The audio daemon needs its PipeWire socket, not OpenClaw access.
      daemonHardening =
        let
          sc = serviceConfig "commutecompass-alarm";
        in
        builtins.hasAttr "commutecompass-alarm" services
        && commonHardening sc
        && (sc.ProtectHome or null) == "read-only"
        && (sc.MemoryDenyWriteExecute or null) == true
        && (sc.ProcSubset or null) == "pid"
        && lib.elem cfg.services.commutecompass.alarm.runtimeDir (sc.ReadWritePaths or [ ])
        && !(lib.elem "/home/tunnel/.openclaw" (sc.ReadWritePaths or [ ]));
    in
    {
      checks = lib.mkIf (system == "x86_64-linux") {
        commutecompass-openclaw-hardening =
          assert lib.assertMsg (lib.all senderHardening senders)
            "CommuteCompass sender hardening contract failed";
          assert lib.assertMsg (lib.all plainHardening plainJobs)
            "CommuteCompass plain-job hardening contract failed";
          assert lib.assertMsg daemonHardening "CommuteCompass audio-daemon hardening contract failed";
          pkgs.runCommand "commutecompass-openclaw-hardening" { } ''
            echo 'CommuteCompass sender hardening contract passed' > "$out"
          '';
      };
    };
}
