{
  config,
  lib,
  inputs,
  rootPath,
  ...
}:
let
  # One immutable store copy of the reviewed skill tree, shared by every
  # deployment target so OpenCode and OpenClaw always see identical content.
  skillSource = builtins.path {
    path = rootPath + /docs/omniroute/skills/omniroute;
    name = "omniroute-skill";
  };

  # A single non-recursive link per target: the new child sits beside the
  # recursively linked parent skills (programs.opencode.skills) without
  # touching them, and needs neither `force` nor `recursive`.
  module = hmArgs: {
    xdg.configFile."opencode/skills/omniroute" = lib.mkIf hmArgs.config.programs.opencode.enable {
      source = skillSource;
    };
  };

  linkModule = {
    home.file.".openclaw/workspace/skills/omniroute".source = skillSource;
  };

  skillDir = "docs/omniroute/skills/omniroute";

  # Byte-preserved upstream files whose SHA256s are pinned in provenance.json.
  # Formatters must never rewrite them; the locally authored SKILL.md,
  # operating-boundaries.md and provenance.json stay formatted normally.
  preservedFiles = map (rel: "${skillDir}/${rel}") [
    "LICENSE"
    "references/omni-mcp.md"
    "references/omni-usage-logs.md"
    "references/omni-context-rtk.md"
    "references/omni-providers/reference.md"
    "references/omni-providers/references/endpoints.md"
  ];

  opencodeTarget = ".config/opencode/skills/omniroute";
  openclawTarget = ".openclaw/workspace/skills/omniroute";
in
{
  flake.modules.homeManager.base = module;
  configurations.nixos.link.module.home-manager.users.tunnel = linkModule;

  perSystem =
    # perSystem `config` is reached via the args set so it does not shadow
    # the flake-level `config` used for aiConfig below.
    perSystemArgs@{ pkgs, system, ... }:
    {
      treefmt.settings.global.excludes = preservedFiles;
    }
    // lib.optionalAttrs (lib.hasSuffix "-linux" system) (
      let
        # Minimal Home Manager evaluations: the OmniRoute module plus the
        # existing recursive parent skills from docs/skills, an unrelated
        # OpenCode child and an unrelated OpenClaw skill, to prove the new
        # links coexist with (and preserve) everything already deployed.
        evalFixture =
          opencodeEnable: isLink:
          (inputs.home-manager.lib.homeManagerConfiguration {
            inherit pkgs;
            modules = [
              module
              {
                home = {
                  username = "fixture";
                  homeDirectory = "/home/fixture";
                  stateVersion = "25.05";
                  file.".openclaw/workspace/skills/fixture-claw/SKILL.md".text = ''
                    ---
                    name: fixture-claw
                    description: Unrelated OpenClaw fixture skill.
                    ---
                  '';
                };
                programs.opencode = {
                  enable = opencodeEnable;
                  package = null;
                  skills = config.flake.aiConfig.skillsDir;
                };
                xdg.configFile."opencode/skills/fixture-child/SKILL.md".text = ''
                  ---
                  name: fixture-child
                  description: Unrelated OpenCode fixture skill.
                  ---
                '';
              }
            ]
            ++ lib.optional isLink linkModule;
          }).config;

        describe =
          hmConfig:
          let
            files = lib.attrValues hmConfig.home.file;
            pick =
              target:
              map (f: {
                inherit (f) target recursive force;
                source = toString f.source;
              }) (lib.filter (f: f.enable && f.target == target) files);
          in
          {
            homeFiles = hmConfig.home-files;
            meta = {
              opencode = pick opencodeTarget;
              openclaw = pick openclawTarget;
              opencodeParent = pick ".config/opencode/skills";
              targets = map (f: f.target) (lib.filter (f: f.enable) files);
            };
          };

        enabled = describe (evalFixture true true);
        disabled = describe (evalFixture false true);
        nonLink = describe (evalFixture true false);

        metadata = pkgs.writeText "omniroute-skills-fixtures.json" (
          builtins.toJSON {
            source = toString skillSource;
            parentSkills = toString config.flake.aiConfig.skillsDir;
            inherit opencodeTarget;
            inherit openclawTarget;
            inherit skillDir preservedFiles;
            treefmtExcludes = perSystemArgs.config.treefmt.settings.global.excludes;
            enabled = enabled.meta;
            disabled = disabled.meta;
            nonLink = nonLink.meta;
          }
        );
      in
      {
        checks.omniroute-skills =
          pkgs.runCommand "omniroute-skills-check"
            { nativeBuildInputs = [ (pkgs.python3.withPackages (ps: [ ps.pyyaml ])) ]; }
            ''
              export PYTHONDONTWRITEBYTECODE=1
              python3 ${./tests/omniroute_skills_test.py} \
                --source ${skillSource} \
                --parent-skills ${config.flake.aiConfig.skillsDir} \
                --metadata ${metadata} \
                --enabled-home ${enabled.homeFiles} \
                --disabled-home ${disabled.homeFiles} \
              --non-link-home ${nonLink.homeFiles}
              touch "$out"
            '';
      }
    );
}
