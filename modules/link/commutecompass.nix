{ inputs, ... }:
{
  flake-file.inputs.commutecompass = {
    url = "github:Multipixelone/commutecompass";
    inputs.nixpkgs.follows = "nixpkgs";
    inputs.flake-utils.follows = "flake-utils";
  };

  configurations.nixos.link.module =
    { config, ... }:
    {
      imports = [ inputs.commutecompass.nixosModules.default ];

      age.secrets."commutecompass" = {
        file = "${inputs.secrets}/commutecompass/tokens.age";
        owner = "commutecompass";
        group = "commutecompass";
        mode = "0400";
      };

      services.commutecompass = {
        enable = true;
        configFile = "${inputs.secrets}/commutecompass/config.toml";
        venuesFile = "${inputs.secrets}/commutecompass/known_venues.yaml";
        environmentFile = config.age.secrets."commutecompass".path;
      };
    };
}
