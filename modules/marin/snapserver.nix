{
  inputs,
  ...
}:
{
  configurations.nixos.marin.module =
    { pkgs, lib, ... }:
    let
      rain-sound = pkgs.fetchurl {
        url = "https://media.rainymood.com/0.mp3";
        hash = "sha256-++BUqQf/qiiD062q/fXCd/sZNzbYA+/zTOsIE4LkKFc=";
      };
      vgmDir = "/var/lib/snapserver/vgm";
    in
    {
      age.secrets."librespot" = {
        file = "${inputs.secrets}/media/spotify.age";
        path = "/var/cache/snapserver/credentials.json";
        mode = "440";
        owner = "snapserver";
        group = "snapserver";
      };

      # AirPlay 2 timing and control ports.
      networking.firewall = {
        allowedUDPPorts = [
          319
          320
        ];
        allowedTCPPorts = [ 7000 ];
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
          openFirewall = true;
          settings = {
            tcp-control.enabled = true;
            http.enabled = true;
            stream.source = [
              "pipe:///run/snapserver/shairport-fifo?name=Airplay&sampleformat=44100:16:2"
              "librespot://${lib.getExe pkgs.librespot}?name=Spotify&devicename=Speakers"
              "pipe:///run/snapserver/rain-fifo?name=Rain&sampleformat=44100:16:2"
              "pipe:///run/snapserver/vgm-fifo?name=VGM&sampleformat=44100:16:2"
              "meta:///Rain/VGM?name=House Mood"
              "meta:///Airplay/Spotify?name=Combined"
            ];
          };
        };
      };

      systemd = {
        tmpfiles.rules = [
          "p+ /run/snapserver/shairport-fifo 0660 snapserver snapserver - -"
          "p+ /run/snapserver/rain-fifo 0660 snapserver snapserver - -"
          "p+ /run/snapserver/vgm-fifo 0660 snapserver snapserver - -"
          "d ${vgmDir} 0755 snapserver snapserver - -"
        ];
        user.services = {
          wireplumber.wantedBy = [ "default.target" ];
          snapclient = {
            description = "SnapCast client";
            after = [
              "snapserver.service"
              "pipewire.service"
            ];
            wants = [
              "snapserver.service"
              "pipewire.service"
            ];
            wantedBy = [ "default.target" ];
            serviceConfig = {
              ExecStart = "${lib.getExe' pkgs.snapcast "snapclient"} --host 127.0.0.1 --player pipewire";
            };
          };
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
          ambience-rain = {
            description = "Ambient rain loop";
            after = [ "snapserver.service" ];
            wants = [ "snapserver.service" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart = "${lib.getExe' pkgs.ffmpeg-headless "ffmpeg"} -re -stream_loop -1 -i ${rain-sound} -f s16le -acodec pcm_s16le -ac 2 -ar 44100 /run/snapserver/rain-fifo";
              User = "snapserver";
              Group = "snapserver";
              Restart = "on-failure";
              RestartSec = "5s";
              NoNewPrivileges = true;
              ProtectHome = true;
              ProtectKernelTunables = true;
              ProtectControlGroups = true;
              ProtectKernelModules = true;
              RestrictNamespaces = true;
            };
          };
          vgm-radio = {
            description = "Video game music shuffle radio";
            after = [ "snapserver.service" ];
            wants = [ "snapserver.service" ];
            wantedBy = [ "multi-user.target" ];
            unitConfig.ConditionDirectoryNotEmpty = vgmDir;
            serviceConfig = {
              ExecStart = lib.escapeShellArgs [
                (lib.getExe pkgs.mpv)
                "--no-video"
                "--no-terminal"
                "--shuffle"
                "--loop-playlist=inf"
                "--audio-display=no"
                "--audio-channels=stereo"
                "--audio-samplerate=44100"
                "--audio-format=s16"
                "--ao=pcm"
                "--ao-pcm-file=/run/snapserver/vgm-fifo"
                "--ao-pcm-waveheader=no"
                vgmDir
              ];
              User = "snapserver";
              Group = "snapserver";
              Restart = "on-failure";
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
