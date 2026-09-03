{ config, lib, ... }:
let
  inherit (config.flake.meta) repo;
  inherit (config) caches;

  # Forge-neutral job/step identifiers and the two shared script recipes.
  # modules/ci/forgejo.nix renders the same data for the self-hosted runner, so
  # anything both forges must agree on lives there rather than here.
  ci = import ../lib/ci.nix { inherit lib; };
  inherit (ci)
    dispatchOnlyChecks
    ids
    matrixParam
    nixArgs
    ;

  # Heavy check-nixos closures (crane, tree-sitter-grammars, etc.) were
  # driving runner disk usage to ~99% full, which kills the GitHub-hosted
  # runner agent itself ("runner has received a shutdown signal", exit
  # 143) rather than failing the build cleanly. min-free/max-free make
  # the daemon GC unreferenced store paths as disk fills up instead of
  # running it to 0 bytes.
  mkNixConf =
    let
      substituters = lib.concatStringsSep " " (map (c: c.url) caches);
      trustedKeys = lib.concatStringsSep " " (map (c: c.key) caches);
    in
    ''
      fallback = true
      http-connections = 25
      max-substitution-jobs = 16
      connect-timeout = 15
      stalled-download-timeout = 15
      download-attempts = 100
      accept-flake-config = true
      netrc-file = /etc/nix/netrc
      access-tokens = github.com=''${{ secrets.GH_TOKEN_FOR_UPDATES }}
      substituters = ${substituters}
      trusted-public-keys = ${trustedKeys}
      min-free = 5368709120
      max-free = 16106127360
    '';

  evalFilename = "eval.yaml";
  evalFilePath = ".github/workflows/${evalFilename}";
  buildFilename = "build.yaml";
  buildFilePath = ".github/workflows/${buildFilename}";
  nixpkgsAgeFilename = "nixpkgs-age-badge.yaml";
  nixpkgsAgeFilePath = ".github/workflows/${nixpkgsAgeFilename}";
  updateLockFilename = "update-lock.yml";
  updateLockFilePath = ".github/workflows/${updateLockFilename}";

  evalWorkflowName = "Eval";
  buildWorkflowName = "Build";
  updateLockWorkflowName = "Update flake inputs";

  runner = {
    name = "ubuntu-latest";
    system = "x86_64-linux";
  };

  # Native ARM runner (free on public repos). aarch64 has no host toplevels —
  # the check set is the portable package subset (see modules/package-checks.nix).
  aarch64Runner = {
    name = "ubuntu-24.04-arm";
    system = "aarch64-linux";
  };

  steps = {
    removeUnusedSoftware = {
      name = "Remove unused toolkits";
      run = ''
        sudo rm -rf $AGENT_TOOLSDIRECTORY
        sudo rm -rf /usr/local/.ghcup
        sudo rm -rf /usr/local/share/powershell
        sudo rm -rf /usr/local/share/chromium
        sudo rm -rf /usr/local/lib/node_modules
        sudo rm -rf /usr/local/lib/heroku
        sudo rm -rf /var/lib/docker/overlay2
        sudo rm -rf /home/linuxbrew
        sudo rm -rf /home/runner/.rustup
        sudo rm -rf /etc/ssh/sshd_config.d/50-cloud-init.conf
      '';
    };
    nothingButNix = {
      # Reclaims ~20-60 GB of runner disk for the Nix store. Must run BEFORE the
      # Nix installer (it asserts /nix does not yet exist). "rampage" is the most
      # aggressive protocol (removes preinstalled language toolchains + Docker/Snap
      # /APT cruft); safe here because every CI step runs through Nix. Only wired
      # into the heavy build jobs — the get-check-names eval jobs still use `jq`
      # and don't need the space.
      uses = "wimpysworld/nothing-but-nix@main";
      "with" = {
        hatchet-protocol = "rampage";
        # nix-quick-install-action sets up /nix without sudo, so it needs the
        # mount owned by the runner user. (Determinate used sudo, hence the old
        # quick->deter switch; this edict is what lets us go back to quick.)
        nix-permission-edict = true;
      };
    };
    checkout = {
      uses = "actions/checkout@v4";
      "with".submodules = true;
    };
    # Upstream Nix via nix-quick-install — NOT the Determinate installer. The
    # latter ships determinate-nixd, whose fetcher SIGABRTs ("bit out of range
    # 0 - FD_SETSIZE on fd_set") on GitHub runners because the daemon raises its
    # own RLIMIT_NOFILE to the runner's huge hard limit and then calls select().
    # Plain nix-daemon doesn't do that, so this path has no FD_SETSIZE crash.
    nixInstaller = {
      uses = "nixbuild/nix-quick-install-action@v35";
      "with".nix_conf = mkNixConf;
    };
    createAtticNetrc = {
      name = "Create attic netrc";
      run = ''
        sudo mkdir -p /etc/nix /etc/determinate
        echo "machine attic-cache.fly.dev login automated password ''${{ secrets.ATTIC_KEY }}" | sudo tee /etc/nix/netrc > /dev/null
        echo '{"authentication":{"additionalNetrcSources":["/etc/nix/netrc"]}}' | sudo tee /etc/determinate/config.json > /dev/null
        # `x-access-token:<pat>` form, not `<pat>@` — GitHub accepts a bare
        # token as the username only for CLASSIC PATs; a fine-grained PAT must
        # arrive as the PASSWORD or the clone 404s as "Repository not found".
        git config --global url."https://x-access-token:''${{ secrets.GH_TOKEN_FOR_UPDATES }}@github.com".insteadOf https://github.com
        # Nix's git fetcher (private `git+https://` inputs, e.g. prem-tweet)
        # spawns git with a sanitized HOME, so the --global rewrite above is
        # invisible to it. GIT_CONFIG_* env vars ride through the environment
        # instead; $GITHUB_ENV exports them to every later step in the job.
        {
          echo "GIT_CONFIG_COUNT=1"
          echo "GIT_CONFIG_KEY_0=url.https://x-access-token:''${{ secrets.GH_TOKEN_FOR_UPDATES }}@github.com/.insteadOf"
          echo "GIT_CONFIG_VALUE_0=https://github.com/"
        } >> "$GITHUB_ENV"
      '';
    };
    installSshKey = {
      name = "Install SSH key";
      uses = "webfactory/ssh-agent@v0.9.0";
      "with".ssh-private-key = "\${{ secrets.SSH_PRIVATE_KEY }}";
    };
    loginToAttic = {
      name = "Login to attic";
      run = ''
        nix run nixpkgs#attic-client login fly https://attic-cache.fly.dev ''${{ secrets.ATTIC_KEY }}
      '';
    };
    pushToAttic = {
      name = "Push to attic";
      continue-on-error = true;
      run = ''
        nix run nixpkgs#attic-client push system result -j 3
      '';
    };
  };

  # The hosted runners are 2-core/7 GB, hence the conservative job and
  # eval-worker counts; the self-hosted runner passes its own.
  mkNixFastBuild = flakeSystem: ci.mkNixFastBuild { inherit flakeSystem; };

  ciFilename = "ci.yml";
  ciFilePath = ".github/workflows/${ciFilename}";
  # ciWorkflowName = "CI";
  # ciRunner = "ubuntu-24.04";

  # machines = [
  #   {
  #     host = "minish";
  #     platform = "x86-64-linux";
  #   }
  #   {
  #     host = "link";
  #     platform = "x86-64-linux";
  #   }
  #   {
  #     host = "marin";
  #     platform = "x86-64-linux";
  #   }
  # ];

in
{
  text.readme.parts = {
    ci-badges =
      let
        inherit (config.flake.meta.repo) owner name defaultBranch;
        repoUrl = "https://github.com/${owner}/${name}";
      in
      # markdown
      ''
        <div align="center">

        [![Eval](https://img.shields.io/github/actions/workflow/status/${owner}/${name}/${evalFilename}?branch=${defaultBranch}&style=for-the-badge&logo=github&label=eval&color=a6e3a1&labelColor=313244&logoColor=cdd6f4)](${repoUrl}/actions/workflows/${evalFilename}?query=branch%3A${defaultBranch})
        [![Build](https://img.shields.io/github/actions/workflow/status/${owner}/${name}/${buildFilename}?branch=${defaultBranch}&style=for-the-badge&logo=github&label=build&color=89b4fa&labelColor=313244&logoColor=cdd6f4)](${repoUrl}/actions/workflows/${buildFilename}?query=branch%3A${defaultBranch})
        [![nixpkgs age](https://img.shields.io/endpoint?style=for-the-badge&url=https%3A%2F%2Fgist.githubusercontent.com%2FMultipixelone%2F6b2a2a693da36488ff3a34274a2047fa%2Fraw%2Fnixpkgs-age.json&logo=nixos&labelColor=313244&logoColor=cdd6f4)](${repoUrl}/actions/workflows/nixpkgs-age-badge.yaml?query=branch%3A${defaultBranch})

        </div>
      '';
    github-actions = ''
      ## Running checks on GitHub Actions

      This repository runs checks using GitHub Actions and pushes the results to an Attic cache.

      For better visibility, a job is spawned for each flake check.
      This is done dynamically.

    ''
    + ''
      See [`modules/ci.nix`](modules/ci.nix).

    '';
  };

  perSystem =
    { pkgs, ... }:
    {
      files.file =
        [
          {
            path = evalFilePath;
            drv = pkgs.writers.writeJSON "gh-actions-workflow-eval.yaml" {
              name = evalWorkflowName;
              on = {
                push = { };
                workflow_call = {
                  outputs.${ids.outputs.jobs.getCheckNames} = {
                    description = "JSON array of check names";
                    value = "\${{ jobs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNames} }}";
                  };
                };
              };
              jobs.${ids.jobs.getCheckNames} = {
                runs-on = runner.name;
                outputs.${ids.outputs.jobs.getCheckNames} =
                  "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNames} }}";
                steps = [
                  steps.removeUnusedSoftware
                  steps.checkout
                  steps.createAtticNetrc
                  steps.nixInstaller
                  steps.installSshKey
                  steps.loginToAttic
                  {
                    id = ids.steps.getCheckNames;
                    run = ''
                      checks="$(nix ${nixArgs} eval --json .#checks.${runner.system} --apply builtins.attrNames)"
                      echo "${ids.outputs.steps.getCheckNames}=$checks" >> $GITHUB_OUTPUT
                    '';
                  }
                ];
              };
            };
          }
          {
            path = buildFilePath;
            drv = pkgs.writers.writeJSON "gh-actions-workflow-build.yaml" {
              name = buildWorkflowName;
              on = {
                push = { };
                workflow_dispatch = { };
              };
              jobs = {
                ${ids.jobs.getCheckNames} = {
                  runs-on = runner.name;
                  outputs = {
                    ${ids.outputs.jobs.getCheckNames} =
                      "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNames} }}";
                    ${ids.outputs.jobs.getCheckNamesNixos} =
                      "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNamesNixos} }}";
                    ${ids.outputs.jobs.getCheckNamesAarch64} =
                      "\${{ steps.${ids.steps.getCheckNames}.outputs.${ids.outputs.steps.getCheckNamesAarch64} }}";
                  };
                  steps = [
                    steps.removeUnusedSoftware
                    steps.checkout
                    steps.createAtticNetrc
                    steps.nixInstaller
                    steps.installSshKey
                    steps.loginToAttic
                    {
                      id = ids.steps.getCheckNames;
                      run = ci.mkCheckNamesScript {
                        inherit (runner) system;
                        aarch64System = aarch64Runner.system;
                      };
                    }
                  ];
                };

                ${ids.jobs.check} = {
                  # Package cells only. Several are genuinely flaky (upstream
                  # fetchers, IFD), so they stay advisory; the host toplevels in
                  # check-nixos are the ones allowed to turn the run red.
                  continue-on-error = true;
                  needs = ids.jobs.getCheckNames;
                  runs-on = runner.name;
                  timeout-minutes = 180;
                  strategy = {
                    fail-fast = false;
                    max-parallel = 5;
                    matrix.${matrixParam} =
                      "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNames}) }}";
                  };
                  steps = [
                    steps.nothingButNix
                    steps.checkout
                    steps.createAtticNetrc
                    steps.nixInstaller
                    steps.installSshKey
                    steps.loginToAttic
                    {
                      run = mkNixFastBuild runner.system;
                    }
                  ];
                };

                ${ids.jobs.checkNixos} = {
                  # No continue-on-error: a host toplevel that fails to build is
                  # the one thing this workflow exists to catch. fail-fast below
                  # keeps the sibling hosts running anyway, so a red cell is
                  # per-host rather than a cancelled matrix.
                  #
                  # Deliberately NOT gated on the `check` job: queueing 7 host
                  # closures behind a ~74-entry package matrix at max-parallel 5
                  # delayed the first host cell by 3.5h and got link and zelda
                  # cancelled at the timeout without ever reaching attic.
                  needs = ids.jobs.getCheckNames;
                  runs-on = runner.name;
                  timeout-minutes = 350;
                  strategy = {
                    fail-fast = false;
                    max-parallel = 5;
                    matrix.${matrixParam} =
                      "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNamesNixos}) }}";
                  };
                  steps = [
                    steps.nothingButNix
                    steps.checkout
                    steps.createAtticNetrc
                    steps.nixInstaller
                    steps.installSshKey
                    steps.loginToAttic
                    {
                      run = mkNixFastBuild runner.system;
                    }
                  ];
                };

                ${ids.jobs.checkAarch64} = {
                  # Same package subset as `check`, on ARM: portability
                  # information, not a deployment gate. Stays advisory.
                  continue-on-error = true;
                  needs = ids.jobs.getCheckNames;
                  runs-on = aarch64Runner.name;
                  timeout-minutes = 180;
                  strategy = {
                    fail-fast = false;
                    max-parallel = 5;
                    matrix.${matrixParam} =
                      "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNamesAarch64}) }}";
                  };
                  steps = [
                    steps.nothingButNix
                    steps.checkout
                    steps.createAtticNetrc
                    steps.nixInstaller
                    steps.installSshKey
                    steps.loginToAttic
                    {
                      run = mkNixFastBuild aarch64Runner.system;
                    }
                  ];
                };
              };
            };
          }
          {
            # Generated rather than hand-written so the scheduled lock bump
            # shares the eval/build credential setup. The hand-written version
            # installed Determinate Nix, which could not fetch the private
            # `git+https://` inputs however the token was presented, and every
            # scheduled run from 2026-08-19 onwards died on a prem-tweet 404.
            path = updateLockFilePath;
            drv = pkgs.writers.writeJSON "gh-actions-workflow-update-lock.yaml" {
              name = updateLockWorkflowName;
              on = {
                workflow_dispatch = { };
                schedule = [ { cron = "0 0 1-31/3 * *"; } ];
              };
              jobs.update-flake-lock = {
                runs-on = runner.name;
                steps = [
                  steps.removeUnusedSoftware
                  steps.checkout
                  steps.createAtticNetrc
                  steps.nixInstaller
                  steps.installSshKey
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
                    # No build step here on purpose: pushing the branch triggers
                    # the Build workflow, which is the real gate.
                    name = "Create pull request";
                    uses = "peter-evans/create-pull-request@v8";
                    "with" = {
                      token = "\${{ secrets.GH_TOKEN_FOR_UPDATES }}";
                      branch = "update_flake_lock_action";
                      title = "chore: update flake.lock";
                      commit-message = "⚙️ bump flake.lock";
                      assignees = repo.owner;
                      labels = "automated";
                      add-paths = ''
                        flake.lock
                        pkgs/firefox-addons/generated.nix
                      '';
                    };
                  }
                ];
              };
            };
          }
          {
            path = nixpkgsAgeFilePath;
            drv = pkgs.writers.writeJSON "gh-actions-workflow-nixpkgs-age-badge.yaml" {
              name = "Nixpkgs age badge";
              on = {
                workflow_dispatch = { };
                schedule = [ { cron = "0 */12 * * *"; } ];
                push.paths = [
                  "flake.lock"
                  "${nixpkgsAgeFilePath}"
                ];
              };
              permissions.contents = "read";
              jobs.update-nixpkgs-age-badge = {
                runs-on = "ubuntu-latest";
                steps = [
                  {
                    uses = "actions/checkout@v4";
                    "with" = {
                      ref = repo.defaultBranch;
                      fetch-depth = 0;
                    };
                  }
                  {
                    name = "Generate nixpkgs age badge JSON";
                    env.GH_TOKEN = "\${{ github.token }}";
                    run = ''
                      set -euo pipefail

                      out="$RUNNER_TEMP/nixpkgs-age.json"

                      # Find the nixpkgs node name used by root, even if it's a list or a string
                      nixpkgs_node="$(
                        jq -r '
                          .nodes.root.inputs.nixpkgs
                          | if type=="array" then .[0] else . end
                          // empty
                        ' flake.lock
                      )"

                      if [ -z "$nixpkgs_node" ]; then
                        echo "Could not find root nixpkgs input in flake.lock"
                        cat >"$out" <<'JSON'
                      {"schemaVersion":1,"label":"nixpkgs age","message":"unknown","color":"lightgrey"}
                      JSON
                        exit 0
                      fi

                      rev="$(jq -r --arg node "$nixpkgs_node" '.nodes[$node].locked.rev // empty' flake.lock)"
                      if [ -z "$rev" ]; then
                        echo "Could not find nixpkgs revision for root input ($nixpkgs_node) in flake.lock"
                        cat >"$out" <<'JSON'
                      {"schemaVersion":1,"label":"nixpkgs age","message":"unknown","color":"lightgrey"}
                      JSON
                        exit 0
                      fi

                      # Query nixpkgs commit date from GitHub
                      commit_date="$(
                        gh api "repos/NixOS/nixpkgs/commits/$rev" \
                          --jq '.commit.committer.date // empty' \
                        || true
                      )"

                      if [ -z "$commit_date" ]; then
                        echo "Could not resolve nixpkgs commit date for revision: $rev"
                        cat >"$out" <<'JSON'
                      {"schemaVersion":1,"label":"nixpkgs age","message":"unknown","color":"lightgrey"}
                      JSON
                        exit 0
                      fi

                      # Compute age in days
                      commit_ts="$(date -u -d "$commit_date" +%s)"
                      now_ts="$(date -u +%s)"
                      age_days="$(( (now_ts - commit_ts) / 86400 ))"

                      # Pick a color (catppuccin mocha)
                      color="a6e3a1"
                      if [ "$age_days" -gt 5 ]; then color="94e2d5"; fi
                      if [ "$age_days" -gt 10 ]; then color="f9e2af"; fi
                      if [ "$age_days" -gt 20 ]; then color="fab387"; fi
                      if [ "$age_days" -gt 30 ]; then color="f38ba8"; fi
                      if [ "$age_days" -gt 40 ]; then color="eba0ac"; fi

                      jq -n \
                        --arg label "nixpkgs age" \
                        --arg message "''${age_days}d" \
                        --arg color "$color" \
                        '{schemaVersion:1,label:$label,message:$message,color:$color}' >"$out"

                      echo "Wrote $out:"
                      cat "$out"
                    '';
                  }
                  {
                    name = "Publish badge JSON to gist";
                    env = {
                      GH_TOKEN = "\${{ secrets.GH_TOKEN_FOR_UPDATES }}";
                      GIST_ID = "6b2a2a693da36488ff3a34274a2047fa";
                    };
                    run = ''
                      set -euo pipefail
                      gh gist edit "$GIST_ID" -a "$RUNNER_TEMP/nixpkgs-age.json"
                    '';
                  }
                ];
              };
            };
          }
          # {
          #   path_ = ciFilePath;
          #   drv = pkgs.writers.writeJSON "gh-actions-workflow-ci.yml" {
          #     name = ciWorkflowName;
          #     on = {
          #       push.branches = [ "main" ];
          #       pull_request = { };
          #       workflow_dispatch = { };
          #     };
          #     jobs = {
          #       checks = {
          #         uses = "./${filePath}";
          #         secrets = "inherit";
          #       };
          #       build = {
          #         name = "build machines";
          #         needs = "checks";
          #         runs-on = ciRunner;
          #         strategy = {
          #           fail-fast = false;
          #           matrix.machine = machines;
          #         };
          #         steps = [
          #           ciSteps.mkdirNix
          #           steps.removeUnusedSoftware
          #           ciSteps.maximizeDiskSpace
          #           ciSteps.chownNix
          #           ciSteps.checkout
          #           steps.createAtticNetrc
          #           ciSteps.nixInstaller
          #           steps.installSshKey
          #           steps.loginToAttic
          #           ciSteps.buildSystem
          #           steps.pushToAttic
          #         ];
          #       };
          #     };
          #   };
          # }
        ]
        |> map (file: lib.nameValuePair file.path { source = file.drv; })
        |> builtins.listToAttrs;

      treefmt.settings.global.excludes = [
        evalFilePath
        buildFilePath
        nixpkgsAgeFilePath
        updateLockFilePath
        ciFilePath
      ];
    };
}
