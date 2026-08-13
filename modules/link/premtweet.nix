# prem-tweet — drafts → Telegram approval → X API v2, with a learning loop.
# A standalone Python daemon on `link` (Telegram long-poll + Anthropic + X API v2
# + SQLite); the v2 replacement for the old OpenClaw+Notion tweet crons (PLAN.md,
# prem-tweet/BUILD.md).
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

      # Telegram bot token + chat id, Anthropic key, and the per-account X OAuth2
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

        # Both posting identities. `finn` is @multipixelone — Finn's personal
        # account, which upstream ships as a second registered account with its
        # own doc stack (docs/finn/), its own looser voice, two batches a day
        # seven days a week and ≤5 posts/day (prem-tweet/premtweet/accounts.py).
        #
        # Enabling it is deliberate: upstream defaults to the brand account
        # alone so that no deploy quietly starts drafting for a second identity.
        # The approval gate is unchanged for both — every tweet is a human
        # Approve tap, and the posted bytes are the approve-time snapshot.
        accounts = [
          "fluso"
          "finn"
        ];

        # MUTABLE checkout of prem-tweet's docs/ (facts/voice/engagement/
        # learnings, plus finn/ for the personal account). prompts.py reads it at
        # runtime and learn.py appends distilled lessons to EACH account's own
        # learnings file, so it must be a writable git working tree — NOT the
        # read-only nix-store copy in the package. Periodically commit/push its
        # appends so the repo stays canonical (BUILD.md, Deployment).
        docsDir = "/home/tunnel/Documents/Git/prem-tweet/docs";
        brandKitDir = "/home/tunnel/Documents/Git/brand-kit";

        # @multipixelone posts through the API; @Flusoai stays copy-paste.
        #
        # The secret carries exactly one X credential set and it is the personal
        # account's, re-keyed to the X_FINN_* prefix — the bare X_* names only
        # feed `fluso` (config.py: the legacy fallback is DEFAULT_KEY-only), so
        # leaving them bare would have posted Finn's drafts from the brand grant.
        # With no X_FLUSO_*/bare set left, `fluso` would fall back to manual on
        # its own; naming it here makes that the declared intent rather than an
        # accident of which credentials happen to be present. Drop "fluso" from
        # this list once the brand account has its own API grant.
        manualPost = [ "fluso" ];

        # ---- personal-account drafting sources (read-only, all best-effort) ---

        # Finn's Obsidian vault — the same tree claude-remote-control.nix exposes
        # as the `obsidian` folder. Opt-in per note: vault.py only surfaces notes
        # marked `tweetable: true` / `share: true` / #tweetable / #tweet-idea,
        # and the exclusion markers (private/#nda/#confidential/#personal) win
        # over an include marker on the same note. obsidianScanAll is left off on
        # purpose — it would widen this to every recently-touched note, vetted or
        # not, which is exactly the guardrail worth keeping.
        obsidianDir = "/home/tunnel/Documents/Finn";

        # Build-in-public material from the public events API. No GITHUB_TOKEN is
        # set, so this is the unauthenticated 60/hour path — far above the few
        # generation runs a day — and githubIncludePrivate stays off: private
        # activity is unreleased work, which facts.md forbids asserting anyway.
        githubUser = "Multipixelone";

        # The published tier. The blog is still its own Zola repo
        # (Multipixelone/blog, ~/Documents/Git/blog/content) — what changed is that
        # the vault now reaches it: Spaces/Writing/Blog is a symlink to that
        # content dir, so the posts ARE in the vault as far as this source is
        # concerned. Matching is by whole path component, so "Blog" is the folder
        # name rather than the path to it, and vault.py follows the link only for
        # the blog walk (the notes walk deliberately does not).
        #
        # Section indexes (_index.md) are skipped as the static-site furniture they
        # are; the five real posts carry YAML frontmatter with a slug, which is what
        # blogBaseUrl turns into a canonical link.
        blogDirs = [ "Blog" ];
        blogBaseUrl = "https://blog.finnrut.is/";

        environmentFile = config.age.secrets."premtweet".path;
      };

      # Publish the unit's non-secret env (baseEnv: PREMTWEET_DB,
      # PREMTWEET_ACCOUNTS, DOCS_DIR, …) as a dotenv file so a terminal
      # `prem-tweet` / `prem-tweet-generate` mirrors exactly what the service
      # runs with — same DB, docs and state. Holds no secrets; source
      # environmentFile alongside it for those. Matches roomieorder.nix's
      # environment.etc."roomieorder/env" idiom.
      environment.etc."prem-tweet/env".source = config.services.prem-tweet.envFile;
    };
}
