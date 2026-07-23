# prem-tweet — @Flusoai drafts → Telegram approval → X API v2, with a learning
# loop. A standalone Python daemon on `link` (Telegram long-poll + Anthropic +
# X API v2 + SQLite); the v2 replacement for the old OpenClaw+Notion tweet crons
# (PLAN.md, prem-tweet/BUILD.md).
#
# Mirrors modules/link/commutecompass.nix and modules/link/roomieorder.nix: the
# app ships its own nixosModule + package from its repo, and this file is the
# infra-side glue — flake input, agenix secret, and `services.prem-tweet` wiring.
#
# Unlike commutecompass/roomieorder there is NO openclaw wrapper: prem-tweet is
# fully standalone (Telegram is its own clear surface, X API v2 its own post
# path). It runs as a systemd **user** service — declared by the app's module —
# because DOCS_DIR is a mutable git checkout in tunnel's home that the learning
# loop writes to; running as tunnel keeps those writes under the user's identity
# (mirrors deadman.nix). Generation is an internal scheduled coroutine in the one
# runtime, so no OnCalendar timer is needed here.
{ inputs, ... }:
{
  flake-file.inputs.prem-tweet = {
    url = "github:Multipixelone/prem-tweet";
  };

  configurations.nixos.link.module =
    { config, ... }:
    {
      imports = [ inputs.prem-tweet.nixosModules.default ];

      # Telegram bot token + chat id, Anthropic key, and the X OAuth2
      # user-context tokens — injected via EnvironmentFile=, never the nix store.
      # Owner tunnel / 0400 so the tunnel user service can read it (mirrors
      # deadman.nix / roomieorder.nix). See prem-tweet/prem-tweet.env.example for
      # the file shape. Create+encrypt it with the existing agenix flow — the app
      # never gets a token inline.
      age.secrets."premtweet" = {
        file = "${inputs.secrets}/ai/premtweet.age";
        owner = "tunnel";
        group = "users";
        mode = "0400";
      };

      services.prem-tweet = {
        enable = true;

        # MUTABLE checkout of prem-tweet's docs/ (facts/voice/engagement/
        # learnings). prompts.py reads it at runtime and learn.py appends
        # distilled lessons to learnings.md, so it must be a writable git working
        # tree — NOT the read-only nix-store copy in the package. Clone the repo
        # to ~/prem-tweet on link and periodically commit/push its learnings.md
        # appends so the repo stays canonical (BUILD.md, Deployment).
        docsDir = "/home/tunnel/Documents/Git/prem-tweet/docs";
        brandKitDir = "/home/tunnel/Documents/Git/brand-kit";

        # No @Flusoai X API access yet: at each slot the bot texts Finn the due
        # tweet on Telegram (tap-to-copy + ✅ Posted button) instead of posting
        # via the API. Also engages automatically while the X_* creds are
        # missing from the secret — set here to make the intent explicit. Flip
        # to false (or drop) once API access lands and the secret carries the
        # full X_* set.
        manualPost = true;

        environmentFile = config.age.secrets."premtweet".path;
      };

      # Publish the unit's non-secret env (baseEnv: PREMTWEET_DB, DOCS_DIR, TZ)
      # as a dotenv file so a terminal `prem-tweet` / `prem-tweet-generate`
      # mirrors exactly what the service runs with — same DB, docs and state.
      # Holds no secrets; source environmentFile alongside it for those. Matches
      # roomieorder.nix's environment.etc."roomieorder/env" idiom.
      environment.etc."prem-tweet/env".source = config.services.prem-tweet.envFile;
    };
}
