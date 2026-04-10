{ inputs, config, ... }:
{
  flake-file.inputs.make-shell = {
    url = "github:nicknovitski/make-shell";
    inputs.flake-compat.follows = "flake-compat";
  };
  imports = [ inputs.make-shell.flakeModules.default ];

  perSystem = {
    make-shells.default.name = config.flake.meta.repo.name;
  };
}
