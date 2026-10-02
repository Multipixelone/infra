{ lib }:
{
  # Read only local, merged unit declarations. This must never read another
  # host configuration: exporter and onFailure configuration use it too.
  optedInUnits =
    config:
    let
      inherit (config) systemd;
      units =
        lib.concatMap (kind: builtins.attrValues (systemd.${kind} or { })) [
          "services"
          "sockets"
          "timers"
          "paths"
          "targets"
          "slices"
        ]
        ++ (systemd.mounts or [ ])
        ++ (systemd.automounts or [ ]);
    in
    lib.sort builtins.lessThan (
      lib.unique (
        map (unit: unit.name) (
          builtins.filter (
            unit: (unit.enable or true) && lib.elem "notify-telegram@%n.service" (unit.onFailure or [ ])
          ) units
        )
      )
    );

  unitRegex =
    units:
    lib.concatStringsSep "|" (
      map (
        unit:
        if lib.hasSuffix "@.service" unit then
          "${lib.escapeRegex (lib.removeSuffix "@.service" unit)}@.+\\.service"
        else
          lib.escapeRegex unit
      ) units
    );
}
