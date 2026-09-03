{ lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };
  inherit (ci) ids matrixParam;

  buildFilePath = ".forgejo/workflows/build.yaml";

  # The label the runner registers is `nix:host` (modules/link/forgejo-runner.nix);
  # the `:host` suffix selects native execution and `runs-on` names only the
  # label itself. There is no ubuntu-latest here, and deliberately no alias for
  # one — a GitHub-shaped label would invite copy-pasted workflows that assume a
  # container and an Ubuntu filesystem.
  runner = {
    name = "nix";
    system = "x86_64-linux";
  };

  steps = {
    # Fully qualified on purpose. A bare `actions/checkout@v4` is resolved
    # against the instance's DEFAULT_ACTIONS_URL, so pinning the host keeps the
    # workflow working regardless of how that is configured server-side.
    # data.forgejo.org mirrors checkout; it does not mirror the two GitHub
    # actions below, which is why those carry a github.com URL.
    checkout = {
      uses = "https://data.forgejo.org/actions/checkout@v4";
      "with".submodules = true;
    };

    # inputs.secrets is git+ssh://git@github.com/Multipixelone/nix-secrets.git
    # and is needed at eval time, so every `nix eval .#checks` fails without a
    # key that can read it. Same deploy key the GitHub workflows use.
    installSshKey = {
      name = "Install SSH key";
      uses = "https://github.com/webfactory/ssh-agent@v0.9.0";
      "with".ssh-private-key = "\${{ secrets.SSH_PRIVATE_KEY }}";
    };

    # link's system nix.conf carries `!include /run/agenix/nix`, which holds the
    # GitHub access token — but that file is 440 tunnel:users and the runner's
    # DynamicUser is in neither, so the include is unavailable to its nix
    # client. Without this the private prem-tweet input
    # (git+https://github.com/Multipixelone/prem-tweet.git) 404s and link's own
    # toplevel cannot build.
    #
    # Only the GIT_CONFIG_* form is used here, not `git config --global`: Nix's
    # git fetcher spawns git with a sanitized HOME, so a --global rewrite is
    # invisible to it. $GITHUB_OUTPUT's sibling $GITHUB_ENV exports these to
    # every later step in the job.
    githubTokenRewrite = {
      name = "Authenticate private GitHub inputs";
      run = ''
        {
          echo "GIT_CONFIG_COUNT=1"
          echo "GIT_CONFIG_KEY_0=url.https://x-access-token:''${{ secrets.GH_TOKEN_FOR_UPDATES }}@github.com/.insteadOf"
          echo "GIT_CONFIG_VALUE_0=https://github.com/"
        } >> "$GITHUB_ENV"

        # Appended, not assigned: the runner unit already exports NIX_CONFIG
        # with max-jobs and cores, and a plain NIX_CONFIG= here would silently
        # drop those and let CI build at full width. Heredoc form because the
        # value is multi-line.
        {
          echo "NIX_CONFIG<<__NIX_CONFIG_EOF__"
          printf '%s\n' "''${NIX_CONFIG:-}"
          echo "access-tokens = github.com=''${{ secrets.GH_TOKEN_FOR_UPDATES }}"
          echo "__NIX_CONFIG_EOF__"
        } >> "$GITHUB_ENV"
      '';
    };

    loginToAttic = {
      name = "Login to attic";
      run = ''
        nix run nixpkgs#attic-client login fly https://attic-cache.fly.dev ''${{ secrets.ATTIC_KEY }}
      '';
    };
  };

  # link is a 5800X with a warm store, so it gets more than the hosted runners'
  # two workers — but stays inside ci.slice's memory ceiling.
  fastBuild = ci.mkNixFastBuild {
    flakeSystem = runner.system;
    jobs = 4;
    evalWorkers = 4;
  };
in
{
  perSystem =
    { pkgs, ... }:
    {
      # Note there is no aarch64 job: link is x86_64 and this repo sets no
      # boot.binfmt.emulatedSystems anywhere, so the portable-package matrix
      # stays on GitHub's free native ARM runners.
      files.file.${buildFilePath}.source = pkgs.writers.writeJSON "forgejo-actions-workflow-build.yaml" {
        name = "Build";
        on = {
          push = { };
          workflow_dispatch = { };
        };
        # One runner, so a superseded push should not sit behind the run it
        # obsoletes. Supported since Forgejo v14.0.
        concurrency = {
          group = "build-\${{ github.ref }}";
          cancel-in-progress = true;
        };
        jobs = {
          ${ids.jobs.getCheckNames} = {
            runs-on = runner.name;
            outputs = {
              ${ids.outputs.jobs.getCheckNames} =
                "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNames} }}";
              ${ids.outputs.jobs.getCheckNamesNixos} =
                "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNamesNixos} }}";
            };
            steps = [
              steps.checkout
              steps.installSshKey
              steps.githubTokenRewrite
              {
                id = ids.steps.getCheckNames;
                # No aarch64System: nothing here can build it.
                run = ci.mkCheckNamesScript { inherit (runner) system; };
              }
            ];
          };

          ${ids.jobs.check} = {
            needs = ids.jobs.getCheckNames;
            runs-on = runner.name;
            timeout-minutes = 180;
            strategy = {
              fail-fast = false;
              matrix.${matrixParam} =
                "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNames}) }}";
            };
            steps = [
              steps.checkout
              steps.installSshKey
              steps.githubTokenRewrite
              steps.loginToAttic
              {
                name = "nix-fast-build";
                # Step level, not job level: Forgejo ignores
                # continue-on-error on a job, so the advisory-package
                # behaviour the GitHub workflow gets from the job key has to
                # ride on the step here or a flaky package turns the run red.
                continue-on-error = true;
                run = fastBuild;
              }
            ];
          };

          ${ids.jobs.checkNixos} = {
            needs = ids.jobs.getCheckNames;
            runs-on = runner.name;
            # Both Forgejo and the runner otherwise cap a job at 3h, which
            # would kill this matrix at the same wall-clock every time. The
            # server side is actions.timeout.DEFAULT in modules/impa/forgejo.nix
            # and the runner side is settings.runner.timeout in
            # modules/link/forgejo-runner.nix; all three have to agree.
            timeout-minutes = 350;
            strategy = {
              fail-fast = false;
              matrix.${matrixParam} =
                "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNamesNixos}) }}";
            };
            steps = [
              steps.checkout
              steps.installSshKey
              steps.githubTokenRewrite
              steps.loginToAttic
              {
                name = "nix-fast-build";
                run = fastBuild;
              }
            ];
          };
        };
      };

      treefmt.settings.global.excludes = [ buildFilePath ];
    };
}
