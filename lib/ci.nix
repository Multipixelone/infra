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

  # Which checks are allowed to turn a run red, as `case` glob patterns.
  #
  # The forge job builds every check in one nix-fast-build and derives its own
  # exit code from the per-check ledger, so this is a real per-check policy —
  # something neither job-level nor step-level `continue-on-error` can express.
  # It replaces the blanket step-level `continue-on-error` the advisory matrix
  # used to carry, under which `files:*` and `treefmt` could not fail a run at
  # all. (That was not hypothetical: the `treefmt` check was failing on `main`
  # and nothing reported it.)
  #
  # `configurations/*` gates because it is the deployment gate — and the glob
  # deliberately covers `configurations/home-manager/*` too, which the old
  # `startswith("configurations/nixos/")` split dropped into the advisory lane.
  # `files:*` gates because a stale generated file means the committed workflow
  # no longer matches its source. Everything else — packages, home-manager
  # profiles, the service-publication contract — reports Forgejo's `warning`
  # state instead: visibly not green, but not a merge blocker.
  gatingCheckPatterns = [
    "configurations/*"
    "files:*"
    "treefmt"
  ];

  # Job, step and output identifiers. Shared so `needs.<job>.outputs.<name>`
  # cannot drift between the two renderings.
  ids = {
    jobs = {
      getCheckNames = "get-check-names";
      check = "check";
      checkAarch64 = "check-aarch64";
    };
    steps.getCheckNames = "get-check-names";
    outputs = {
      jobs.getCheckNamesAarch64 = "checks-aarch64";
      steps.getCheckNamesAarch64 = "checks-aarch64";
    };
  };

  matrixParam = "checks";

  nixArgs = "--accept-flake-config";

  # Emits the aarch64 check-name matrix on $GITHUB_OUTPUT.
  #
  # Only GitHub Actions still needs this: the forge builds its whole check set
  # in one job (modules/ci/forgejo.nix) and no longer fans out into a matrix,
  # so the native x86_64 leg this helper used to serve is gone.
  #
  # Still jq rather than a `nix eval --apply` filter: jq is preinstalled on the
  # GitHub runners and the self-hosted runner carries it explicitly in
  # hostPackages.
  mkCheckNamesScript = { aarch64System }: ''
    aarch64_checks="$(nix ${nixArgs} eval --json .#checks.${aarch64System} --apply builtins.attrNames)"
    echo "${ids.outputs.steps.getCheckNamesAarch64}=$aarch64_checks" >> $GITHUB_OUTPUT
  '';

  # A nix-eval-jobs `--select` function that drops the dispatch-only checks.
  #
  # This is what lets the forge build everything in ONE invocation without
  # inventing a second flake output: `checks` itself keeps every attribute, so
  # a local `nix flake check` is unchanged, and only the CI evaluation sees the
  # reduced set. nix-fast-build forwards `--select` straight to nix-eval-jobs,
  # which applies the function to the attribute the flake fragment selected.
  mkSelectExpr =
    skip: if skip == [ ] then "cs: cs" else "cs: builtins.removeAttrs cs ${builtins.toJSON skip}";

  # Shared nix-fast-build invocation.
  #
  # There is deliberately no `|| retry-without-attic` fallback: it fired on ANY
  # non-zero exit, so an eval error or a failed NixOS assertion was reported as
  # "Attic upload failed" and then re-run to produce the identical failure.
  # `--retries 2` already covers the transient cache errors it was meant to.
  #
  # `--no-link` is gone: it is a deprecated no-op in nix-fast-build 2.0.2, which
  # does not create out-links by default. `--no-fold` is deliberately NOT
  # passed — the `::group::`/`::endgroup::` markers it would suppress are what
  # give the consolidated job a per-attribute collapsible log, which is the
  # only per-check drill-down Forgejo can render.
  mkNixFastBuild =
    {
      flakeSystem,
      # `attr` builds a single matrix cell (GitHub's aarch64 leg); `select`
      # builds a whole check set in one process (the forge). `select` is
      # interpolated as a raw shell fragment, not quoted here — the forge
      # passes a variable reference because the expression depends on
      # `github.event_name`, which is only known inside the job.
      attr ? null,
      select ? null,
      jobs ? 2,
      evalWorkers ? 2,
      evalMaxMemory ? 2048,
      streamJsonLines ? false,
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
    ''
    + lib.optionalString streamJsonLines "  --stream-json-lines \\\n"
    + lib.optionalString (select != null) "  --select ${select} \\\n"
    + (
      if attr != null then
        "  --flake '.#checks.${flakeSystem}.\"${attr}\"'\n"
      else
        "  --flake '.#checks.${flakeSystem}'\n"
    );
}
