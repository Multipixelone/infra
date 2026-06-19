_: {
  configurations.nixos.iot.module = _: {
    virtualisation.oci-containers.containers.vnc-ipad = {
      image = "ddayb/vnc-ipad";
      ports = [ "5900:5900" ]; # LAN only — iot is not WAN-exposed
      environment = {
        VNC_PASSWORD = "ipad";
        # Declarative kiosk (modules/iot/dashboard-home.nix). Replaces the old
        # storage-mode main-home dashboard, which stays as a manual fallback.
        STARTING_WEBSITE_URL = "http://192.168.8.111:8123/nixos-home/home?kiosk";
        VNC_RESOLUTION = "1536x1152"; # 4:3, midpoint between 1024x768 and iPad Air native 2048x1536
      };
      volumes = [
        # Persist browser profile (cookies → HA stays logged in across restarts).
        # ddayb/vnc-ipad actually runs Chromium (not Firefox) as root; profile lives under /root/.config/chromium.
        "vnc-ipad-profile:/root"
      ];
      # Pin hostname so Chromium's SingletonLock (symlinked to <hostname>-<pid>)
      # stays valid across container recreates. Otherwise the persistent volume
      # holds a stale lock pointing at the previous random hostname and Chromium
      # refuses to launch.
      extraOptions = [ "--hostname=vnc-ipad" ];
    };
  };
}
