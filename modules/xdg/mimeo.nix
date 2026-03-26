{
  flake.modules.homeManager.gui =

    {
      pkgs,
      config,
      ...
    }:
    let
      # xdg-utils as a runtime dependency: https://github.com/NixOS/nixpkgs/pull/181171
      # see on postFixup instead of postInstall: https://github.com/NixOS/nixpkgs/pull/285233
      xdg-mimeo = pkgs.xdg-utils.overrideAttrs (_old: {
        postFixup = ''
          cp ${pkgs.mimeo}/bin/mimeo $out/bin/xdg-open
        '';
      });
      # taken from fufexan https://github.com/fufexan/dotfiles/blob/f3723f5e0982d7275cdf6264bc3dcde48bf9a53c/home/terminal/programs/xdg.nix
      browser = [ "firefox" ];
      imageViewer = [ "org.gnome.Loupe" ];
      videoPlayer = [ "vlc" ];
      audioPlayer = [ "vlc" ];
      xdgAssociations =
        type: program: list:
        builtins.listToAttrs (
          map (e: {
            name = "${type}/${e}";
            value = program;
          }) list
        );

      image = xdgAssociations "image" imageViewer [
        "png"
        "svg"
        "jpeg"
        "gif"
      ];
      video = xdgAssociations "video" videoPlayer [
        "mp4"
        "avi"
        "mkv"
      ];
      audio = xdgAssociations "audio" audioPlayer [
        "mp3"
        "flac"
        "aac"
      ];
      browserTypes =
        (xdgAssociations "application" browser [
          "json"
          "x-extension-htm"
          "x-extension-html"
          "x-extension-shtml"
          "x-extension-xht"
          "x-extension-xhtml"
        ])
        // (xdgAssociations "x-scheme-handler" browser [
          "about"
          "ftp"
          "http"
          "https"
          "unknown"
        ]);

      # XDG MIME types
      associations = builtins.mapAttrs (_: v: (map (e: "${e}.desktop") v)) (
        {
          "application/pdf" = [ "org.pwmt.zathura-pdf-mupdf" ];
          "text/html" = browser;
          "text/plain" = [ "Helix" ];
          "audio/wav" = [ "izotope-rx-10.desktop" ];
          "audio/x-wav" = [ "izotope-rx-10.desktop" ];
          "x-scheme-handler/chrome" = [ "chromium-browser" ];
          "inode/directory" = [ "yazi" ];
          "x-scheme-handler/nxm" = [ "modorganizer2-nxm-handler.desktop" ];
        }
        // image
        // video
        // audio
        // browserTypes
      );
    in
    {
      xdg = {
        enable = true;
        cacheHome = config.home.homeDirectory + "/.local/cache";

        mimeApps = {
          enable = true;
          defaultApplications = associations;
        };

        userDirs = {
          enable = true;
          setSessionVariables = true;
          extraConfig = {
            SCREENSHOTS = "${config.xdg.userDirs.pictures}/Screenshots";
          };
        };
      };
      home.packages = [
        pkgs.mimeo
        pkgs.nemo
        pkgs.loupe
        pkgs.kdePackages.ark
        xdg-mimeo
      ];
    };
}
