{
  inputs,
  ...
}:
{
  flake.modules.nixos.pc =
    { config, lib, ... }:
    {
      # Consumed by the per-host wg-quick interfaces (link, zelda), which the
      # ISO does not import — so only the declaration needs the guard here.
      age.secrets = lib.mkIf (!config.infra.installerMedia) {
        "wireguard".file = "${inputs.secrets}/wireguard/${config.networking.hostName}.age";
        "psk".file = "${inputs.secrets}/wireguard/psk.age";
      };
      networking.firewall.trustedInterfaces = [
        "wg0"
      ];
    };
}
