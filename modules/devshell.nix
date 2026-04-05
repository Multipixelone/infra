{ inputs, config, ... }:
{
  imports = [ inputs.make-shell.flakeModules.default ];

  perSystem = {
    make-shells.default.name = config.flake.meta.repo.name;
  };
}
