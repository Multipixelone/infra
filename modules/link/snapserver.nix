{
  inputs,
  lib,
  ...
}:
{
  configurations.nixos.link.module =
    { pkgs, ... }:
    {
      age.secrets."librespot" = {
        file = "${inputs.secrets}/media/spotify.age";
        path = "/var/cache/snapserver/credentials.json";
        mode = "440";
        owner = "snapserver";
        group = "snapserver";
      };

      # AirPlay 2 timing and control ports.
      # Shairport-sync AirPlay 2 mode uses dynamic ports in the ephemeral range
      # (32768-60999) for event/data/control channels - without these open the
      # client sees the device via mDNS but fails with "unable to connect to
      # speakers" when the actual RTSP SETUP tries to open those channels.
      # See: https://github.com/mikebrady/shairport-sync/blob/master/TROUBLESHOOTING.md
      networking.firewall = {
        allowedUDPPorts = [
          319 # NQPTP PTP event
          320 # NQPTP PTP general
        ];
        allowedTCPPorts = [
          7000 # AirPlay 2 RTSP control
          6600 # MPD remote control
          1704 # Snapcast audio stream
          1705 # Snapcast control
        ];
        allowedTCPPortRanges = [
          {
            from = 32768;
            to = 60999;
          }
        ];
        allowedUDPPortRanges = [
          {
            from = 32768;
            to = 60999;
          }
        ];
      };

      users.users.snapserver = {
        group = "snapserver";
        isSystemUser = true;
      };
      users.groups.snapserver = { };

      services = {
        pipewire = {
          socketActivation = false;
          pulse.enable = true;
          wireplumber.extraConfig = {
            # Snapweb's in-browser "listen" client plays back through
            # whatever PipeWire picks as the default sink. Pin that to the
            # onboard analog line-out so it never drifts to GPU HDMI/DP
            # audio or another device that happens to appear.
            "line-out-priority" = {
              "monitor.alsa.rules" = [
                {
                  matches = [
                    {
                      "node.name" = "alsa_output.pci-0000_0e_00.4.analog-stereo";
                    }
                  ];
                  actions = {
                    update-props = {
                      "priority.session" = 2000;
                      "priority.driver" = 2000;
                    };
                  };
                }
              ];
            };
          };
        };
        avahi = {
          nssmdns4 = true;
          openFirewall = true;
        };
        shairport-sync = {
          enable = true;
          package = pkgs.shairport-sync-airplay2;
          openFirewall = true;
          user = "snapserver";
          group = "snapserver";
          settings = {
            general = {
              name = "Speakers";
              output_backend = "pipe";
              mdns_backend = "avahi";
              volume_max_db = 0.0;
              default_airplay_volume = -12.0;
            };
            sessioncontrol = {
              allow_session_interruption = "yes";
              session_timeout = 60;
            };
            pipe = {
              name = "/run/snapserver/shairport-fifo";
              output_rate = 44100;
              output_format = "S16_LE";
            };
          };
        };
        snapserver = {
          enable = true;
          # Snapweb is published privately through Link's HTTPS service
          # publication vhost. Ports 1704/1705 remain explicitly open above
          # for Snapcast clients, while HTTP port 1780 is no longer exposed.
          openFirewall = false;
          settings = {
            tcp-control.enabled = true;
            http.enabled = true;
            streaming_client.initial_volume = 100;
            stream.source = [
              "pipe:///run/snapserver/shairport-fifo?name=Airplay&sampleformat=44100:16:2"
              "pipe:///run/snapserver/mpd-fifo?name=MPD&sampleformat=44100:16:2"
              "librespot://${lib.getExe pkgs.librespot}?name=Spotify&devicename=Speakers"
              # Auto-switches to whichever of Airplay/MPD/Spotify is actively
              # playing, so clients can pick one stream instead of toggling.
              "meta:///Airplay/MPD/Spotify?name=Combined"
            ];
          };
        };
      };

      systemd = {
        tmpfiles.rules = [
          "p+ /run/snapserver/shairport-fifo 0660 snapserver snapserver - -"
          "p+ /run/snapserver/mpd-fifo 0666 snapserver snapserver - -"
        ];
        user.services = {
          wireplumber.wantedBy = [ "default.target" ];
        };
        services = {
          snapserver.serviceConfig = {
            CacheDirectory = [ "snapserver" ];
            DynamicUser = lib.mkForce false;
            User = "snapserver";
            Group = "snapserver";
          };
          shairport-sync = {
            after = [
              "nqptp.service"
              "snapserver.service"
            ];
            requires = [ "nqptp.service" ];
            wants = [ "snapserver.service" ];
            serviceConfig = {
              AmbientCapabilities = "CAP_SYS_NICE";
              SupplementaryGroups = [ "avahi" ];
            };
          };
          nqptp = {
            description = "Network Precision Time Protocol for Shairport Sync";
            wantedBy = [ "multi-user.target" ];
            after = [ "network.target" ];
            serviceConfig = {
              ExecStart = "${pkgs.nqptp}/bin/nqptp";
              Restart = "always";
              RestartSec = "5s";
              NoNewPrivileges = true;
              ProtectHome = true;
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              ProtectKernelModules = true;
              RestrictNamespaces = true;
            };
          };
        };
      };
    };
}
