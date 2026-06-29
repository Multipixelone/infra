{ inputs, config, ... }:
{
  configurations.darwin.fi.module = {
    nixpkgs.hostPlatform = "aarch64-darwin";

    # Required for user-scoped options (homebrew, system.defaults, …).
    system.primaryUser = config.flake.meta.owner.username;
    system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;

    nix.enable = true;
    nix.settings = {
      experimental-features = [
        "nix-command"
        "flakes"
        "pipe-operators"
      ];
      trusted-users = [
        "@admin"
        config.flake.meta.owner.username
      ];
    };

    # /etc/zsh* managed by nix-darwin (PATH in non-interactive shells); HM's
    # ~/.zshrc is sourced from the system /etc/zshrc.
    programs.zsh.enable = true;

    # Touch ID for sudo (survives across `darwin-rebuild` via sudo_local).
    security.pam.services.sudo_local.touchIdAuth = true;
  };
}
