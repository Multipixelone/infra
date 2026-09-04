{ config, lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };
  inherit (ci) ids matrixParam nixArgs;
  inherit (config.flake.meta) owner repo;

  buildFilePath = ".forgejo/workflows/build.yaml";
  updateLockFilePath = ".forgejo/workflows/update-lock.yaml";

  # The forge this repo is authoritative on. Also spelled out in
  # modules/impa/forgejo.nix (the instance) and modules/link/forgejo-runner.nix
  # (the runner's forge URL); those are NixOS modules, where `config` is a host
  # rather than the flake, so there is no shared attribute to inherit from
  # without threading flake.meta through specialArgs.
  forge = {
    domain = "git.finnrut.is";
    # The forge account, which is not the GitHub account in repo.owner.
    owner = owner.username;
    inherit (repo) name;
  };

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

  # Every job in every workflow here needs the same three things before it can
  # evaluate the flake at all: a worktree, a key for the private `git+ssh`
  # secrets input, and a token for the private `git+https` inputs.
  sharedPreSteps = [
    steps.checkout
    steps.installSshKey
    steps.githubTokenRewrite
  ];

  # link is a 5800X with a warm store, so it gets more than the hosted runners'
  # two workers — but stays inside ci.slice's memory ceiling.
  fastBuild = ci.mkNixFastBuild {
    flakeSystem = runner.system;
    jobs = 4;
    evalWorkers = 4;
  };

  updateBranch = "update_flake_lock_action";
in
{
  perSystem =
    { pkgs, ... }:
    {
      files.file = {
        # Note there is no aarch64 job: link is x86_64 and this repo sets no
        # boot.binfmt.emulatedSystems anywhere, so the portable-package matrix
        # stays on GitHub's free native ARM runners.
        ${buildFilePath}.source = pkgs.writers.writeJSON "forgejo-actions-workflow-build.yaml" {
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
              steps = sharedPreSteps ++ [
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
              steps = sharedPreSteps ++ [
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
              steps = sharedPreSteps ++ [
                steps.loginToAttic
                {
                  name = "nix-fast-build";
                  run = fastBuild;
                }
              ];
            };
          };
        };

        # The scheduled lock bump, moved off GitHub Actions so the forge is the
        # only thing that writes to this repo. While both forges ran it, each
        # opened its own pull request from the same branch name and the GitHub
        # copy had to be merged back by hand.
        ${updateLockFilePath}.source =
          pkgs.writers.writeJSON "forgejo-actions-workflow-update-lock.yaml"
            {
              name = "Update flake inputs";
              on = {
                workflow_dispatch = { };
                # Forgejo only honours `schedule` on the default branch, which
                # is where this is generated, so the cadence matches the GitHub
                # workflow it replaces: every third day.
                schedule = [ { cron = "0 0 1-31/3 * *"; } ];
              };
              jobs.update-flake-lock = {
                runs-on = runner.name;
                # Nothing here builds a host closure — `flake update` is pure
                # input resolution and the addon generator is one small
                # derivation — so this stays well inside the runner's slice
                # even while a build matrix is running beside it.
                timeout-minutes = 60;
                steps = sharedPreSteps ++ [
                  {
                    name = "Update flake.lock";
                    run = "nix ${nixArgs} flake update";
                  }
                  {
                    # Mirror `just update`: keep the pinned Firefox addons in
                    # lockstep with the flake bump so the automated PR doesn't
                    # drift from a manual update.
                    name = "Update Firefox addons";
                    run = ''
                      nix run 'git+https://git.sr.ht/~rycee/mozilla-addons-to-nix' \
                        --option allow-import-from-derivation true \
                        -- pkgs/firefox-addons/addons.json pkgs/firefox-addons/generated.nix
                    '';
                  }
                  {
                    # peter-evans/create-pull-request is GitHub-API-only, so
                    # the branch and the pull request are made by hand here.
                    #
                    # No build step first, on purpose: pushing the branch
                    # triggers the Build workflow, which is the real gate.
                    # That is also why this pushes with a PAT rather than the
                    # run's automatic token — Forgejo suppresses workflow
                    # triggers for pushes made with the automatic token, so
                    # the bumped branch would never get built.
                    name = "Open pull request";
                    env = {
                      FORGE_USER = forge.owner;
                      FORGE_TOKEN = "\${{ secrets.FORGE_TOKEN }}";
                    };
                    run = ''
                      set -euo pipefail

                      paths="flake.lock pkgs/firefox-addons/generated.nix"

                      if git diff --quiet -- $paths; then
                        echo "Inputs and addon pins are already current; nothing to open."
                        exit 0
                      fi

                      git config user.name  "${owner.name}"
                      git config user.email "${owner.email}"

                      git switch -C "${updateBranch}"
                      git add -- $paths
                      git commit -m "⚙️ bump flake.lock"

                      # checkout@v4 leaves an Authorization header pinned to the
                      # run's automatic token in the local config, and it wins
                      # over any credential helper. Drop it so the PAT below is
                      # what actually authenticates the push.
                      git config --local --unset-all \
                        'http.https://${forge.domain}/.extraheader' || true

                      # Via a credential file rather than a URL so the token
                      # never lands in git's argv on a machine the owner also
                      # uses interactively.
                      creds="$(mktemp)"
                      trap 'rm -f "$creds"' EXIT
                      printf 'https://%s:%s@${forge.domain}\n' "$FORGE_USER" "$FORGE_TOKEN" > "$creds"
                      git config --local credential.helper "store --file=$creds"

                      git push --force origin "HEAD:refs/heads/${updateBranch}"

                      body="$(mktemp)"
                      code="$(curl -sS -o "$body" -w '%{http_code}' \
                        -X POST "https://${forge.domain}/api/v1/repos/${forge.owner}/${forge.name}/pulls" \
                        -H "Authorization: token $FORGE_TOKEN" \
                        -H 'Content-Type: application/json' \
                        -d '${
                          builtins.toJSON {
                            head = updateBranch;
                            base = repo.defaultBranch;
                            title = "chore: update flake.lock";
                            body = "Scheduled bump of `flake.lock` and the generated Firefox addon pins.";
                            assignees = [ owner.username ];
                          }
                        }')"

                      case "$code" in
                        201)
                          echo "Opened $(jq -r '.html_url' "$body")"
                          ;;
                        409)
                          # The previous run's pull request is still open and
                          # now points at the branch we just force-pushed,
                          # which is the intended end state.
                          echo "Pull request already open; updated its head instead."
                          ;;
                        *)
                          echo "Unexpected HTTP $code from the pulls API:" >&2
                          cat "$body" >&2
                          exit 1
                          ;;
                      esac
                    '';
                  }
                ];
              };
            };
      };

      treefmt.settings.global.excludes = [
        buildFilePath
        updateLockFilePath
      ];
    };
}
