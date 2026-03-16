{
  flake.modules.homeManager.base = {
    programs = {
      mergiraf.enableGitIntegration = true;
      git = {
        settings = {
          merge.conflictstyle = "zdiff3";
          rerere.enabled = true;
        };
      };
      mergiraf.enable = true;
    };
  };
}
