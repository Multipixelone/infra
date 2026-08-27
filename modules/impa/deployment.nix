{
  configurations.nixos.impa.deployment = {
    targetHost = "192.168.6.50";
    targetUser = "root";
    tags = [ "edge" ];
  };
}
