{
  flake.modules.homeManager.base =
    { lib, ... }:
    {
      programs.starship = {
        enable = true;
        settings = {
          directory.style = "blue";
          character = {
            format = "$symbol ";
            success_symbol = "[❯](purple)";
            error_symbol = "[❯](red)";
          };
          hostname = {
            format = " [$hostname]($style) ";
            style = "dimmed white";
            disabled = false;
          };
          git_metrics = {
            format = "([▴$added]($added_style))([▿$deleted]($deleted_style))";
            added_style = "italic dimmed green";
            deleted_style = "italic dimmed red";
            ignore_submodules = true;
            disabled = false;
          };
          git_status = {
            style = "bright-blue";
            format = "([$ahead_behind](italic $style))";
            ahead = "[⇡\${count}](green)";
            behind = "[⇣\${count}](red)";
            diverged = "[⇡\${ahead_count}⇣\${behind_count}](bright-magenta)";
          };
          git_branch = {
            symbol = "";
            truncation_symbol = "⋯";
            truncation_length = 11;
            format = "$symbol $branch";
            ignore_branches = [
              "main"
              "master"
            ];
          };
          directory = {
            # home_symbol = "⌂ ";
            truncation_length = 3;
            truncation_symbol = "…/";
            read_only = " ◈";
            use_os_path_sep = true;
            format = "[$path]($style)[$read_only]($read_only_style)";
            repo_root_style = "bold blue";
            repo_root_format = "[$before_root_path]($before_repo_root_style)[$repo_root]($repo_root_style)[$path]($style)[$read_only]($read_only_style) [](bold bright-blue)";
          };
          nix_shell = {
            style = "dimmed blue";
            symbol = "✶";
            format = "[$symbol $name]($style)";
            impure_msg = "";
            pure_msg = "";
            unknown_msg = "";
          };
          format = lib.concatStrings [
            # "($nix_shell$container$git_metrics)$cmd_duration"
            "$localip"
            "$sudo"
            "$directory"
            "$hostname"
            "$git_status"
            "$git_metrics"
            "$git_branch"
            "$nix_shell"
            "$character"
          ];
          right_format = lib.concatStrings [
            "$singularity"
            "$kubernetes"
            "$vcsh"
            "$fossil_branch"
            "$hg_branch"
            "$pijul_channel"
            "$docker_context"
            "$package"
            "$c"
            "$cmake"
            "$cobol"
            "$daml"
            "$dart"
            "$deno"
            "$dotnet"
            "$elixir"
            "$elm"
            "$erlang"
            "$fennel"
            "$golang"
            "$guix_shell"
            "$haskell"
            "$haxe"
            "$helm"
            "$java"
            "$julia"
            "$kotlin"
            "$gradle"
            "$lua"
            "$nim"
            "$nodejs"
            "$ocaml"
            "$opa"
            "$perl"
            "$php"
            "$pulumi"
            "$purescript"
            "$python"
            "$raku"
            "$rlang"
            "$red"
            "$ruby"
            "$rust"
            "$scala"
            "$solidity"
            "$swift"
            "$terraform"
            "$vlang"
            "$vagrant"
            "$zig"
            "$buf"
            "$conda"
            "$meson"
            "$spack"
            "$memory_usage"
            "$aws"
            "$gcloud"
            "$openstack"
            "$azure"
            "$crystal"
            "$custom"
            "$status"
            "$os"
            "$battery"
            "$time"
          ];
        };
      };
    };
}
