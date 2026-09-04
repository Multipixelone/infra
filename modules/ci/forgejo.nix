{ config, lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };
  inherit (ci) ids nixArgs;
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
    #
    # Done in-shell rather than with webfactory/ssh-agent, which is what the
    # GitHub workflows use. On a host runner that action is a poor fit: it
    # writes to ~/.ssh, and this runner's HOME is a single directory shared by
    # every job, so two concurrent jobs (capacity = 2) race on the same
    # known_hosts. Writing to a per-job temp directory and exporting
    # GIT_SSH_COMMAND has no shared state, leaves no agent process behind, and
    # drops a github.com fetch that data.forgejo.org does not mirror.
    #
    # GIT_SSH_COMMAND rather than an agent socket because Nix's git fetcher
    # spawns git with a sanitized HOME; an explicit -i path is unaffected by
    # that, and $GITHUB_ENV carries it to every later step in the job.
    installSshKey = {
      name = "Install SSH key";
      env.SSH_PRIVATE_KEY = "\${{ secrets.SSH_PRIVATE_KEY }}";
      run = ''
        set -euo pipefail

        dir="$(mktemp -d)"
        chmod 700 "$dir"
        # printf, not echo: the key must end in a newline or ssh rejects it as
        # malformed, and a secret that already ends in one is unharmed by the
        # extra blank line.
        printf '%s\n' "$SSH_PRIVATE_KEY" > "$dir/id"
        chmod 600 "$dir/id"

        # Same trust-on-first-use as the action this replaces.
        ssh-keyscan github.com > "$dir/known_hosts" 2>/dev/null

        echo "GIT_SSH_COMMAND=ssh -i $dir/id -o IdentitiesOnly=yes -o UserKnownHostsFile=$dir/known_hosts" >> "$GITHUB_ENV"
      '';
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

  # One invocation for the whole check set, so the ~50 s of scaffolding a
  # matrix cell used to pay — checkout, key material, an attic login, fetching
  # nix-fast-build and evaluating the entire flake to resolve ONE attribute —
  # is paid once instead of 86 times.
  #
  # Two eval workers at 3 GiB rather than the old four at 2 GiB: the ceiling
  # that matters is ci.slice's MemoryHigh=8G, and 2×3 GiB sits under it where
  # the old 4×2 GiB sat exactly on it — twice over, since `capacity = 2` let
  # two of these run at once. Consolidation removes the second evaluator
  # outright. Fewer, larger workers also restart less often, and a restart
  # re-pays the whole-set evaluation.
  #
  # `-j 2` multiplies with the runner unit's own `NIX_CONFIG = max-jobs = 3`
  # (modules/link/forgejo-runner.nix), so up to six derivations build at once.
  fastBuild = ci.mkNixFastBuild {
    flakeSystem = runner.system;
    jobs = 2;
    evalWorkers = 2;
    evalMaxMemory = 3072;
    streamJsonLines = true;
    # Resolved inside the job: the dispatch-only set depends on the event.
    select = "\"$CI_SELECT\"";
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
          # One job, not a matrix.
          #
          # The fan-out existed to pace the work across GitHub-hosted runners.
          # On a self-hosted runner with `capacity = 2` it is pure loss: 86
          # cells serialise two at a time, and each one evaluates the whole
          # flake just to look up its own attribute. Per-check reporting is
          # what the matrix was really buying, and commit statuses provide
          # that without a runner slot per check — a cached check now gets a
          # green light too, where before it cost a full job to discover
          # there was nothing to do.
          jobs.${ids.jobs.check} = {
            runs-on = runner.name;
            # Under the 480 minutes that both the runner
            # (settings.runner.timeout in modules/link/forgejo-runner.nix) and
            # the server (actions.timeout.DEFAULT in modules/impa/forgejo.nix)
            # allow, so the job's own timeout fires first and Forgejo records a
            # clean timeout instead of reaping a zombie task ten minutes later.
            timeout-minutes = 420;
            env = {
              FORGE_API = "https://${forge.domain}/api/v1";
              FORGE_REPO = "\${{ github.repository }}";
              FORGE_SHA = "\${{ github.sha }}";
              # The same PAT the update-lock workflow pushes with. The run's
              # automatic token also carries repo write, but this one is known
              # to work against this instance's API and needs no experiment.
              FORGE_TOKEN = "\${{ secrets.FORGE_TOKEN }}";
              # Every status points at this one job. Per-check drill-down comes
              # from nix-fast-build's `::group::` markers instead, which the
              # runner rewrites to `##[group]` and Forgejo's log viewer folds.
              FORGE_TARGET_URL = "\${{ github.server_url }}/\${{ github.repository }}/actions/runs/\${{ github.run_number }}";
            };
            steps = sharedPreSteps ++ [
              steps.loginToAttic
              {
                name = "Seed pending statuses";
                # One extra whole-flake `nix eval`, and worth it twice over: it
                # puts a pending dot on every check before the first build
                # starts, and it is the ground truth the final sweep needs — a
                # failure to evaluate the root emits no per-attribute rows at
                # all, only a non-zero exit, so without a seeded list those
                # checks would be indistinguishable from checks that passed.
                run = ''
                  set -euo pipefail

                  # Resolved once, into $GITHUB_ENV, so the pipe consumer in the
                  # next step is a plain exec rather than a third `nix run`.
                  CI_STATUS_BIN="$(nix ${nixArgs} build --no-link --print-out-paths .#forgejo-check-status)/bin/forgejo-check-status"
                  echo "CI_STATUS_BIN=$CI_STATUS_BIN" >> "$GITHUB_ENV"

                  # The seeded list and the evaluator's --select have to agree,
                  # or a check is either seeded and never resolved or resolved
                  # and never seeded. Both come off dispatchOnlyChecks here.
                  if [ "''${{ github.event_name }}" = workflow_dispatch ]; then
                    skip='[]'
                    echo 'CI_SELECT=${ci.mkSelectExpr [ ]}' >> "$GITHUB_ENV"
                  else
                    skip='${builtins.toJSON ci.dispatchOnlyChecks}'
                    echo 'CI_SELECT=${ci.mkSelectExpr ci.dispatchOnlyChecks}' >> "$GITHUB_ENV"
                  fi

                  nix ${nixArgs} eval --json .#checks.${runner.system} --apply builtins.attrNames \
                    | jq -c --argjson skip "$skip" 'map(select(IN($skip[]) | not))' \
                    | "$CI_STATUS_BIN" seed
                '';
              }
              {
                name = "nix-fast-build";
                # No `continue-on-error` anywhere any more. It could only ever
                # make the WHOLE step advisory, which is why `files:*` and
                # `treefmt` could not fail a run — and why `treefmt` sat red on
                # main unnoticed. The verdict now comes from the per-check
                # ledger in the next step, against lib/ci.nix's
                # gatingCheckPatterns.
                #
                # stdout is JSON Lines and nothing else; the human-readable
                # build log is on stderr and still reaches the job log.
                run = ''
                  set -uo pipefail

                  rc=0
                  # removeSuffix: the shared recipe ends in a newline, which
                  # would put the pipe on a line of its own — a syntax error,
                  # not a pipeline.
                  ${lib.removeSuffix "\n" fastBuild} | "$CI_STATUS_BIN" consume || rc=$?
                  echo "NFB_RC=$rc" >> "$GITHUB_ENV"
                '';
              }
              {
                name = "Report verdict";
                # `always()` so a failed build still reconciles its statuses
                # rather than leaving them pending. `''${NFB_RC:-1}`: if the
                # step above died before writing it, that must not read as
                # success.
                "if" = "always()";
                run = ''"$CI_STATUS_BIN" finish "''${NFB_RC:-1}"'';
              }
            ];
          };
        };

        # The scheduled lock bump, moved off GitHub Actions so the forge is the
        # only thing that writes to this repo. While both forges ran it, each
        # opened its own pull request from the same branch name and the GitHub
        # copy had to be merged back by hand.
        ${updateLockFilePath}.source = pkgs.writers.writeJSON "forgejo-actions-workflow-update-lock.yaml" {
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
