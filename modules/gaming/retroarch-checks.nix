{ config, lib, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    lib.optionalAttrs (system == "x86_64-linux") (
      let
        host = config.flake.nixosConfigurations.link;
        home = host.config.home-manager.users.${config.flake.meta.owner.username};
        wrappers = builtins.filter (
          package: lib.hasPrefix "retroarch-with-cores-" package.name
        ) home.home.packages;
        retroarch = lib.head wrappers;
        azahar = lib.findFirst (core: core.core == "azahar") null retroarch.cores;
        # HM uses the host's global pkgs; use that exact instance so host-local
        # overlays cannot make this assertion compare unrelated derivations.
        required = map (name: host.pkgs.libretro.${name}) config.flake.saveSyncInventory.requiredCores;
      in
      {
        # Inspect link's actual selected package, not an independently assembled
        # test wrapper. Loading the ABI below uses no content and never calls
        # retro_init, so it cannot discover or mutate the real user directory.
        checks.retroarch-link-azahar =
          assert lib.assertMsg (
            builtins.length wrappers == 1
          ) "link must install exactly one RetroArch wrapper";
          assert lib.assertMsg (azahar != null) "link's RetroArch is missing Azahar";
          assert lib.assertMsg (builtins.all (
            core: builtins.elem core.drvPath (map (c: c.drvPath) retroarch.cores)
          ) required) "link lost a policy-required RetroArch core";
          assert lib.assertMsg (
            builtins.length retroarch.cores == builtins.length required + 1
          ) "link must retain the policy cores and add only Azahar";
          pkgs.runCommand "retroarch-link-azahar"
            {
              nativeBuildInputs = [ pkgs.python3 ];
            }
            ''
              export HOME="$TMPDIR/home"
              mkdir -p "$HOME"
              test -x ${retroarch}/bin/retroarch
              # libretroCore is the core directory, not the shared-library file.
              test -f ${retroarch}${azahar.libretroCore}/azahar_libretro.so
              test "$(readlink -f ${retroarch}${azahar.libretroCore}/azahar_libretro.so)" = \
                "$(readlink -f ${azahar}${azahar.libretroCore}/azahar_libretro.so)"
              test -f ${pkgs.libretro-core-info}/share/retroarch/cores/azahar_libretro.info
              python3 ${./tests/azahar-core-identity.py} \
                ${retroarch}${azahar.libretroCore}/azahar_libretro.so ${lib.escapeShellArg azahar.version} > "$out"
            '';
      }
    );
}
