{
  perSystem =
    { pkgs, ... }:
    {
      packages.claude-status-line = pkgs.writeShellApplication {
        name = "claude-status-line";
        runtimeInputs = [
          pkgs.jq
          pkgs.git
          pkgs.coreutils
          pkgs.inetutils
        ];
        text = ''
          input=$(cat)

          model=$(echo "$input" | jq -r '.model.display_name')
          current_dir=$(echo "$input" | jq -r '.workspace.current_dir')
          project_dir=$(echo "$input" | jq -r '.workspace.project_dir')

          # Context window usage (pre-calculated percentage)
          context_info=""
          used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
          if [ -n "$used_pct" ]; then
              context_info=$(printf "%d%%" "$used_pct")
          fi

          username=$(whoami)
          hostname=$(hostname -s 2>/dev/null || hostname)

          # Directory display (relative to project, else ~-abbreviated)
          if [ -n "$project_dir" ] && [ "$current_dir" != "$project_dir" ]; then
              display_dir=''${current_dir#"$project_dir"/}
              if [ "$display_dir" = "$current_dir" ]; then
                  display_dir=''${current_dir/#"$HOME"/\~}
              fi
          else
              display_dir=''${current_dir/#"$HOME"/\~}
          fi

          # Git branch + dirty indicator (* suffix when modified)
          git_info=""
          if git -C "$current_dir" rev-parse --git-dir > /dev/null 2>&1; then
              branch=$(git -C "$current_dir" branch --show-current 2>/dev/null)
              if [ -n "$branch" ]; then
                  dirty=""
                  if ! git -C "$current_dir" diff-index --quiet HEAD -- 2>/dev/null; then
                      dirty="*"
                  fi
                  git_info=$(printf " \033[2;32m%s%s\033[0m" "$branch" "$dirty")
              fi
          fi

          # Two-color scheme: dim white for labels/separators, cyan for values
          sep="\033[2;37m|\033[0m"

          out=$(printf "\033[2;37m%s@%s\033[0m %b \033[0;36m%s\033[0m%s %b \033[2;37m%s\033[0m" \
              "$username" "$hostname" "$sep" "$display_dir" "$git_info" "$sep" "$model")

          if [ -n "$context_info" ]; then
              out=$(printf "%s %b \033[2;37mctx:\033[0m\033[0;36m%s\033[0m" \
                  "$out" "$sep" "$context_info")
          fi

          printf "%b" "$out"
        '';
      };
    };
}
