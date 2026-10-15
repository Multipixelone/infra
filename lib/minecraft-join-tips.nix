# Structured text stays literal: command examples containing <name> or <aqua>
# must never be parsed as MiniMessage. Colours match FlectonePulse and TAB.
{
  lib,
  mapUrl,
  inviteUrl,
}:
let
  muted = "#a6adc8";
  mauve = "#cba6f7";
  prose = text: {
    inherit text;
    color = muted;
  };
  accent = text: {
    inherit text;
    color = mauve;
  };
  hover = text: {
    action = "show_text";
    value = prose text;
  };
  command =
    text: suggestion:
    (accent text)
    // {
      click_event = {
        action = "suggest_command";
        command = suggestion;
      };
      hover_event = hover "Click to suggest";
    };
  link =
    text: url:
    (accent text)
    // lib.optionalAttrs (url != "") {
      click_event = {
        action = "open_url";
        inherit url;
      };
      hover_event = hover "Click to open link";
    };
  discord = text: link text inviteUrl;
  component = extra: {
    text = "";
    color = muted;
    bold = false;
    italic = false;
    underlined = false;
    extra = extra;
  };
  tellraw = extra: "tellraw @s ${builtins.toJSON (component extra)}\n";
  bullet = prose "· ";
  label = text: [
    bullet
    (accent text)
  ];
  # MiniMessage's three-stop, zero-phase TAB gradient across 15 characters.
  # TextColor.lerp rounds each RGB channel; seven intervals separate the stops.
  gradient = lib.imap0 (
    index: text:
    let
      offset = if index <= 7 then index else index - 7;
      start =
        if index <= 7 then
          [
            203
            166
            247
          ]
        else
          [
            245
            194
            231
          ];
      end =
        if index <= 7 then
          [
            245
            194
            231
          ]
        else
          [
            250
            179
            135
          ];
      channel =
        a: b:
        lib.toLower (
          lib.fixedWidthString 2 "0" (lib.toHexString (builtins.div (a * (7 - offset) + b * offset + 3) 7))
        );
    in
    {
      inherit text;
      color = "#${lib.concatStrings (lib.zipListsWith channel start end)}";
      bold = true;
    }
  ) (lib.stringToCharacters "Finn's Survival");
  welcome = [
    bullet
    (prose "Welcome to ")
  ]
  ++ gradient
  ++ [ (prose "! Quick start:\n") ]
  ++ label "Homes: "
  ++ [
    (command "/sethome <name>" "/sethome ")
    (prose ", then ")
    (command "/home <name>" "/home ")
    (prose " (10 max)\n")
  ]
  ++ label "Friends: "
  ++ [
    (command "/tpa <player>" "/tpa ")
    (prose ", they reply ")
    (command "/tpaccept" "/tpaccept")
    (prose "\n")
    bullet
    (prose "Mine ores while sneaking to vein-mine them\n")
    bullet
    (prose "Death keeps items+XP in a grave; follow your ")
    (accent "Grave Compass")
    (prose "\n")
  ]
  ++ label "Map: "
  ++ [
    (link (lib.removePrefix "https://" mapUrl) mapUrl)
    (prose " · ")
    (discord "Discord: ")
    (command "/discord" "/discord")
  ];
  # Edit this list; numbering, random bounds and function files follow its length.
  tips = [
    [
      (command "/sethome <name>" "/sethome ")
      (prose " saves a home; ")
      (command "/home <name>" "/home ")
      (prose " takes you there.")
    ]
    [
      (command "/tpa <player>" "/tpa ")
      (prose " asks to visit; they have 60s to ")
      (command "/tpaccept" "/tpaccept")
      (prose ".")
    ]
    [ (prose "Sneak while mining ore with a pickaxe to vein-mine it.") ]
    [
      (prose "Die? You respawn with a ")
      (accent "Grave Compass")
      (prose " pointing to your grave.")
    ]
    [ (prose "Shift + right-click your grave to grab everything at once.") ]
    [ (prose "Graves never expire and only you can open yours.") ]
    [
      (command "/ec" "/ec")
      (prose " opens your ender chest from anywhere.")
    ]
    [
      (command "/edithome <name> privacy public" "/edithome ")
      (prose " shows a home on the map.")
    ]
    [
      (command "/phome <player>:<home>" "/phome ")
      (prose " visits someone's public home.")
    ]
    [ (prose "You can keep 10 homes and share 10 public ones.") ]
    [
      (command "/back" "/back")
      (prose " returns you to before a home or TPA teleport.")
    ]
    [ (prose "Only half the players need to sleep to skip the night.") ]
    [
      (prose "See the live world map at ")
      (link mapUrl mapUrl)
    ]
    [
      (command "/afk" "/afk")
      (prose " toggles AFK; you're marked AFK after 5 idle minutes.")
    ]
    [
      (command "/nick <aqua>Name" "/nick <aqua>Name")
      (prose " colours your nickname; ")
      (command "/nick reset" "/nick reset")
      (prose " clears it. Linked Discord nicknames sync as plain text.")
    ]
    [
      (command "/discord" "/discord")
      (prose " shows the invite link for our ")
      (discord "Discord")
      (prose ".")
    ]
    [ (prose "Stonecut blocks into mini-block heads for decorating.") ]
    [
      (command "/tpignore" "/tpignore")
      (prose " toggles incoming teleport requests.")
    ]
    [ (prose "Nether portals can be any shape, with crying obsidian.") ]
    # HuskHomes 4.11-9ed80cc: RANDOM_TELEPORT defaults to 600 seconds.
    [
      (command "/rtp" "/rtp")
      (prose " teleports you into the wild; cooldown: 10 minutes.")
    ]
  ];
  markSeen = ''
    tag @s add infra.join_tips.seen
    scoreboard players set @s ijt_leave 0
  '';
  prefix = "data/infra/function/join_tips/";
in
{
  "${prefix}first.mcfunction" = tellraw welcome + markSeen;
  "${prefix}returning.mcfunction" =
    tellraw [
      bullet
      (prose "Welcome back, ")
      {
        selector = "@s";
        color = mauve;
      }
      (prose "!")
    ]
    + ''
      execute store result score @s ijt_tip run random value 1..${toString (lib.length tips)}
    ''
    + lib.concatStrings (
      lib.imap1 (
        index: _:
        "execute if score @s ijt_tip matches ${toString index} run function infra:join_tips/tips/${toString index}\n"
      ) tips
    )
    + markSeen;
}
// lib.listToAttrs (
  lib.imap1 (
    index: spans:
    lib.nameValuePair "${prefix}tips/${toString index}.mcfunction" (tellraw (label "Tip: " ++ spans))
  ) tips
)
