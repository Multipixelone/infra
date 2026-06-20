{ lib, ... }:
{
  perSystem =
    { self', pkgs, ... }:
    {
      # Only expose a package as a check on systems where it can actually be
      # built. This keeps the aarch64 check set to the portable subset and
      # avoids surfacing packages that are explicitly x86_64-only.
      checks =
        self'.packages
        |> lib.filterAttrs (_: drv: lib.meta.availableOn pkgs.stdenv.hostPlatform drv)
        |> lib.mapAttrs' (name: drv: lib.nameValuePair "packages/${name}" drv);
    };
}
