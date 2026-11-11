{
  flake.modules.homeManager.base = {
    programs.git.settings.rebase = {
      autoSquash = true;
      autoStash = true;
      instructionFormat = "%d %s";
      updateRefs = true;
    };
  };
}
