{ config, ... }:
{
  flake.modules.homeManager.base.programs.git = {
    settings = {
      core = {
        editor = "hx";
        whitespace = "cr-at-eol";
      };
      user = {
        email = config.flake.meta.owner.email;
        name = config.flake.meta.accounts.github.username;
      };
      init.defaultBranch = "main";
      pull.rebase = true;
      push = {
        default = "current";
        autoSetupRemote = true;
      };
      fetch = {
        prune = true;
        fsckObjects = true;
      };
      receive.fsckObjects = true;
      transfer.fsckObjects = true;
      commit.verbose = true;
      branch.sort = "-committerdate";
      tag.sort = "taggerdate";
    };
  };
}
