{ config, ... }:
{
  flake.modules.homeManager.base.programs.git = {
    settings = {
      core = {
        editor = "hx";
        whitespace = "fix,-indent-with-non-tab,trailing-space,cr-at-eol";
      };
      user = {
        email = config.flake.meta.owner.email;
        name = config.flake.meta.accounts.github.username;
      };
      init.defaultBranch = "main";
      push.default = "current";
      commit.verbose = true;
      branch.sort = "-committerdate";
      tag.sort = "taggerdate";
    };
  };
}
