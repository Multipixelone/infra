{ config, ... }:
{
  flake.modules = {
    nixos.base =
      { pkgs, ... }:
      {
        programs.fish.enable = true;
        programs.command-not-found.enable = false;
        programs.bash = {
          interactiveShellInit = ''
            if [[ $(${pkgs.procps}/bin/ps --no-header --pid=$PPID --format=comm) != "fish" && -z ''${BASH_EXECUTION_STRING} ]]
            then
              shopt -q login_shell && LOGIN_OPTION='--login' || LOGIN_OPTION=""
              exec ${pkgs.fish}/bin/fish $LOGIN_OPTION
            fi
          '';
        };
      };
    homeManager.base =
      {
        pkgs,
        lib,
        ...
      }:
      let
        inherit (lib) getExe getExe';
        cliphist = getExe pkgs.cliphist;
        wl-copy = getExe' pkgs.wl-clipboard "wl-copy";
        fzf-config = ''
          set -x FZF_DEFAULT_OPTS "--preview='bat {} --color=always'" \n
          set -x SKIM_DEFAULT_COMMAND "rg --files || fd || find ."
          set -U __done_notification_command "zellij pipe \"zjstatus::notify::\$title \$message\""
          set -U __done_allow_nongraphical 1
          set -U --append __done_exclude '^lazygit'
          set -U --append __done_exclude '^hx'
        '';
        # pure-config = ''
        #   set pure_enable_single_line_prompt true
        #   set pure_enable_nixdevshell true
        #   set pure_color_mute cyan
        #   set pure_check_for_new_release false
        #   set pure_color_primary white
        #   set pure_color_info blue
        # '';
        fish-config = ''
          set fish_greeting # Disable greeting
        ''
        + fzf-config;
        # + pure-config;
      in
      {
        home.shell.enableFishIntegration = true;
        # source other functions
        xdg.configFile = {
          "fish/functions" = {
            source = lib.cleanSourceWith {
              src = lib.cleanSource ./functions/.;
            };
            recursive = true;
          };
        };
        # allow apps like uwsm to read HM vars
        programs.bash.enable = true;
        programs.fish = {
          enable = true;
          shellAbbrs =
            let
              bat-args = command: args: command + (" | bat " + args);
            in
            {
              c = "clear";
              h = bat-args "history" "-l fish";
              lsabbrs = bat-args "abbr" "-l fish";
              mx = "chmod +x";
              lg = "lazygit";
              nixlg = "cd $PROJECTS_DIR/${config.flake.meta.repo.name} && lazygit";
              fetch = "nix run nixpkgs#nitch";
              upset = "nix run github:Multipixelone/upset";
              hypr-log = "tail -f /run/user/1000/hypr/$(find /run/user/1000/hypr/ -mindepth 1 -printf '%P\n' -prune)/hyprland.log";
              # TODO Split this into commands based on hostname
              pw-get = "pactl load-module module-null-sink media.class=Audio/Sink sink_name=music channel_map=stereo && pactl load-module module-native-protocol-tcp port=4656 listen=192.168.6.6";
              pw-send = "pactl load-module module-tunnel-sink server=tcp:192.168.6.6:4656";
              nsp = "nix-shell -p";
              nb = "nix build";
              nr = "nix run";
              kh = "khinsider";
            };
          shellAliases = {
            fzf = "fzf --preview 'bat --color=always --style=numbers --line-range=:500 {}'";
            mkdir = "mkdir -pv";
            tree = "eza -s type -a -T -I '.git|node_modules|.next'";
            clip = "${cliphist} list | fzf | ${cliphist} decode | ${wl-copy}";
            ping = getExe pkgs.prettyping;
            public-ip = getExe' pkgs.dnsutils "dig" + " +short myip.opendns.com @resolver1.opendns.com";

            # Confirm before overwriting something.
            cp = getExe pkgs.xcp;
            rm = getExe pkgs.gomi;
            mv = "mv --interactive";
            ln = "ln --interactive";
          };
          shellInit = fish-config;
          interactiveShellInit = ''
            # set $EDITOR in fish
            set -gx EDITOR hx
            set -gx VISUAL hx
            set -gx NIXPKGS_ALLLOW_UNFREE 1
            set -gx NIXPKGS_ALLOW_INSECURE 1

            if test "$TERM" != "dumb"
              ${getExe pkgs.zellij} setup --generate-completion fish | source
            end
            if status is-interactive
                  if type -q zellij
                      # Update the zellij tab name with the current process name or pwd.
                      function zellij_tab_name_update_pre --on-event fish_preexec
                          if set -q ZELLIJ
                              set -l cmd_line (string split " " -- $argv)
                              set -l process_name $cmd_line[1]
                              if test -n "$process_name" -a "$process_name" != "z"
                                  command nohup zellij action rename-tab $process_name >/dev/null 2>&1
                                  if test "$process_name" = "hx"
                                    command nohup zellij action switch-mode locked >/dev/null 2>&1
                                  end
                              end
                          end
                      end

                      function zellij_tab_name_update_post --on-event fish_postexec
                          if set -q ZELLIJ
                              set -l cmd_line (string split " " -- $argv)
                              set -l process_name $cmd_line[1]
                              command nohup zellij action switch-mode normal >/dev/null 2>&1
                              if test "$process_name" = "z"
                                  command nohup zellij action rename-tab (prompt_pwd) >/dev/null 2>&1
                              end
                          end
                      end
                  end
              end
          '';
          functions = {
            __onefetch_on_pwd_change = {
              # body = "__onefetch_on_pwd_change --on-variable PWD";
              onVariable = "PWD";
              body = ''
                if test -d ./.git
                  ${getExe pkgs.onefetch} --no-art
                end
              '';
            };
            fish_command_not_found = ''
              # If you run the command with comma, running the same command
              # will not prompt for confirmation for the rest of the session
              if contains $argv[1] $__command_not_found_confirmed_commands
                or ${getExe pkgs.gum} confirm --no-show-help --selected.background=2 "Run using comma?"

                # Not bothering with capturing the status of the command, just run it again
                if not contains $argv[1] $__command_not_found_confirmed_commands
                  set -ga __command_not_found_confirmed_commands $argv[1]
                end

                ${getExe pkgs.comma} -- $argv
                return 0
              else
                __fish_default_command_not_found_handler $argv
              end
            '';
          };
          plugins = [
            {
              name = "fish-eza";
              src = pkgs.fetchFromGitHub {
                owner = "plttn";
                repo = "fish-eza";
                rev = "36f57936ba3e921334ee313b25c3988258fb9771";
                sha256 = "sha256-f/JmwxOnLHq/FXIxI424AfOavlmv5/Ep5D2JEm0jFPE=";
              };
            }
          ]
          ++ (map
            (name: {
              inherit name;
              inherit (pkgs.fishPlugins.${name}) src;
            })
            [
              "fzf-fish"
              "done"
              "pisces"
              "puffer"
              "humantime-fish"
              "grc"
            ]
          );
        };
      };
  };
}
