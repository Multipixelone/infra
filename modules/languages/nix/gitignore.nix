{
  gitignore = [
    # `colmena build --keep-result` (just colmena-diff) writes gcroots here.
    # Untracked, they dirty the flake source and move every host's drvPath.
    "/.gcroots/"
    "/result"
    "/result.*"
  ];
}
