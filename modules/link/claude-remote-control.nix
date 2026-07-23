# Claude Code "Remote Control" for local project folders on `link`, pickable
# from the phone.
#
# What this gives you
# -------------------
# One `Restart=always` systemd *user* service per folder (modelled on
# `openclaw-gateway` in ./openclaw.nix). Each runs a Claude Code Remote Control
# session rooted in a real local folder on `link`. Remote Control sessions run
# on THIS machine against the local filesystem — the phone's Claude app ("Code"
# tab) / claude.ai/code is just a window into them. Nothing is pushed to GitHub
# and there is no cloud VM. Because the session dies if its `claude` process
# stops, we keep one alive per folder as a supervised service, so any folder is
# always available to pick up from the phone.
#
# One-time prerequisites that CANNOT be expressed in Nix (Remote Control state
# lives in ~/.claude and there is no settings.json key to enable it)
# --------------------------------------------------------------------
#   1. Sign in once on `link` as `tunnel`: run `claude`, then `/login` (Pro/Max
#      account). Remote Control needs a full-scope OAuth login token —
#      `claude setup-token` / CLAUDE_CODE_OAUTH_TOKEN are model-only and are
#      rejected. When that token eventually expires, re-run `/login` (until then
#      Restart=always will crash-loop on the auth error; check the journal).
#   2. Accept workspace trust once per folder: run `claude` inside each folder
#      below one time (home-dir trust is not persisted).
#   3. Remote Control must reach api.anthropic.com directly: ANTHROPIC_API_KEY
#      must be unset and ANTHROPIC_BASE_URL must be unset / api.anthropic.com.
#      (Verified: nothing in this repo exports either into tunnel's env. The
#      service also clears them defensively via UnsetEnvironment.)
#   4. If sessions must run while tunnel is logged out: `loginctl enable-linger
#      tunnel`. `link` is the Hyprland desktop where tunnel is normally logged
#      in (openclaw-gateway already relies on the user manager), so this may
#      already hold — verify with `loginctl show-user tunnel -p Linger`.
#   Optional: to also make ordinary interactive `co` sessions phone-available,
#   flip `/config` -> "Enable Remote Control for all sessions" once (not
#   declarative; not needed here since the service starts Remote Control
#   explicitly).
#
# Caveats
# -------
#   * Running Remote Control under systemd is not an officially documented
#     pattern (the docs treat it as a foreground process; there is no daemon
#     mode). We supervise it ourselves, exactly like openclaw-gateway.
#   * While connected, the transcript is stored on Anthropic's servers (Remote
#     Control routes phone<->machine via Anthropic's relay; the phone never
#     connects directly to `link`). Fine for personal use.
#
# Verify on `link` after `just rebuild`:
#   systemctl --user status claude-rc-openclaw
#   journalctl --user -u claude-rc-openclaw -f     # should register + show online
# then: Claude app -> Code tab -> the folder session appears (green dot) -> open
# it -> run `pwd` / a small edit -> confirm it acts on link's local files.
{ inputs, ... }:
{
  configurations.nixos.link.module =
    {
      pkgs,
      lib,
      ...
    }:
    let
      claudePkg = inputs.claude-code-pkg.packages.${pkgs.stdenv.hostPlatform.system}.claude;
      home = "/home/tunnel";

      # ---- EDIT HERE: folders to expose to the phone (name -> absolute path) --
      # Names become the session label prefix shown in the Claude app and the
      # `claude-rc-<name>` unit name. Repo checkouts follow the repo's
      # `$PROJECTS_DIR` convention (~/Documents/Git, see ../git/_clone-self.nix);
      # OpenClaw is rooted at its state dir instead so the session can read the
      # config files alongside the workspace.
      folders = {
        # OPENCLAW_STATE_DIR — same root `openclaw-gateway` runs in
        # (see ./openclaw.nix), holding both the config files and workspace/.
        openclaw = "${home}/.openclaw";
        infra = "${home}/Documents/Git/infra";
      };
      # ------------------------------------------------------------------------

      # Launch a Remote Control session for `$1` (name) rooted in `$2` (dir).
      # Picks the right invocation for whatever `claude` build is on `link`:
      #   * If this build has a dedicated `remote-control` subcommand, use it —
      #     it is designed to stay running headless, waiting for connections, so
      #     it needs no PTY and fits a systemd service cleanly.
      #   * Otherwise fall back to the interactive `--remote-control` flag (the
      #     only surface in e.g. claude 2.1.218). That mode renders the TUI and
      #     needs a PTY, which `script` (util-linux) provides so it can run under
      #     systemd.
      # Detection reads the `--help` command list rather than probing
      # `claude remote-control` directly, so an unknown subcommand can't be
      # misread as a prompt.
      launcher = pkgs.writeShellApplication {
        name = "claude-rc";
        runtimeInputs = [
          claudePkg
          pkgs.git
          pkgs.nodejs
          pkgs.ripgrep
          pkgs.coreutils
          pkgs.util-linux
        ];
        text = ''
          name="$1"
          dir="$2"
          if ! cd "$dir"; then
            echo "claude-rc: folder not found: $dir" >&2
            exit 1
          fi
          export CLAUDE_REMOTE_CONTROL_SESSION_NAME_PREFIX="$name"

          if claude --help 2>/dev/null | grep -qE '^[[:space:]]+remote-control([[:space:]]|$)'; then
            # Server/daemon-style mode. If sessions spawn in the wrong place add
            # `--spawn same-dir` (verify flags with `claude remote-control --help`).
            exec claude remote-control
          fi

          exec script -qec "claude --remote-control $name" /dev/null
        '';
      };

      mkService = name: dir: {
        Unit = {
          Description = "Claude Code Remote Control — ${name} (${dir})";
          After = [ "network-online.target" ];
          Wants = [ "network-online.target" ];
        };
        Service = {
          Type = "simple";
          ExecStart = "${lib.getExe launcher} ${name} ${dir}";
          Restart = "always";
          RestartSec = "10s";
          Environment = [
            "HOME=${home}"
            "PATH=${home}/.local/bin:/etc/profiles/per-user/tunnel/bin:/run/current-system/sw/bin:/usr/bin:/bin"
          ];
          # Remote Control refuses to start if these point away from
          # api.anthropic.com; clear anything inherited from the session.
          UnsetEnvironment = [
            "ANTHROPIC_API_KEY"
            "ANTHROPIC_BASE_URL"
            "ANTHROPIC_AUTH_TOKEN"
          ];
        };
        Install.WantedBy = [ "default.target" ];
      };
    in
    {
      home-manager.users.tunnel = {
        systemd.user.services = lib.mapAttrs' (
          name: dir: lib.nameValuePair "claude-rc-${name}" (mkService name dir)
        ) folders;
      };
    };
}
