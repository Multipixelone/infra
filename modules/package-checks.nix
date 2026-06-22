{ lib, ... }:
{
  perSystem =
    { self', pkgs, ... }:
    {
      # Only expose a package as a check on systems where it can actually be
      # built. This keeps the aarch64 check set to the portable subset and
      # avoids surfacing packages that are explicitly x86_64-only. The
      # tryEval also catches packages whose own meta.platforms is
      # unrestricted but that pull in a transitively platform-restricted
      # dependency (e.g. beets-plugins -> essentia-extractor, x86_64/i686
      # only) — forcing drvPath is what trips nixpkgs' checkMeta assertion
      # in that case, not the top-level availableOn check.
      checks =
        self'.packages
        |> lib.filterAttrs (
          _: drv:
          lib.meta.availableOn pkgs.stdenv.hostPlatform drv
          && (builtins.tryEval drv.drvPath).success
        )
        |> lib.mapAttrs' (name: drv: lib.nameValuePair "packages/${name}" drv);
    };
}
