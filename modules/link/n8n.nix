{ inputs, ... }:
{
  nixpkgs.config.allowUnfreePackages = [
    "n8n"
    "n8n-task-runner-launcher"
  ];
  configurations.nixos.link.module =
    { config, ... }:
    {
      age.secrets."n8n".file = "${inputs.secrets}/ai/n8n.age";
      services.n8n = {
        enable = true;
        openFirewall = true;
        environment = {
          N8N_SECURE_COOKIE = false;
          N8N_RUNNERS_AUTH_TOKEN_FILE = config.age.secrets."n8n".path;
        };
        taskRunners = {
          enable = true;
        };
      };
    };
}
