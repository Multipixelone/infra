{
  lib,
  inputs,
  withSystem,
  ...
}:
{
  perSystem.wrappers.packages.helix = true;
  flake.wrappers.helix =
    { pkgs, wlib, ... }:
    let
      zellij-args = ":sh zellij run -c -f -x 10%% -y 10%% --width 80%% --height 80%% --";
    in
    {
      imports = [ wlib.wrapperModules.helix ];
      package = inputs.helix.packages.${pkgs.stdenv.hostPlatform.system}.default;
      themes = {
        catppuccin = builtins.readFile "${inputs.catppuccin-helix}/themes/default/catppuccin_mocha.toml";
      };
      settings = {
        theme = "catppuccin";
        editor = {
          line-number = "relative";
          auto-format = true;
          completion-trigger-len = 1;
          completion-replace = true;
          bufferline = "multiple";
          rainbow-brackets = true;
          color-modes = true;
          true-color = true; # fix colors over ssh
          cursorline = true;
          popup-border = "all";
          trim-trailing-whitespace = true;
          indent-guides.render = true;
          indent-heuristic = "tree-sitter";
          soft-wrap = {
            enable = true;
            wrap-indicator = "↩ ";
          };
          auto-save = {
            focus-lost = true;
          };
          lsp = {
            display-inlay-hints = true;
            display-progress-messages = true;
            auto-document-highlight = true;
          };
          end-of-line-diagnostics = "hint";
          inline-diagnostics = {
            cursor-line = "error";
            prefix-len = 1;
            max-wrap = 20;
          };
          gutters = [
            "diagnostics"
            "line-numbers"
            "spacer"
            "diff"
          ];
          statusline = {
            separator = "";
            left = [
              "mode"
              "separator"
              "file-name"
              "file-modification-indicator"
              "read-only-indicator"
              "spinner"
            ];
            right = [
              "diagnostics"
              "workspace-diagnostics"
              "version-control"
              "register"
              "file-encoding"
              "file-type"
              "selections"
              "position"
            ];
            mode = {
              normal = "";
              insert = "I";
              select = "S";
            };
          };
          whitespace.characters = {
            newline = "↴";
            tab = "⇥";
          };
          cursor-shape = {
            insert = "bar";
            normal = "block";
            select = "underline";
          };
        };
        keys = {
          normal = {
            # ctrl + s to save
            C-s = ":write";
            # clipboard commands
            C-v = [
              "paste_clipboard_after"
              "collapse_selection"
            ];
            # tree-sitter selection
            C-h = "select_prev_sibling";
            C-j = "shrink_selection";
            C-k = "expand_selection";
            C-l = "select_next_sibling";
            # selection command
            V = [
              "select_mode"
              "extend_to_line_bounds"
            ];
            space = {
              l.g = [
                "${zellij-args} ${lib.getExe pkgs.lazygit}"
                ":reload"
              ];
              n.r = [
                "${zellij-args} nix run"
                ":reload"
              ];
              n.s = [
                "${zellij-args} fish"
                ":reload"
              ];
            };
          };
        };
      };
      languages = {
        language-server = {
          tinymist = {
            command = "tinymist";
            config = {
              exportPdf = "onType";
              formatterMode = "typstyle";
              formatterPrintWidth = 80;
              preview.background = {
                enabled = true;
                args = [
                  "--data-plane-host=127.0.0.1:0" # 0: pick a random port
                  "--invert-colors=never"
                  "--open"
                ];
              };
            };
          };
          gpt = {
            command = "copilot-language-server";
            args = [ "--stdio" ];
            config = {
              editorInfo = {
                name = "Helix";
                version = "25.01";
              };
              editorPluginInfo = {
                name = "helix-copilot";
                version = "0.1.0";
              };
            };
          };
          taplo = {
            command = lib.getExe pkgs.taplo;
            args = [
              "lsp"
              "stdio"
            ];
          };
          nixd = {
            command = lib.getExe pkgs.nixd;
            args = [ "--inlay-hints=true" ];
            config = {
              formatting.command = [ (lib.getExe pkgs.nixfmt) ];
              nixpkgs.expr = "import <nixpkgs> {}";
              options = {
                nixos.expr = "(builtins.getFlake \"/etc/nixos\").nixosConfigurations.default.options";
                home-manager.expr = "(builtins.getFlake \"/etc/nixos\").homeConfigurations.default.options";
              };
            };
          };
          basedpyright.command = "${pkgs.basedpyright}/bin/basedpyright-langserver";
          ruff = {
            command = lib.getExe pkgs.ruff;
            args = [ "server" ];
          };
          fish-lsp = {
            command = lib.getExe pkgs.fish-lsp;
            args = [ "start" ];
          };
          dprint =
            let
              dprintConfig = builtins.toFile "dprint.json" (
                builtins.toJSON {
                  lineWidth = 80;
                  typescript = {
                    quoteStyle = "preferSingle";
                    binaryExpression.operatorPosition = "sameLine";
                  };
                  json.indentWidth = 2;
                  excludes = [ "**/*-lock.json" ];
                  plugins = [
                    "https://plugins.dprint.dev/typescript-0.93.0.wasm"
                    "https://plugins.dprint.dev/json-0.19.3.wasm"
                    "https://plugins.dprint.dev/markdown-0.17.8.wasm"
                  ];
                }
              );
            in
            {
              command = lib.getExe pkgs.dprint;
              args = [
                "lsp"
                "--config"
                dprintConfig
              ];
            };
          astro-ls = {
            command = "${pkgs.astro-language-server}/bin/astro-ls";
            args = [ "--stdio" ];
          };
          typescript-language-server = {
            command = lib.getExe pkgs.nodePackages.typescript-language-server;
            args = [ "--stdio" ];
            config = {
              typescript-language-server.source = {
                addMissingImports.ts = true;
                fixAll.ts = true;
                organizeImports.ts = true;
                removeUnusedImports.ts = true;
                sortImports.ts = true;
              };
              plugins = [
                {
                  name = "@vue/typescript-plugin";
                  location = "${pkgs.vue-language-server}/lib/node_modules/@vue/language-server";
                  languages = [ "vue" ];
                }
              ];
            };
          };
          uwu-colors = {
            command = "${inputs.uwu-colors.packages.${pkgs.stdenv.hostPlatform.system}.default}/bin/uwu_colors";
          };
          vscode-css-language-server = {
            command = "${pkgs.nodePackages.vscode-langservers-extracted}/bin/vscode-css-language-server";
            args = [ "--stdio" ];
            config = {
              provideFormatter = true;
              css.validate.enable = true;
              scss.validate.enable = true;
            };
          };
          yaml-language-server = {
            command = "${pkgs.nodePackages.yaml-language-server}/bin/yaml-language-server";
            args = [ "--stdio" ];
            config.yaml = {
              schemaStore.enable = true;
              format.enable = true;
              validate = true;
              completion = true;
              hover = true;
              schemas.kubernetes = [
                "*.k8s.yaml"
                "kustomization.yaml"
                "**/values.yaml"
                "helm/*.yaml"
              ];
            };
          };
          texlab = {
            command = "texlab";
            config.texlab = {
              chktex = {
                onOpenAndSave = true;
                onEdit = true;
              };
              build = {
                onSave = true;
                forwardSearchAfter = true;
                executable = "latexrun";
                args = [ "%f" ];
              };
              forwardSearch = {
                executable = "zathura";
                args = [
                  "%p"
                  "--synctex-forward"
                  "%l:1:%f"
                ];
              };
            };
          };
        };
        language =
          let
            prettier = lang: {
              command = lib.getExe pkgs.nodePackages.prettier;
              args = [
                "--parser"
                lang
              ];
            };
          in
          [
            {
              name = "nix";
              language-servers = [
                "nixd"
                "gpt"
              ];
              formatter.command = lib.getExe pkgs.nixfmt;
              auto-format = true;
            }
            {
              name = "yaml";
              auto-format = true;
              language-servers = [ "yaml-language-server" ];
            }
            {
              name = "fish";
              language-servers = [
                "fish-lsp"
                "gpt"
              ];
            }
            {
              name = "markdown";
              language-servers = [
                "marksman"
                "markdown-oxide"
              ];
              formatter = {
                command = lib.getExe pkgs.nodePackages.prettier;
                args = [
                  "--stdin-filepath"
                  "%{buffer_name}"
                ];
              };
              auto-format = true;
            }
            {
              name = "python";
              auto-format = true;
              language-servers = [
                "basedpyright"
                {
                  name = "ruff";
                  except-features = [ "hover" ];
                }
              ];
            }
            {
              name = "latex";
              file-types = [ "tex" ];
              language-servers = [ "texlab" ];
              text-width = 120;
            }
            {
              name = "typst";
              formatter.command = lib.getExe pkgs.typstyle;
              auto-format = true;
              language-servers = [ "tinymist" ];
            }
            {
              name = "toml";
              auto-format = true;
              formatter = {
                command = lib.getExe pkgs.taplo;
                args = [
                  "fmt"
                  "-"
                ];
              };
              language-servers = [ "taplo" ];
            }
            {
              name = "css";
              formatter = prettier "css";
              auto-format = true;
              language-servers = [
                "vscode-css-language-server"
                "uwu-colors"
              ];
            }
            {
              name = "html";
              formatter = prettier "html";
              language-servers = [ "vscode-html-language-server" ];
            }
            {
              name = "javascript";
              auto-format = true;
              file-types = [
                "js"
                "jsx"
                "mjs"
              ];
              language-servers = [
                "dprint"
                "typescript-language-server"
              ];
              formatter = {
                command = lib.getExe pkgs.dprint;
                args = [
                  "fmt"
                  "--stdin"
                  "javascript"
                ];
              };
            }
            {
              name = "astro";
              auto-format = true;
              formatter = prettier "astro";
              language-servers = [ "astro-ls" ];
            }
          ];
      };
    };
  nixpkgs.config.allowUnfreePackages = [ "copilot-language-server" ];
  flake.modules = {
    homeManager.base =
      hmArgs@{
        pkgs,
        lib,
        ...
      }:
      let
        # wrap secret into helix-gpt
        gpt-wrapped = pkgs.writeShellScriptBin "copilot-language-server" ''
          export GITHUB_COPILOT_TOKEN=$(cat ${hmArgs.config.age.secrets."copilot".path})
          ${lib.getExe pkgs.copilot-language-server} $@
        '';
        packages = with pkgs; [
          gpt-wrapped
          marksman
          nodePackages.prettier
          wl-clipboard
          markdown-oxide
        ];
      in
      {
        home.packages = packages;
        age.secrets = {
          "copilot" = {
            file = "${inputs.secrets}/github/copilot.age";
          };
        };
        programs.helix = {
          enable = true;
          package = withSystem pkgs.stdenv.hostPlatform.system (psArgs: psArgs.config.packages.helix);
          defaultEditor = true;
        };
      };
  };
}
