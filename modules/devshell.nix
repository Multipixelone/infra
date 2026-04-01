{ inputs, ... }:
{
  imports = [ inputs.make-shell.flakeModules.default ];

  perSystem =
    { config, ... }:
    {
      make-shells.default.name = config.flake.meta.repo.name;
    };
}
