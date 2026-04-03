{
  lib,
  stdenvNoCC,
  makeWrapper,
  # treble.node is compiled for Node.js ABI v115 (node_register_module_v115)
  nodejs_20,
  python3,
  squashfsTools,
  plexamp,
}:
let
  # Reuse the source and version from the nixpkgs plexamp desktop package
  inherit (plexamp) version src;

  # Extract the squashfs filesystem from the AppImage
  appimageContents = stdenvNoCC.mkDerivation {
    pname = "plexamp-appimage-contents";
    inherit version src;

    nativeBuildInputs = [
      python3
      squashfsTools
      nodejs_20.pkgs.asar
    ];

    unpackPhase = ''
      # AppImage = ELF stub + squashfs; calculate where the squashfs starts
      offset=$(python3 -c '
      import os, struct
      elfHeader = os.read(0, 64)
      (bitness, endianness) = struct.unpack("4x B B 58x", elfHeader)
      (shoff, shentsize, shnum) = struct.unpack(
          (">" if endianness == 2 else "<") +
          ("40x Q 10x H H 2x" if bitness == 2 else "32x L 10x H H 14x"),
          elfHeader
      )
      print(shoff + shentsize * shnum)
      ' < "$src")
      unsquashfs -o "$offset" -d squashfs-root "$src"
    '';

    installPhase = ''
      mkdir -p "$out/app"
      cd squashfs-root/resources

      # Extract JS source from the asar archive.
      # asar extract fails on dangling symlinks in app.asar.unpacked (build
      # artifacts like node_gyp_bins/python3), so use Node.js directly to
      # extract only the packed files and handle unpacked files separately.
      if [ -f app.asar ]; then
        ${nodejs_20}/bin/node -e '
          const asar = require("${nodejs_20.pkgs.asar}/lib/node_modules/@electron/asar");
          const fs = require("fs");
          const path = require("path");
          const archive = process.argv[1];
          const dest = process.argv[2];
          const filenames = asar.listPackage(archive);
          for (const name of filenames) {
            const destPath = path.join(dest, name);
            let stat;
            try { stat = asar.statFile(archive, name); } catch { continue; }
            if (!stat) continue;
            if ("files" in stat) {
              fs.mkdirSync(destPath, { recursive: true });
            } else if (!stat.unpacked) {
              fs.mkdirSync(path.dirname(destPath), { recursive: true });
              fs.writeFileSync(destPath, asar.extractFile(archive, name));
            }
          }
        ' app.asar "$out/app"
      elif [ -d app ]; then
        cp -r app/* "$out/app/"
      fi

      # Copy native modules (e.g. treble.node) that live outside the asar,
      # skipping dangling symlinks (build artifacts like node_gyp_bins/python3)
      if [ -d app.asar.unpacked ]; then
        cp -rn --no-dereference app.asar.unpacked/* "$out/app/" 2>/dev/null || true
        # Remove dangling symlinks
        find "$out/app" -xtype l -delete 2>/dev/null || true
      fi
    '';
  };
in
stdenvNoCC.mkDerivation {
  pname = "plexamp-headless";
  inherit version;

  dontUnpack = true;

  nativeBuildInputs = [ makeWrapper ];

  installPhase = ''
    runHook preInstall

    mkdir -p "$out/lib/plexamp-headless"
    cp -r ${appimageContents}/app/* "$out/lib/plexamp-headless/"

    mkdir -p "$out/bin"
    makeWrapper "${lib.getExe nodejs_20}" "$out/bin/plexamp-headless" \
      --add-flags "$out/lib/plexamp-headless/js/index.js"

    runHook postInstall
  '';

  meta = {
    description = "Headless Plexamp player (extracted from desktop AppImage)";
    homepage = "https://plexamp.plex.tv/";
    mainProgram = "plexamp-headless";
    license = lib.licenses.unfree;
    platforms = [ "x86_64-linux" ];
    sourceProvenance = [ lib.sourceTypes.binaryBytecode ];
  };
}
