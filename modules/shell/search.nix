{
  flake.modules.homeManager.base = _: {
    programs = {
      ripgrep.enable = true;
      fd.enable = true;
      jq.enable = true;
      fzf = {
        enable = true;
        defaultCommand = "fd --type file --follow"; # FZF_DEFAULT_COMMAND
        fileWidgetCommand = "fd --type file --follow"; # FZF_CTRL_T_COMMAND
        defaultOptions = [
          "--multi"
          "--reverse"
          "--info inline"
          "--bind=ctrl-f:page-down,ctrl-b:page-up,ctrl-y:accept"
          "--height=40%"
        ];
        fileWidgetOptions = [
          "--preview 'bat -n --color=always --style=header,grid --line-range :500 {}'"
        ];
        changeDirWidgetOptions = [
          "--preview 'eza --tree --color=always {} | head -200'"
        ];
      };
    };
  };
}
