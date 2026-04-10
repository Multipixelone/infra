{
  buildMozillaXpiAddon,
  lib,
}:
{
  "last-fm-unscrobbler" = buildMozillaXpiAddon {
    pname = "last-fm-unscrobbler";
    version = "1.6.4";
    addonId = "lastfm@unscrobbler.com";
    url = "https://addons.mozilla.org/firefox/downloads/file/4474846/last_fm_unscrobbler-1.6.4.xpi";
    sha256 = "34237301a4934f1d5865a25678b4e337bb556caf650da6fc9a3dc3e1632884af";
    meta = with lib; {
      homepage = "https://github.com/guytepper/lastfm-unscrobbler";
      description = "Delete multiple scrobbles from your Last.FM profile.";
      license = licenses.mpl20;
      mozPermissions = [
        "activeTab"
        "declarativeContent"
      ];
      platforms = platforms.all;
    };
  };
  "readwise" = buildMozillaXpiAddon {
    pname = "readwise";
    version = "3.2.3";
    addonId = "{f7619bc3-ed22-44a3-83ad-e79a78416737}";
    url = "https://addons.mozilla.org/firefox/downloads/file/4673048/readwise-3.2.3.xpi";
    sha256 = "f9f2bfd611fe4e8cc6022509315c8f00c6577008246319505c5e2241bac60422";
    meta = with lib; {
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
    meta = with lib; {
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
