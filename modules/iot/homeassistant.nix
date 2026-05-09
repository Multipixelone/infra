{
  configurations.nixos.iot.module = {
    services.home-assistant = {
      enable = true;
      extraComponents = [
        "mobile_app"
        "webhook"
        "default_config"
      ];
      config.homeassistant.name = "Home";
    };
  };
}
