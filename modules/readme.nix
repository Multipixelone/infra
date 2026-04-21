{ config, lib, ... }:
{
  config = {
    text.readme = {
      order = [
        "intro"
        "ci-badge"
        "badges"
        "about"
        "structure"
        "commands"
        "wrappers"
        "hosts"
        "dendritic"
        "github-actions"
        "files"
      ];

      parts.intro =
        # markdown
        ''
          # ${config.flake.meta.repo.name}
        '';

      parts.badges =
        let
          inherit (config.flake.meta.repo) owner name defaultBranch;
          repoUrl = "https://github.com/${owner}/${name}";
        in
        # markdown
        ''
          [![License](https://img.shields.io/github/license/${owner}/${name}?style=flat-square)](${repoUrl}/blob/${defaultBranch}/LICENSE)
          [![Built with Nix](https://img.shields.io/badge/Built%20with-Nix-5277C3?style=flat-square&logo=nixos&logoColor=white)](https://builtwithnix.org)
          [![Dendritic Pattern](https://img.shields.io/badge/Dendritic--Pattern-Nix-informational?style=flat-square&color=c6a0f6&logo=data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAADIAAAA5CAYAAAB0+HhyAAAAAXNSR0IB2cksfwAAAARnQU1BAACxjwv8YQUAAAAgY0hSTQAAeiYAAICEAAD6AAAAgOgAAHUwAADqYAAAOpgAABdwnLpRPAAAAAlwSFlzAAALEwAACxMBAJqcGAAAAbpJREFUaN7tWcGuwyAMW6L9/y/nXTZpr4PiJA6sqJwmrZQYjOOk8igcZmbv3yIilWvpY9L4BHVpINXjBnIDKRrP1arEUjZlgIiokr0GS9mo1GoFN0uKJUMBdkCt96J00wyt5DUYALLv0ch96O3kCgD0O+INqvdslK5ypApLJnsBjea25o1Ai4gIOvH4XARMdAOO81rPaEWOYCiXB8RpZkfoNtPuDwUnsusoOBa1kFg0ojozqYaqpLJywioAp5cdOZ2KU8kkXmEEiiY3RhLsvYObXQdSiUppZC312HAm3bL+7WuToi9F5rROpGotyfgi5qXP+jeJJi4mIM96PS8mTEsSzcrZ4s5V6s7KB+mafYsT2eaObKtal80jmeDOAjmjLHutbbzW3u63zNglTae7HkF2aGY7CFlbq0DM7rQoWov8WvPhGK9mi6mK5oKnf/CO/flr9Bm5jNb/ZmaK7soqkKhg6L/sCDbpop/XmL7sK+6M48wIAfMTRrdBN6MeiTar3Q06zy5lKTMyk8ipbPNVt6SsHXVnKvKWsncUokGBfCuD15HgWqAzAEsTG6OpsYRaK8cN5AZyRSAzXfIf7j4IjUJ5XtMAAAAASUVORK5CYII=&logoColor=white)](https://github.com/mightyiam/dendritic)
          [![Flake Parts](https://img.shields.io/badge/Flake%20Parts-Nix-informational?style=flat-square&color=89b4fa&logoSize=auto&logoColor=white&logo=data:image/svg+xml;base64,PD94bWwgdmVyc2lvbj0iMS4wIiBlbmNvZGluZz0iVVRGLTgiIHN0YW5kYWxvbmU9Im5vIj8+CjwhLS0gQ3JlYXRlZCB3aXRoIElua3NjYXBlIChodHRwOi8vd3d3Lmlua3NjYXBlLm9yZy8pIC0tPgoKPHN2ZwogICB3aWR0aD0iMzcuMzcyOTFtbSIKICAgaGVpZ2h0PSI0NS4zMTE5NzRtbSIKICAgdmlld0JveD0iMCAwIDM3LjM3MjkwOSA0NS4zMTE5NzMiCiAgIHZlcnNpb249IjEuMSIKICAgaWQ9InN2ZzExNTIiCiAgIHhtbG5zPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyIKICAgeG1sbnM6c3ZnPSJodHRwOi8vd3d3LnczLm9yZy8yMDAwL3N2ZyI+CiAgPGRlZnMKICAgICBpZD0iZGVmczExNDkiIC8+CiAgPGcKICAgICBpZD0ibGF5ZXIxIgogICAgIHRyYW5zZm9ybT0idHJhbnNsYXRlKC0zOS4xMTkzNDksLTExMy4yMDM5OCkiPgogICAgPHBhdGgKICAgICAgIGlkPSJwYXRoNDg5OCIKICAgICAgIHN0eWxlPSJmaWxsOiNmZmZmZmY7ZmlsbC1vcGFjaXR5OjE7c3Ryb2tlOm5vbmU7c3Ryb2tlLXdpZHRoOjcuOTM3O3N0cm9rZS1saW5lam9pbjpyb3VuZDtzdHJva2UtbWl0ZXJsaW1pdDo0O3N0cm9rZS1kYXNoYXJyYXk6bm9uZSIKICAgICAgIGQ9Im0gNDYuNTkzODI4LDExMy4yMDM5OCAtMy43MzcyNCw2LjQ3Mjk5IDcuNDc0NDc5LDEyLjk0NTk4IC03LjQ3NDQ3OSwxMi45NDY1IC0zLjczNzIzOSw2LjQ3Mjk5IDMuNzM3MjM5LDYuNDczNTEgaCA3LjQ3NDQ3OSBsIDcuNDc0NDc5LC0xMi45NDY1IDcuNDc0OTk2LDEyLjk0NjUgaCA3LjQ3NDQ3OSBsIDMuNzM3MjQsLTYuNDczNTEgLTMuNzM3MjQsLTYuNDcyOTkgLTcuNDc0NDc5LC0xMi45NDY1IC03LjQ3NDk5NiwtMTIuOTQ1OTggLTMuNzM3MjM5LC02LjQ3Mjk5IHoiIC8+CiAgPC9nPgo8L3N2Zz4K)](https://flake.parts/)
        '';

      parts.about =
        # markdown
        ''
          > **One dotfile to rule them all.**

          `dotfiles` on steroids, this repository contains my declarative NixOS and Home Manager-based Infrastructure as Code (IaC) for personal devices and home servers.

          Built on top of [flake-parts](https://flake.parts/), this setup manages system configurations, dotfiles, user secrets (via `agenix`), custom packages, and portable applications runnable anywhere via `nix run`.
        '';

      parts.structure =
        # markdown
        ''

          ## Repository Structure

          - **`flake.nix`**: Auto-generated entrypoint (do not edit).
          - **`outputs.nix`**: The true flake entry point, imports the module tree.
          - **`modules/`**: Flake-parts modules defining hosts, profiles, and services. Auto-discovered.
          - **`pkgs/`**: Custom packages and overrides.
          - **`docs/`**: Agent skills and internal documentation.
        '';

      parts.commands =
        let
          justfileLines = lib.splitString "\n" (builtins.readFile ../Justfile);

          recipeNames =
            justfileLines
            |> map (
              line:
              let
                match = builtins.match "^([A-Za-z0-9_-]+)([[:space:]][^:]*)?:([[:space:]].*)?$" line;
              in
              if match == null then null else builtins.elemAt match 0
            )
            |> lib.filter (name: name != null)
            |> lib.unique;

          commandDescriptions = {
            rebuild = "Local system rebuild (uses `nh os switch`).";
            deploy = "Rebuild and push closures to the Attic binary cache.";
            colmena-apply = "Deploy configurations to remote hosts via Colmena.";
            colmena-apply-tag = "Deploy configurations to a specific Colmena tag.";
            minishb = "Build selected hosts and push resulting closures.";
            fastb = "Fast build with `nix-fast-build` and Attic cache upload.";
            iso = "Build an installer ISO.";
            debug = "Run rebuild with `--show-trace` for debugging.";
            update = "Update flake lockfile and Firefox addons.";
            update-flake = "Update flake lockfile inputs.";
            update-addons = "Regenerate Firefox addons metadata.";
            history = "Show system profile history.";
            gc = "Garbage collect and wipe old generations.";
          };

          commandDisplay =
            name: if name == "colmena-apply-tag" then "`just colmena-apply-tag <tag>`" else "`just ${name}`";

          commandRows =
            recipeNames
            |> map (
              name: "| ${commandDisplay name} | ${commandDescriptions.${name} or "See Justfile recipe."} |"
            );
        in
        (
          [
            ""
            "## Commands"
            ""
            "Task execution is managed via `just`."
            ""
            "| Command | Description |"
            "|---|---|"
          ]
          ++ commandRows
          ++ [
            ""
            "> **Note:** Regenerate auto-generated files (like `flake.nix` or this `README.md`) using `nix run .#generate-files`."
          ]
        )
        |> lib.concatLines;

      parts.wrappers =
        let
          inherit (config.flake.meta.repo) owner name;
          repo = "${owner}/${name}";
          wrappers = config.flake.wrappers |> builtins.attrNames |> lib.naturalSort;

          wrapperLines = wrappers |> map (name: "- `${name}` — `nix run github:${repo}#${name}`");
        in
        (
          [
            ""
            "## Wrappers"
            ""
            "Portable applications exposed by this flake and runnable on any Nix-enabled system."
            ""
          ]
          ++ wrapperLines
        )
        |> lib.concatLines;

      parts.hosts =
        let
          rolePriority =
            role:
            let
              normalized = if role == null then "" else lib.toLower role;
            in
            if normalized == "server" then
              "2"
            else if normalized == "desktop" then
              "0"
            else if normalized == "laptop" then
              "1"
            else if normalized == "mobile" then
              "3"
            else if normalized == "tablet" then
              "4"
            else
              "9";

          hostsMarkdown =
            config.hosts
            |> lib.mapAttrsToList (
              _name: host:
              let
                vOrDash = value: if value == null then "-" else value;
                role =
                  if host.readmeRole != null then
                    host.readmeRole
                  else if host.roles == [ ] then
                    null
                  else
                    lib.toSentenceCase (builtins.head host.roles);
              in
              "${rolePriority role}::| `${host.hostName}` | ${vOrDash host.description} | ${vOrDash host.manufacturer} | ${vOrDash host.model} | ${vOrDash role} | ${vOrDash host.desktopWindowManager} | ${vOrDash host.notes} |"
            )
            |> lib.naturalSort
            |> map (row: builtins.substring 3 ((builtins.stringLength row) - 3) row)
            |> lib.concat [
              ""
              "## Hosts"
              ""
              "| Hostname | Description | Manufacturer | Model | Role | Desktop/WM | Notes |"
              "|----------|-------------|--------------|-------|------|------------|-------|"
            ]
            |> lib.concatLines
            |> (s: s + "\n");
        in
        hostsMarkdown;

      parts.dendritic =
        # markdown
        ''

          ## Dendritic Pattern

          This repository follows the [dendritic](https://github.com/mightyiam/dendritic) pattern with flake-parts modules auto-discovered from `modules/`.

        '';
    };

    perSystem =
      { pkgs, ... }:
      {
        files.files = [
          {
            path_ = "README.md";
            drv = pkgs.writeText "README.md" (lib.removeSuffix "\n" config.text.readme + "\n");
          }
        ];

        treefmt.settings.global.excludes = [ "README.md" ];
      };
  };
}
