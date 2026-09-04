{ lib, ... }:
{
  perSystem =
    { self', system, ... }:
    let
      # Spelled out rather than derived. The predicate this replaces was
      # `lib.meta.availableOn hostPlatform drv && (builtins.tryEval drv.drvPath).success`,
      # and forcing every package's drvPath made the *names* of the check set
      # cost 51 s and 2.7 GB to compute — against 0.23 s and 132 MB for the
      # same `builtins.attrNames` over `packages`. Every matrix cell used to
      # pay that bill in full just to look up its own attribute, and the
      # consolidated evaluator in modules/ci/forgejo.nix would re-pay it after
      # every nix-eval-jobs worker restart. Nothing else about this filter was
      # load-bearing: on x86_64 it excluded nothing at all.
      #
      # beets-plugins pulls in essentia-extractor (x86_64/i686 only) — a
      # transitively restricted dependency that only surfaces when drvPath is
      # forced, which is what the old tryEval was for. izotope and
      # plexamp-headless are x86_64-only binaries.
      #
      # The cost of hardcoding: a newly unportable package now fails its own
      # aarch64 check instead of quietly leaving the check set. That leg is
      # advisory (modules/ci.nix), so the failure is the signal you want —
      # but it does mean this list has to be extended by hand.
      unavailable = {
        aarch64-linux = [
          "beets-plugins"
          "izotope"
          "plexamp-headless"
        ];
      };
      excluded = unavailable.${system} or [ ];
    in
    {
      checks =
        self'.packages
        |> lib.filterAttrs (name: _: !(builtins.elem name excluded))
        |> lib.mapAttrs' (name: drv: lib.nameValuePair "packages/${name}" drv);
    };
}
