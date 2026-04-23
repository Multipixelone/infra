{ config, lib, ... }:
let
  inherit (config.flake.meta) repo;
  inherit (config) caches;

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
      substituters = ${substituters}
      trusted-public-keys = ${trustedKeys}
    '';

  evalFilename = "eval.yaml";
  evalFilePath = ".github/workflows/${evalFilename}";
  buildFilename = "build.yaml";
  buildFilePath = ".github/workflows/${buildFilename}";
  nixpkgsAgeFilename = "nixpkgs-age-badge.yaml";
  nixpkgsAgeFilePath = ".github/workflows/${nixpkgsAgeFilename}";

  evalWorkflowName = "Eval";
  buildWorkflowName = "Build";

  ids = {
    jobs = {
      getCheckNames = "get-check-names";
      check = "check";
      checkNixos = "check-nixos";
    };
    steps.getCheckNames = "get-check-names";
    outputs = {
      jobs.getCheckNames = "checks";
      jobs.getCheckNamesNixos = "checks-nixos";
      steps.getCheckNames = "checks";
      steps.getCheckNamesNixos = "checks-nixos";
    };
  };

  matrixParam = "checks";

  nixArgs = "--accept-flake-config --allow-import-from-derivation";

  runner = {
    name = "ubuntu-latest";
    system = "x86_64-linux";
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
      uses = "wimpysworld/nothing-but-nix@main";
      "with" = {
        hatchet-protocol = "holster";
      };
    };
    checkout = {
      uses = "actions/checkout@v4";
      "with".submodules = true;
    };
    nixInstaller = {
      uses = "DeterminateSystems/nix-installer-action@v22";
      "with" = {
        flakehub = false;
        extra-conf = mkNixConf;
      };
    };
    createAtticNetrc = {
      name = "Create attic netrc";
      run = ''
        sudo mkdir -p /etc/nix /etc/determinate
        echo "machine attic-cache.fly.dev login automated password ''${{ secrets.ATTIC_KEY }}" | sudo tee /etc/nix/netrc > /dev/null
        echo '{"authentication":{"additionalNetrcSources":["/etc/nix/netrc"]}}' | sudo tee /etc/determinate/config.json > /dev/null
        git config --global url."https://''${{ secrets.GH_TOKEN_FOR_UPDATES }}@github.com".insteadOf https://github.com
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

        [![Eval](https://img.shields.io/github/actions/workflow/status/${owner}/${name}/eval.yaml?branch=${defaultBranch}&style=for-the-badge&logo=github&label=eval&color=a6e3a1&labelColor=313244&logoColor=cdd6f4)](${repoUrl}/actions/workflows/eval.yaml?query=branch%3A${defaultBranch})
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
      files.files = [
        {
          path_ = evalFilePath;
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
          path_ = buildFilePath;
          drv = pkgs.writers.writeJSON "gh-actions-workflow-build.yaml" {
            name = buildWorkflowName;
            on.push = { };
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
                  steps.removeUnusedSoftware
                  steps.checkout
                  steps.createAtticNetrc
                  steps.nixInstaller
                  steps.installSshKey
                  steps.loginToAttic
                  {
                    id = ids.steps.getCheckNames;
                    run = ''
                      all_checks="$(nix ${nixArgs} eval --json .#checks.${runner.system} --apply builtins.attrNames)"
                      echo "${ids.outputs.steps.getCheckNames}=$(echo "$all_checks" | jq -c '[.[] | select(startswith("configurations/nixos/") | not)]')" >> $GITHUB_OUTPUT
                      echo "${ids.outputs.steps.getCheckNamesNixos}=$(echo "$all_checks" | jq -c '[.[] | select(startswith("configurations/nixos/"))]')" >> $GITHUB_OUTPUT
                    '';
                  }
                ];
              };

              ${ids.jobs.check} = {
                continue-on-error = true;
                needs = ids.jobs.getCheckNames;
                runs-on = runner.name;
                timeout-minutes = 350;
                strategy = {
                  fail-fast = false;
                  max-parallel = 5;
                  matrix.${matrixParam} =
                    "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNames}) }}";
                };
                steps = [
                  steps.removeUnusedSoftware
                  steps.checkout
                  steps.createAtticNetrc
                  steps.nixInstaller
                  steps.installSshKey
                  steps.loginToAttic
                  {
                    run = ''
                      nix run github:Mic92/nix-fast-build -- \
                        --skip-cached \
                        --no-nom \
                        --attic-cache system \
                        -j 1 \
                        --eval-workers 1 \
                        --eval-max-memory-size 2048 \
                        --retries 2 \
                        --no-link \
                        --flake '.#checks.${runner.system}."''${{ matrix.${matrixParam} }}"'
                    '';
                  }
                ];
              };

              ${ids.jobs.checkNixos} = {
                continue-on-error = true;
                needs = [
                  ids.jobs.getCheckNames
                  ids.jobs.check
                ];
                runs-on = runner.name;
                timeout-minutes = 350;
                strategy = {
                  fail-fast = false;
                  max-parallel = 5;
                  matrix.${matrixParam} =
                    "\${{ fromJson(needs.${ids.jobs.getCheckNames}.outputs.${ids.outputs.jobs.getCheckNamesNixos}) }}";
                };
                steps = [
                  steps.removeUnusedSoftware
                  steps.checkout
                  steps.createAtticNetrc
                  steps.nixInstaller
                  steps.installSshKey
                  steps.loginToAttic
                  {
                    run = ''
                      nix run github:Mic92/nix-fast-build -- \
                        --skip-cached \
                        --no-nom \
                        --attic-cache system \
                        -j 1 \
                        --eval-workers 1 \
                        --eval-max-memory-size 2048 \
                        --retries 2 \
                        --no-link \
                        --flake '.#checks.${runner.system}."''${{ matrix.${matrixParam} }}"'
                    '';
                  }
                ];
              };
            };
          };
        }
        {
          path_ = nixpkgsAgeFilePath;
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
      ];

      treefmt.settings.global.excludes = [
        evalFilePath
        buildFilePath
        nixpkgsAgeFilePath
        ciFilePath
      ];
    };
}
