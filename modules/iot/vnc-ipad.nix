_: {
  configurations.nixos.iot.module = _: {
    virtualisation.oci-containers.containers.vnc-ipad = {
      image = "docker.io/ddayb/vnc-ipad:latest@sha256:10800ec38efb8254d0f627702de556269f6265c59a3ddfb3a700d31ad466189f";
      ports = [ "5900:5900" ]; # LAN only — iot is not WAN-exposed
      environment = {
        VNC_PASSWORD = "ipad";
        # Declarative kiosk (modules/iot/dashboard-home.nix). Replaced the old
        # storage-mode main-home dashboard, since deleted.
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
