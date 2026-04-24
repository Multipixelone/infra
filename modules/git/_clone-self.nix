{ config, ... }:
let
  inherit (config.flake.meta) repo;
in
{
  flake.modules.homeManager.base =
    hmArgs@{ pkgs, lib, ... }:
    let
      projectsDir = "${hmArgs.config.home.homeDirectory}/Documents/Git";
      repoDir = "${projectsDir}/${repo.name}";
    in
    {
      home.sessionVariables.PROJECTS_DIR = projectsDir;

      home.activation.cloneSelf = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        if [ ! -d ${lib.escapeShellArg "${repoDir}/.git"} ]; then
          $DRY_RUN_CMD mkdir -p ${lib.escapeShellArg projectsDir}
          $DRY_RUN_CMD env GIT_SSH_COMMAND=${lib.escapeShellArg "${lib.getExe pkgs.openssh} -o BatchMode=yes -o StrictHostKeyChecking=accept-new"} \
            ${lib.getExe pkgs.git} clone --recurse-submodules \
            ${lib.escapeShellArg repo.cloneUrl} \
            ${lib.escapeShellArg repoDir} \
            || echo "Warning: failed to clone ${repo.name}. Clone it manually into ${lib.escapeShellArg projectsDir}."
        fi
      '';
    };
}
