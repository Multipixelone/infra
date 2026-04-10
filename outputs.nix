inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } {
  systems = [ "x86_64-linux" ];

  imports = [
    inputs.flake-file.flakeModules.default
    (inputs.import-tree ./modules)
  ];

  _module.args.rootPath = ./.;
}
