{ lib, ... }:
{
  configurations.nixos.marin.module =
    { pkgs, ... }:
    {
      options.services.marin.headlessPlayer = lib.mkOption {
        type = lib.types.enum [
          "plexamp"
          "caldera"
          "none"
        ];
        default = "caldera";
        description = "Headless network music player to run on Marin.";
      };

      config = {
        # The built-in CS4208 codec (card "PCH") boots with its analog "Speaker"
        # output muted at 0%, so PipeWire sends audio into a dead channel and no
        # sound reaches the line-out. Nothing restores this on marin (no
        # alsa-restore service), so unmute it once the sound card is up.
        systemd.services.marin-speaker-unmute = {
          description = "Unmute built-in Speaker output (CS4208 boots muted)";
          after = [ "sound.target" ];
          wantedBy = [ "multi-user.target" ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecStart = "${pkgs.alsa-utils}/bin/amixer -c PCH sset 'Speaker' 80% unmute";
          };
        };
      };
    };
}
