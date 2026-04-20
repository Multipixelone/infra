{
  flake.modules.homeManager.gui =
    { pkgs, ... }:
    let
      tinymistThemeExtension =
        pkgs.runCommandLocal "tinymist-catppuccin-extension"
          {
            manifest = builtins.toJSON {
              manifest_version = 3;
              name = "Tinymist Catppuccin Mocha";
              version = "1.0.0";
              description = "Catppuccin Mocha theme for tinymist typst preview";
              content_scripts = [
                {
                  matches = [
                    "http://127.0.0.1/*"
                    "http://localhost/*"
                  ];
                  css = [ "catppuccin-mocha.css" ];
                  js = [ "content.js" ];
                  run_at = "document_idle";
                  all_frames = true;
                }
              ];
            };

            contentJs = ''
              console.log("Tinymist Catppuccin theme injected successfully!");

              const root = document.documentElement;
              root.style.setProperty("--typst-preview-background-color", "#11111b", "important");
              root.style.setProperty("--typst-preview-foreground-color", "#cdd6f4", "important");
              root.style.setProperty("--typst-preview-toolbar-fg-color", "#cdd6f4", "important");
              root.style.setProperty("--typst-preview-toolbar-border-color", "#313244", "important");
              root.style.setProperty("--typst-preview-toolbar-bg-color", "#181825", "important");
            '';

            themeCss = ''
              /* 1. Set the background behind the paper to Mocha Crust */
              :root, body { background-color: #11111b !important; }

              /* 2. Color the paper itself to Mocha Base, bypassing the filter */
              .typst-page-inner { fill: #1e1e2e !important; stroke: #313244 !important; stroke-width: 1px !important; }

              /* 3. Remove the filter from the whole document */
              #typst-app .typst-doc, #typst-app.invert-colors .typst-doc { filter: none !important; }

              /* 4. Apply the dark mode filter ONLY to the page content (text/shapes) */
              #typst-app .typst-page, #typst-app.invert-colors .typst-page { filter: invert(1) hue-rotate(180deg) sepia(0.2) brightness(0.85) contrast(0.95) !important; }

              /* 5. Fix images so they aren't double-inverted */
              #typst-app .typst-image, #typst-app.invert-colors .typst-image { filter: invert(1) hue-rotate(180deg) !important; }

              /* 6. Text selection color */
              .tsel span::selection, .tsel::selection { background-color: #cba6f760 !important; }

              /* 7. Hover highlight color */
              .hover .typst-text, .typst-text:hover {
                --glyph_fill: #fab387 !important;
                --glyph_stroke: #fab387 !important;
                /* Pre-invert the hover color so the parent filter transforms it into Peach! */
                filter: invert(1) hue-rotate(180deg) !important;
              }

              /* 8. Hide Scrollbar */
              .element::-webkit-scrollbar {
                display: none;
              }
            '';

            passAsFile = [
              "manifest"
              "contentJs"
              "themeCss"
            ];

          }
          ''
            mkdir -p $out
            cp "$manifestPath"  $out/manifest.json
            cp "$contentJsPath" $out/content.js
            cp "$themeCssPath"  $out/catppuccin-mocha.css
          '';
    in
    {
      programs.chromium = {
        commandLineArgs = [
          "--load-extension=${tinymistThemeExtension}"
        ];
      };
    };
}
