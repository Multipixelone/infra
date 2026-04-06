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

          # Context window usage
          context_info=""
          usage=$(echo "$input" | jq '.context_window.current_usage')
          if [ "$usage" != "null" ]; then
              current=$(echo "$usage" | jq '.input_tokens + .cache_creation_input_tokens + .cache_read_input_tokens')
              size=$(echo "$input" | jq '.context_window.context_window_size')
              if [ "$size" != "null" ] && [ "$size" -gt 0 ] 2>/dev/null; then
                  pct=$((current * 100 / size))
                  context_info=$(printf "💭 %d%%" "$pct")
              fi
          fi

          username=$(whoami)
          hostname=$(hostname -s 2>/dev/null || hostname)

          # Directory display (relative to project, else ~-abbreviated)
          if [ -n "$project_dir" ] && [ "$current_dir" != "$project_dir" ]; then
              display_dir=''${current_dir#"$project_dir"/}
              if [ "$display_dir" = "$current_dir" ]; then
                  display_dir=''${current_dir/#"$HOME"/~}
              fi
          else
              display_dir=''${current_dir/#"$HOME"/~}
          fi
          # Replace leading ~ with  icon
          display_dir=''${display_dir/#~/}

          # Git branch + dirty indicator
          git_info=""
          if git rev-parse --git-dir > /dev/null 2>&1; then
              branch=$(git branch --show-current 2>/dev/null)
              if [ -n "$branch" ]; then
                  git_status=""
                  if ! git diff-index --quiet HEAD -- 2>/dev/null; then
                      git_status=" 📝"
                  fi
                  # Catppuccin Mocha Green (#a6e3a1 ≈ 150)
                  git_info=$(printf " \033[2;38;5;150m %s\033[0m%s" "$branch" "$git_status")
              fi
          fi

          # Catppuccin Mocha Overlay0 separator (#6c7086 ≈ 60)
          sep=$'\033[2;38;5;60m\033[0m'

          # Catppuccin Mocha palette (256-color approximations):
          #   Mauve  (#cba6f7) ≈ 183  — ⚡ accent
          #   Blue   (#89b4fa) ≈ 111  — username
          #   Teal   (#94e2d5) ≈ 116  — hostname
          #   Overlay1 (#7f849c) ≈ 103 — directory / separators
          #   Lavender (#b4befe) ≈ 147 — model
          #   Overlay0 (#6c7086) ≈ 60  — context info
          printf "\033[38;5;183m⚡\033[0m %s \033[2;38;5;111m %s\033[0m\033[2;38;5;103m@\033[0m\033[2;38;5;116m💻 %s\033[0m %s \033[2;38;5;103m%s\033[0m%s %s \033[2;38;5;147m🧠 %s\033[0m \033[2;38;5;60m%s\033[0m" \
              "$sep" "$username" "$hostname" "$sep" "$display_dir" "$git_info" "$sep" "$model" "$context_info"
        '';
      };
    };
}
