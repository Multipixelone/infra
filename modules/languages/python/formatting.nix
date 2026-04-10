{
  perSystem.treefmt = {
    programs.ruff = {
      check = true;
      format = true;
    };
    settings.formatter.ruff-check.priority = 1;
    settings.formatter.ruff-format.priority = 2;
  };
}
