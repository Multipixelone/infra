{
  flake.modules.homeManager.base = {
    programs = {
      mergiraf.enableGitIntegration = true;
      git = {
        settings = {
          rerere.enabled = true;
        };
      };
      mergiraf.enable = true;
    };
  };
}
