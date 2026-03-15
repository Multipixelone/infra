{ inputs, ... }:
{
  imports = [ inputs.wrappers.flakeModules.wrappers ];
  perSystem =
    { pkgs, ... }:
    {
      wrappers.control_type = "build";
    };
}
