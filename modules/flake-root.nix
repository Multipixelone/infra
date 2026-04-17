{
  inputs,
  ...
}:
{
  flake-file.inputs.flake-root.url = "github:srid/flake-root";
  imports = [
    inputs.flake-root.flakeModule
  ];

  perSystem =
    {
      config,
      ...
    }:
    {
      make-shells.default = {
        inputsFrom = [
          config.flake-root.devShell
        ];
      };
    };
}
