{
  configurations.nixos.link.module =
    let
      atm-folder = "/srv/games/mc-atm10";
    in
    {
      systemd.tmpfiles.rules = [
        "d ${atm-folder}/data 0770 tunnel users -"
        "d ${atm-folder}/modpacks 0770 tunnel users -"
        # "d /srv/games/velocity 0770 tunnel users -"
      ];
      # age.secrets = {
      #   "curseforge" = {
      #     file = "${inputs.secrets}/curseforge.age";
      #     mode = "400";
      #     owner = "tunnel";
      #     group = "users";
      #   };
      # };
      networking.firewall.allowedTCPPorts = [
        25565
      ];
      virtualisation.oci-containers.containers = {
        minecraft-atm10 = {
          autoStart = false;
          image = "itzg/minecraft-server:latest";
          ports = [ "25565:25565" ];
          # environmentFiles = [config.age.secrets."curseforge".path];
          environment = {
            EULA = "TRUE";
            ONLINE_MODE = "TRUE";
            # MOD_PLATFORM = "AUTO_CURSEFORGE";
            TYPE = "CURSEFORGE";
            CF_SERVER_MOD = "/modpacks/ServerFiles-6.0.1.zip";
            MEMORY = "16G";
          };
          volumes = [
            "${atm-folder}/modpacks:/modpacks:ro"
            "${atm-folder}/data:/data"
          ];
        };
        # minecraft-proxy = {
        #   autoStart = true;
        #   image = "itzg/mc-proxy:latest";
        #   ports = ["25565:25577"];
        #   environment = {
        #     TYPE = "VELOCITY";
        #   };
        #   volumes = [
        #     "/srv/games/velocity:/server"
        #   ];
        # };
      };
    };
}
