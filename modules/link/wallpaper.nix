_:
let
  main = builtins.fetchurl {
    name = "wallpaper-14nh77xn8x58693y2na5askm6612xqbll2kr6237y8pjr1jc24xp.png";
    url = "https://drive.usercontent.google.com/download?id=1OrRpU17DU78sIh--SNOVI6sl4BxE06Zi";
    sha256 = "14nh77xn8x58693y2na5askm6612xqbll2kr6237y8pjr1jc24xp";
  };
  side = builtins.fetchurl {
    name = "wallpaper-05jbbil1zk8pj09y52yhmn5b2np2fqnd4jwx49zw1h7pfyr7zsc8.png";
    url = "https://blusky.s3.us-west-2.amazonaws.com/SU_SKY.PNG";
    sha256 = "05jbbil1zk8pj09y52yhmn5b2np2fqnd4jwx49zw1h7pfyr7zsc8";
  };
in
{
  configurations.nixos.link.module =
    { pkgs, config, ... }:
    let
      set-wallpaper = pkgs.writeShellApplication {
        name = "set-wallpaper";
        runtimeInputs = [
          pkgs.awww
          pkgs.socat
          pkgs.jq
          config.programs.hyprland.package
        ];
        text = ''
          # Wait for awww daemon to be ready
          until awww query &>/dev/null; do sleep 0.5; done

          # Set wallpapers on known monitors (|| true so a missing output doesn't abort)
          awww img --outputs DP-1 "${main}" || true
          awww img --outputs DP-3 "${side}" || true

          # Resolve the active Hyprland socket
          XDG_RUNTIME_DIR="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
          sig=$(hyprctl instances -j | jq -r 'sort_by(.time) | last | .instance')
          socket="$XDG_RUNTIME_DIR/hypr/$sig/.socket2.sock"

          # Watch for new monitors and apply the default wallpaper
          socat -u "UNIX-CONNECT:$socket" - | while IFS= read -r line; do
            case "$line" in
              monitoradded*)
                monitor="''${line#monitoradded>>}"
                awww img --outputs "$monitor" "${main}"
                ;;
            esac
          done
        '';
      };
    in
    {
      home-manager.users.tunnel =
        { lib, ... }:
        {
          systemd.user.services.wallpaper = {
            Unit = {
              Description = "Set wallpaper on all monitors and watch for new ones";
              After = [
                "awww.service"
                "graphical-session.target"
              ];
              PartOf = [ "graphical-session.target" ];
            };
            Service = {
              ExecStart = lib.getExe set-wallpaper;
              Restart = "on-failure";
              RestartSec = "3s";
            };
            Install.WantedBy = [ "graphical-session.target" ];
          };
        };
    };
}
