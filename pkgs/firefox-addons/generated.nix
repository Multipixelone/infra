{ buildMozillaXpiAddon, fetchurl, lib, stdenv }:
  {
    "last-fm-unscrobbler" = buildMozillaXpiAddon {
      pname = "last-fm-unscrobbler";
      version = "1.6.4";
      addonId = "lastfm@unscrobbler.com";
      url = "https://addons.mozilla.org/firefox/downloads/file/4474846/last_fm_unscrobbler-1.6.4.xpi";
      sha256 = "34237301a4934f1d5865a25678b4e337bb556caf650da6fc9a3dc3e1632884af";
      meta = with lib;
      {
        homepage = "https://github.com/guytepper/lastfm-unscrobbler";
        description = "Delete multiple scrobbles from your Last.FM profile.";
        license = licenses.mpl20;
        mozPermissions = [ "activeTab" "declarativeContent" ];
        platforms = platforms.all;
      };
    };
    "readwise" = buildMozillaXpiAddon {
      pname = "readwise";
      version = "3.2.8";
      addonId = "{f7619bc3-ed22-44a3-83ad-e79a78416737}";
      url = "https://addons.mozilla.org/firefox/downloads/file/5002835/readwise-3.2.8.xpi";
      sha256 = "3b17340f34db3b6f048af9e6d4cbf6b19b27091d256a5b539a407eb0951f9ddf";
      meta = with lib;
      {
        homepage = "https://readwise.io";
        description = "Don't let your kindle highlights disappear. Sync them with Readwise and then review them daily.";
        mozPermissions = [
          "notifications"
          "cookies"
          "storage"
          "alarms"
          "contextMenus"
          "tabs"
          "*://read.amazon.com/*"
          "*://*.readwise.io/*"
          "*://*.readwise.io/twitter_start*"
        ];
        platforms = platforms.all;
      };
    };
    "tree-style-tab" = buildMozillaXpiAddon {
      pname = "tree-style-tab";
      version = "4.4.4";
      addonId = "treestyletab@piro.sakura.ne.jp";
      url = "https://addons.mozilla.org/firefox/downloads/file/5000082/tree_style_tab-4.4.4.xpi";
      sha256 = "cc1eecb91204016d44def589e9322f89c4b8c70937e142c21b8e558da2206f78";
      meta = with lib;
      {
        homepage = "http://piro.sakura.ne.jp/xul/_treestyletab.html.en";
        description = "Show tabs like a tree.";
        mozPermissions = [
          "activeTab"
          "contextualIdentities"
          "cookies"
          "menus"
          "menus.overrideContext"
          "notifications"
          "search"
          "sessions"
          "storage"
          "tabGroups"
          "tabs"
          "theme"
        ];
        platforms = platforms.all;
      };
    };
    "youtube-popout-player" = buildMozillaXpiAddon {
      pname = "youtube-popout-player";
      version = "5.2.2";
      addonId = "{85b42b8f-49cd-4935-aeca-a6b32dd6ac9f}";
      url = "https://addons.mozilla.org/firefox/downloads/file/4616137/youtube_popout_player-5.2.2.xpi";
      sha256 = "f2199e31039239927050dd979e814db4420978ee7e303fe6f43d85a46052cc3d";
      meta = with lib;
      {
        homepage = "https://rthaut.github.io/YouTubePopoutPlayer/";
        description = "Provides a simple way to open any YouTube video in a popout window";
        license = licenses.gpl3;
        mozPermissions = [
          "contextMenus"
          "declarativeNetRequest"
          "notifications"
          "storage"
          "*://*.youtube-nocookie.com/*"
          "*://*.youtube.com/*"
        ];
        platforms = platforms.all;
      };
    };
  }