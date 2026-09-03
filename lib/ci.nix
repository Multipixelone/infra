# Forge-neutral CI data, rendered into GitHub Actions YAML by modules/ci.nix
# and into Forgejo Actions YAML by modules/ci/forgejo.nix.
#
# Everything here is dialect-independent. Forgejo aliases the `github` context
# to its own and sets $GITHUB_OUTPUT alongside $FORGEJO_OUTPUT, so the
# `${{ ... }}` expressions and the output-file redirects below are byte-for-byte
# valid on both forges. What is *not* portable — runner labels, `uses:`
# resolution, the Ubuntu-runner preparation steps, job-level continue-on-error —
# stays in the per-forge modules.
{ lib }:
rec {
  # `configurations/nixos/iso` builds an installer image nothing deploys, so it
  # only earns a runner slot when someone is about to reinstall a host.
  dispatchOnlyChecks = [ "configurations/nixos/iso" ];

  # Job, step and output identifiers. Shared so `needs.<job>.outputs.<name>`
  # cannot drift between the two renderings.
  ids = {
    jobs = {
      getCheckNames = "get-check-names";
      check = "check";
      checkNixos = "check-nixos";
      checkAarch64 = "check-aarch64";
    };
    steps.getCheckNames = "get-check-names";
    outputs = {
      jobs.getCheckNames = "checks";
      jobs.getCheckNamesNixos = "checks-nixos";
      jobs.getCheckNamesAarch64 = "checks-aarch64";
      steps.getCheckNames = "checks";
      steps.getCheckNamesNixos = "checks-nixos";
      steps.getCheckNamesAarch64 = "checks-aarch64";
    };
  };

  matrixParam = "checks";

  nixArgs = "--accept-flake-config";

  # Splits the flake's check set into the three matrices the build workflow
  # fans out over, on $GITHUB_OUTPUT.
  #
  # Still jq rather than a `nix eval --apply` filter: jq is preinstalled on the
  # GitHub runners, and the self-hosted runner carries it explicitly in
  # hostPackages, so keeping one implementation keeps the two forges' generated
  # workflows textually identical in this step.
  mkCheckNamesScript =
    {
      system,
      aarch64System ? null,
    }:
    ''
      all_checks="$(nix ${nixArgs} eval --json .#checks.${system} --apply builtins.attrNames)"
      nixos_checks="$(echo "$all_checks" | jq -c '[.[] | select(startswith("configurations/nixos/"))]')"
      if [ "''${{ github.event_name }}" != workflow_dispatch ]; then
        nixos_checks="$(echo "$nixos_checks" | jq -c --argjson skip '${builtins.toJSON dispatchOnlyChecks}' 'map(select(IN($skip[]) | not))')"
      fi
      echo "${ids.outputs.steps.getCheckNames}=$(echo "$all_checks" | jq -c '[.[] | select(startswith("configurations/nixos/") | not)]')" >> $GITHUB_OUTPUT
      echo "${ids.outputs.steps.getCheckNamesNixos}=$nixos_checks" >> $GITHUB_OUTPUT
    ''
    # Each fragment keeps its own trailing newline so the concatenation is
    # identical whether or not the aarch64 leg is appended.
    + lib.optionalString (aarch64System != null) ''
      aarch64_checks="$(nix ${nixArgs} eval --json .#checks.${aarch64System} --apply builtins.attrNames)"
      echo "${ids.outputs.steps.getCheckNamesAarch64}=$aarch64_checks" >> $GITHUB_OUTPUT
    '';

  # Shared nix-fast-build invocation for one check-matrix cell.
  #
  # There is deliberately no `|| retry-without-attic` fallback: it fired on ANY
  # non-zero exit, so an eval error or a failed NixOS assertion was reported as
  # "Attic upload failed" and then re-run to produce the identical failure.
  # `--retries 2` already covers the transient cache errors it was meant to.
  mkNixFastBuild =
    {
      flakeSystem,
      jobs ? 2,
      evalWorkers ? 2,
      evalMaxMemory ? 2048,
    }:
    ''
      nix run github:Mic92/nix-fast-build -- \
        --skip-cached \
        --no-nom \
        --attic-cache system \
        -j ${toString jobs} \
        --eval-workers ${toString evalWorkers} \
        --eval-max-memory-size ${toString evalMaxMemory} \
        --retries 2 \
        --no-link \
        --flake '.#checks.${flakeSystem}."''${{ matrix.${matrixParam} }}"'
    '';
}
