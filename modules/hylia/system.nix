{ inputs, config, ... }:
{
  # `pkgs` here is the nix-darwin module's package set, taken from the deferred
  # module's own args — not the flake-parts top-level scope (which has no
  # `pkgs`; that only exists under `perSystem`).
  configurations.darwin.hylia.module =
    { pkgs, ... }:
    {
      nixpkgs.hostPlatform = "aarch64-darwin";

      # Required for user-scoped options (homebrew, system.defaults, …).
      system.primaryUser = config.flake.meta.owner.username;
      system.configurationRevision = inputs.self.rev or inputs.self.dirtyRev or null;

      # Nix itself (experimental-features, trusted-users, substituters) is managed
      # by Determinate Nix via `determinateNix.*` in ./determinate.nix — the
      # determinate module forces `nix.enable = false`, so nix-darwin's `nix.*`
      # settings would be inert here.

      # /etc/zsh* managed by nix-darwin (PATH in non-interactive shells); HM's
      # ~/.zshrc is sourced from the system /etc/zshrc.
      programs.zsh.enable = true;

      # Register fish in /etc/shells so it can be set as the login shell
      # (macOS rejects `chsh` to a shell not listed here). HM installs/configures
      # fish; setting it as the actual login shell is a one-time `chsh -s`.
      #
      # `environment.shells` whitelists `/run/current-system/sw/bin/fish`, which
      # only exists if fish is in the *system* profile — HM installs into the
      # per-user profile, so we add it here too to make that path resolve.
      environment.shells = [ pkgs.fish ];
      environment.systemPackages = [ pkgs.fish ];

      # Touch ID for sudo (survives across `darwin-rebuild` via sudo_local).
      security.pam.services.sudo_local.touchIdAuth = true;
    };
}
