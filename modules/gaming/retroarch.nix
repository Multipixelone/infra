# The installed core set is a PROJECTION of the Core policy, never a second
# list beside it.
#
# The trap this avoids is quiet and expensive: a hand-written `withCores` list
# drifts from modules/gaming/saves/policy.nix the moment the policy moves a
# system to a different core, and RetroArch does not complain. It loads
# whatever core the playlist or the "DETECT" association points at, writes a
# battery save in THAT core's format, and the file lands at the same path the
# prescribed core would have used -- so the save looks synced, looks current,
# and cannot be opened by the core every other client is running. That is
# exactly how a GBA save written by gpSP becomes unreadable to mGBA while both
# machines report success. Deriving the list from
# `saveSyncInventory.requiredCores` makes "the policy prescribes it" and "the
# binary can load it" the same statement.
#
# `requiredCores` already folds in `corePolicy.extraCores`, so the retired
# cores that WROTE the saves now on disk (gpSP, bsnes) stay installed for the
# migration without being prescribed for anything.
{ config, ... }:
{
  # libretro-snes9x and libretro-genesis-plus-gx are both
  # `unfreeRedistributable` in nixpkgs -- Snes9x for its non-commercial clause,
  # Genesis Plus GX for the same. This list cannot be derived from
  # `requiredCores`: knowing a core is unfree means forcing its meta, which
  # means having a `pkgs`, which is the very thing this option configures. So
  # it is written out, and a newly-prescribed unfree core fails the build with
  # nixpkgs' own "unfree" error naming the attribute to add here.
  nixpkgs.config.allowUnfreePackages = [
    "libretro-snes9x"
    "libretro-genesis-plus-gx"
  ];

  flake.modules.homeManager.gaming =
    { pkgs, ... }:
    let
      # `withCores` hands the callback `pkgs.libretro` itself, so a policy core
      # name is an attribute path into that set. A missing name must be a hard
      # evaluation failure and not a silently shorter list: an absent core is
      # the failure mode above, and `cores.${name} or null` would produce it.
      coreOf =
        cores: name:
        cores.${name} or (throw ''
          retroarch: the Core policy prescribes the libretro core "${name}",
          which this nixpkgs does not provide as pkgs.libretro.${name}.

          Either the attribute was renamed upstream or the policy has a typo.
          Fix the `core` value in modules/gaming/saves/policy.nix, or add the
          package -- do NOT drop it from the list: a client missing its
          prescribed core writes battery saves in another core's format to the
          same path, and nothing reports an error.

          Available: nix eval --raw 'nixpkgs#libretro' --apply builtins.attrNames
        '');

      retroarch-cores = pkgs.retroarch.withCores (
        cores: map (coreOf cores) config.flake.saveSyncInventory.requiredCores
      );
    in
    {
      home.packages = [
        retroarch-cores
      ];
    };
}
