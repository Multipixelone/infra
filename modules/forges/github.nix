{ inputs, ... }:
{
  flake = {
    meta.accounts.github = {
      domain = "github.com";
      username = "Multipixelone";
    };

    modules = {
      nixos.base = {
        # https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints
        programs.ssh.knownHosts."github.com".publicKey =
          "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl";
      };

      homeManager = {
        base =
          hmArgs@{ lib, pkgs, ... }:
          let
            # wrap secret into gh cli
            gh-wrapped = pkgs.writeShellScriptBin "gh" ''
              set -a; source ${hmArgs.config.age.secrets."gh".path}; set +a
              ${lib.getExe pkgs.gh} "$@"
            '';
            gh-dash-wrapped = pkgs.writeShellScriptBin "gh-dash" ''
              set -a; source ${hmArgs.config.age.secrets."gh".path}; set +a
              ${lib.getExe pkgs.gh-dash} "$@"
            '';
          in
          {
            age.secrets."gh".file = "${inputs.secrets}/github/ghcli.age";
            xdg.configFile."fish/completions/gh.fish".source =
              pkgs.runCommand "gh-completion"
                {
                }
                ''
                  ${lib.getExe pkgs.gh} completion -s fish > $out
                '';
            programs.gh = {
              package = gh-wrapped;
              enable = true;
              settings.git_protocol = "ssh";
            };
            programs.git.settings.url = {
              "https://github.com/".insteadOf = "gh:";
              "ssh://git@github.com/".pushInsteadOf = "gh:";
            };

            home.packages = [ gh-dash-wrapped ];
          };
        gui =
          { pkgs, ... }:
          {
            home.packages = with pkgs; [ gh-markdown-preview ];
          };
      };
    };
  };
}
