{
  inputs,
  ...
}:
{
  configurations.nixos.marin.module =
    { config, ... }:
    {
      # TODO: grocy data on marin has no backup — marin lacks the pc/backup
      # role, and link's old /srv/grocy backup was dropped when grocy moved.
      age.secrets."grocy".file = "${inputs.secrets}/grocy.age";
      virtualisation.oci-containers.containers.barcode-buddy = {
        autoStart = false;
        image = "f0rc3/barcodebuddy:latest";
        ports = [ "7575:80" ];
        environment.Grocy__BaseUrl = "localhost";
        volumes = [
          "barcode-buddy:/config"
        ];
        environmentFiles = [
          config.age.secrets."grocy".path
        ];
      };
      services.grocy = {
        enable = false;
        hostName = "192.168.5.21";
        nginx.enableSSL = false;
      };
    };
}
