{
  flake.modules.homeManager.base = {
    # System-wide `:shortcode:` → emoji expansion (Slack/Discord style) via the
    # espanso text expander. Unlike macOS' native Text Replacement, espanso
    # injects at the input layer, so it fires everywhere — terminals, Electron
    # apps, browsers — not just native Cocoa text fields. Enabled on every host:
    # launchd agent on darwin, `systemd --user` service on Linux (x11 works best;
    # Wayland injection has known quirks).
    #
    # On macOS, first launch needs Accessibility + Input Monitoring granted to
    # espanso in System Settings → Privacy & Security (Apple gates these behind a
    # GUI prompt; nothing can declare them).
    services.espanso = {
      enable = true;
      matches.emoji.matches = [
        # The two you asked for: graph arrows trending up / down.
        {
          trigger = ":up:";
          replace = "📈";
        }
        {
          trigger = ":down:";
          replace = "📉";
        }

        # Status / dev workflow.
        {
          trigger = ":check:";
          replace = "✅";
        }
        {
          trigger = ":x:";
          replace = "❌";
        }
        {
          trigger = ":warn:";
          replace = "⚠️";
        }
        {
          trigger = ":fire:";
          replace = "🔥";
        }
        {
          trigger = ":rocket:";
          replace = "🚀";
        }
        {
          trigger = ":bug:";
          replace = "🐛";
        }
        {
          trigger = ":zap:";
          replace = "⚡";
        }
        {
          trigger = ":sparkles:";
          replace = "✨";
        }
        {
          trigger = ":tada:";
          replace = "🎉";
        }
        {
          trigger = ":100:";
          replace = "💯";
        }
        {
          trigger = ":eyes:";
          replace = "👀";
        }
        {
          trigger = ":brain:";
          replace = "🧠";
        }

        # Gestures / reactions.
        {
          trigger = ":+1:";
          replace = "👍";
        }
        {
          trigger = ":-1:";
          replace = "👎";
        }
        {
          trigger = ":ok:";
          replace = "👌";
        }
        {
          trigger = ":wave:";
          replace = "👋";
        }
        {
          trigger = ":clap:";
          replace = "👏";
        }
        {
          trigger = ":pray:";
          replace = "🙏";
        }
        {
          trigger = ":point:";
          replace = "👉";
        }

        # Faces.
        {
          trigger = ":nerd:";
          replace = "🤓";
        }
        {
          trigger = ":cool:";
          replace = "😎";
        }
        {
          trigger = ":think:";
          replace = "🤔";
        }
        {
          trigger = ":joy:";
          replace = "😂";
        }
        {
          trigger = ":sob:";
          replace = "😭";
        }
        {
          trigger = ":wink:";
          replace = "😉";
        }
        {
          trigger = ":party:";
          replace = "🥳";
        }
        {
          trigger = ":shrug:";
          replace = "¯\\_(ツ)_/¯";
        }

        # Symbols.
        {
          trigger = ":heart:";
          replace = "❤️";
        }
        {
          trigger = ":star:";
          replace = "⭐";
        }
        {
          trigger = ":skull:";
          replace = "💀";
        }

        # Plain directional arrows (distinct from the :up:/:down: graphs).
        {
          trigger = ":aup:";
          replace = "⬆️";
        }
        {
          trigger = ":adown:";
          replace = "⬇️";
        }
        {
          trigger = ":aleft:";
          replace = "⬅️";
        }
        {
          trigger = ":aright:";
          replace = "➡️";
        }
      ];
    };
  };
}
