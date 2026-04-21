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
      substituters = ${substituters}
      trusted-public-keys = ${trustedKeys}
    '';

  filename = "check.yaml";
  filePath = ".github/workflows/${filename}";
  nixpkgsAgeFilename = "nixpkgs-age-badge.yaml";
  nixpkgsAgeFilePath = ".github/workflows/${nixpkgsAgeFilename}";
  nixpkgsAgeBadgeJsonPath = ".github/badges/nixpkgs-age.json";

  workflowName = "Check";

  ids = {
    jobs = {
      getCheckNames = "get-check-names";
      check = "check";
    };
    steps.getCheckNames = "get-check-names";
    outputs = {
      jobs.getCheckNames = "checks";
      steps.getCheckNames = "checks";
    };
  };

  matrixParam = "checks";

  nixArgs = "--accept-flake-config";

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
      uses = "nixbuild/nix-quick-install-action@v34";
      "with" = {
        nix_version = "2.31.2";
        nix_conf = mkNixConf;
      };
    };
    createAtticNetrc = {
      name = "Create attic netrc";
      run = ''
        sudo mkdir -p /etc/nix
        echo "machine attic-cache.fly.dev password ''${{ secrets.ATTIC_KEY }}" | sudo tee /etc/nix/netrc > /dev/null
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
    ci-badges = ''
      <div align="center">

      <a href="https://github.com/${repo.owner}/${repo.name}/actions/workflows/${filename}?query=branch%3A${repo.defaultBranch}">
        <img alt="CI status" src="https://img.shields.io/${repo.forge}/actions/workflow/status/${repo.owner}/${repo.name}/${filename}?style=for-the-badge&branch=${repo.defaultBranch}&label=${workflowName}">
      </a>
      <a href="https://github.com/${repo.owner}/${repo.name}/actions/workflows/${nixpkgsAgeFilename}?query=branch%3A${repo.defaultBranch}">
        <img alt="nixpkgs commit age" src="https://img.shields.io/endpoint?style=for-the-badge&url=https%3A%2F%2Fraw.githubusercontent.com%2F${repo.owner}%2F${repo.name}%2F${repo.defaultBranch}%2F.github%2Fbadges%2Fnixpkgs-age.json">
      </a>

      </div>
    '';
    github-actions = ''
      ## Running checks on GitHub Actions

      Running this repository's flake checks on GitHub Actions is merely a bonus
      and possibly more of a liability.

      Workflow files are generated using
      [the _files_ flake-parts module](https://github.com/mightyiam/files).

      For better visibility, a job is spawned for each flake check.
      This is done dynamically.

    ''
    + (
      assert steps ? nothingButNix;
      ''
        To prevent runners from running out of space,
        The action [Nothing but Nix](https://github.com/marketplace/actions/nothing-but-nix)
        is used.

      ''
    )
    + ''
      See [`modules/ci.nix`](modules/ci.nix).

    '';
  };

  perSystem =
    { pkgs, ... }:
    {
      files.files = [
        {
          path_ = filePath;
          drv = pkgs.writers.writeJSON "gh-actions-workflow-check.yaml" {
            name = workflowName;
            on = {
              push = { };
              workflow_call = { };
            };
            jobs = {
              ${ids.jobs.getCheckNames} = {
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

              ${ids.jobs.check} = {
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
                  # steps.pushToAttic
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
            permissions.contents = "write";
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
                  run = ''
                    set -euo pipefail

                    nixpkgs_node="$(jq -r '.nodes.root.inputs.nixpkgs // empty' flake.lock)"

                    if [ -z "$nixpkgs_node" ]; then
                      echo "Could not find root nixpkgs input in flake.lock"
                      exit 1
                    fi

                    rev="$(jq -r --arg node "$nixpkgs_node" '.nodes[$node].locked.rev // empty' flake.lock)"

                    if [ -z "$rev" ]; then
                      echo "Could not find nixpkgs revision for root input ($nixpkgs_node) in flake.lock"
                      exit 1
                    fi

                    commit_date="$(curl -fsSL "https://api.github.com/repos/NixOS/nixpkgs/commits/$rev" | jq -r '.commit.committer.date // empty')"

                    if [ -z "$commit_date" ]; then
                      echo "Could not resolve nixpkgs commit date for revision: $rev"
                      exit 1
                    fi

                    commit_ts="$(date -u -d "$commit_date" +%s)"
                    now_ts="$(date -u +%s)"
                    age_days="$(( (now_ts - commit_ts) / 86400 ))"

                    color="brightgreen"
                    if [ "$age_days" -gt 7 ]; then color="green"; fi
                    if [ "$age_days" -gt 14 ]; then color="yellowgreen"; fi
                    if [ "$age_days" -gt 30 ]; then color="yellow"; fi
                    if [ "$age_days" -gt 60 ]; then color="orange"; fi
                    if [ "$age_days" -gt 90 ]; then color="red"; fi

                    mkdir -p .github/badges
                    jq -n \
                      --arg message "''${age_days}d" \
                      --arg color "$color" \
                      '{schemaVersion: 1, label: "nixpkgs age", message: $message, color: $color}' \
                      > ${nixpkgsAgeBadgeJsonPath}
                  '';
                }
                {
                  name = "Commit badge JSON when changed";
                  run = ''
                    set -euo pipefail

                    if git diff --quiet -- ${nixpkgsAgeBadgeJsonPath}; then
                      echo "No badge update needed"
                      exit 0
                    fi

                    git config user.name "github-actions[bot]"
                    git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
                    git add ${nixpkgsAgeBadgeJsonPath}
                    git commit -m "chore(ci): update nixpkgs age badge"
                    git push
                  '';
                }
              ];
            };
          };
        }
        {
          path_ = nixpkgsAgeBadgeJsonPath;
          drv = pkgs.writeText "nixpkgs-age.json" (
            (builtins.toJSON {
              schemaVersion = 1;
              label = "nixpkgs age";
              message = "unknown";
              color = "lightgrey";
            })
            + "\n"
          );
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
        filePath
        nixpkgsAgeFilePath
        nixpkgsAgeBadgeJsonPath
        ciFilePath
      ];
    };
}
