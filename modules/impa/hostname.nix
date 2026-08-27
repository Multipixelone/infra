{ lib, ... }:
{
  configurations.nixos.impa.module = {
    networking = {
      hostName = "impa";
      domain = lib.mkForce "hosts.nyc.finnrut.is";
    };
  };
}
