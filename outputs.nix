inputs:
inputs.flake-parts.lib.mkFlake { inherit inputs; } {
  # `systems` is declared in modules/systems.nix (single source of truth:
  # x86_64-linux for all hosts + aarch64-linux for portable packages).
  imports = [
    inputs.flake-file.flakeModules.default
    (inputs.import-tree ./modules)
  ];

  _module.args.rootPath = inputs.self;
}
