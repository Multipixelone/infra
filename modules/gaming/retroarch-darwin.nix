# RetroArch on hylia comes from Homebrew, not nixpkgs.
#
# nixpkgs marks `retroarch-bare` BROKEN on aarch64-darwin -- evaluating it trips
# the broken assert -- so the `pkgs.retroarch.withCores` projection in
# modules/gaming/retroarch.nix has no darwin counterpart and the `hylia` client
# is `managed = false` for that reason. The cask owns the app bundle; cores are
# fetched once through RetroArch's own Online Updater and held to the Core
# policy by the generated validation report rather than by the closure.
#
# `retroarch-metal` rather than `retroarch`: the plain cask is the OpenGL build,
# and Apple has deprecated OpenGL. Both exist upstream.
{
  configurations.darwin.hylia.module.homebrew.casks = [ "retroarch-metal" ];
}
