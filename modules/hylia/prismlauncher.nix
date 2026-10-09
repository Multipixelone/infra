{ config, ... }:
let
  user = config.flake.meta.owner.username;
in
{
  configurations.darwin.hylia.module =
    { pkgs, ... }:
    {
      # The pinned Nix package supports Darwin and installs an Applications
      # bundle. mac-app-util.nix exposes it through HM's ~/Applications aliases.
      home-manager.users.${user}.home.packages = [
        (pkgs.prismlauncher.override {
          # Java 25 for current Minecraft; retain older runtimes for modpacks.
          # The wrapper supplies these to Prism's Java auto-detection.
          jdks = with pkgs; [
            jdk25
            jdk21
            jdk17
            jdk8
          ];
        })
      ];

      # Synced instance.cfg files can contain another host's JavaPath.
      # Prism's AutoInstallJava replaces a missing override when global
      # AutomaticJavaSwitch is enabled and a compatible runtime is found.
      # Otherwise CheckJava fails the launch and asks to fix/disable the override.
      # One-time Mac fix: Edit Instance -> Settings -> Java, untick "Java
      # installation" to inherit the global Java selection, or use Auto-detect
      # to select a compatible Mac runtime. Configure global Java first.
      # UI edits to instance.cfg sync to peers; Nix never rewrites these files.
    };
}
