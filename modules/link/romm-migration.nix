# One-shot migration tooling for the move to RomM as the save hub. These are
# not services: they run by hand, in order, once.
#
#   1. romm-igir-import   messy collection -> DAT-verified, RomM-shaped library
#   2. romm-save-rename   old save filenames -> the names igir gave the ROMs
#   3. romm-save-upload   flattened saves -> RomM, over the documented API
#
# Step 2 exists because Grout matches saves to ROMs by platform and filename.
# igir renames "Pokemon Red.gb" to its No-Intro name, and the .sav sitting next
# to it does not follow -- which is the single most likely way to silently lose
# access to a save in this migration. Nothing here ever deletes or moves an
# original: every step reads one tree and writes a new one.
{ inputs, ... }:
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      staging = "/media/Data/romm-staging";
      library = "/media/Data/romm/library";

      # The seed uploader authenticates with a RomM Client API Token. It lives
      # in agenix like every other credential here rather than a dotfile in
      # $HOME: the token carries assets.write against an instance whose /api/
      # is reachable from the internet, so it is worth the same handling as the
      # provider keys next to it. Owned by tunnel because the migration tools
      # are run by hand, as the login user, not by a service.
      tokenPath = config.age.secrets."romm-api-token".path;

      # igir's CSV report is a human artifact, not a machine input. Its column
      # headers are not part of any documented contract, so the rename step
      # below maps old names to new ones by content hash instead of parsing it:
      # the same bytes under a different name are the same ROM, whatever igir's
      # report format does next release.
      romm-igir-import = pkgs.writeShellApplication {
        name = "romm-igir-import";
        runtimeInputs = with pkgs; [
          igir
          rsync
          coreutils
        ];
        text = ''
          STAGING="${staging}"
          PROMOTE=0

          while [ $# -gt 0 ]; do
            case "$1" in
              --staging) STAGING="$2"; shift 2 ;;
              --promote) PROMOTE=1; shift ;;
              -h|--help)
                cat <<'USAGE'
          romm-igir-import [--staging DIR] [--promote]

            Verifies and renames ROMs against No-Intro/Redump DATs, writing a
            RomM-shaped tree. Reads STAGING/roms-unverified, never the original
            collection. With --promote, copies the verified tree into the live
            RomM library afterwards.

            Expected layout under --staging (default ${staging}):
              dats/             DAT files, downloaded by hand
              roms-unverified/  a COPY of the collection to work on
              roms-verified/    output, RomM platform slugs
              roms-unmatched/   output, anything no DAT recognised
              reports/          igir CSV reports
          USAGE
                exit 0 ;;
              *) echo "unknown argument: $1" >&2; exit 2 ;;
            esac
          done

          DATS="$STAGING/dats"
          IN="$STAGING/roms-unverified"
          OUT="$STAGING/roms-verified"
          UNMATCHED="$STAGING/roms-unmatched"
          REPORTS="$STAGING/reports"

          mkdir -p "$DATS" "$IN" "$OUT" "$UNMATCHED" "$REPORTS"

          # Without DATs igir matches nothing, renames nothing, and cheerfully
          # reports every file as unknown -- a run that looks like it worked and
          # did nothing. Refuse instead.
          if [ -z "$(find "$DATS" -type f \( -name '*.dat' -o -name '*.xml' \) -print -quit)" ]; then
            cat >&2 <<EOF
          No DAT files in $DATS

          DATs cannot be fetched reproducibly -- No-Intro is behind a web form and
          Redump is per-platform -- so they are hand-supplied state. Download them
          and drop them in:

            cartridges: https://datomatic.no-intro.org/index.php?page=download&op=daily
            optical:    http://redump.org/downloads/
          EOF
            exit 1
          fi

          if [ -z "$(find "$IN" -type f -print -quit)" ]; then
            echo "No input ROMs in $IN -- copy the collection there first, e.g." >&2
            echo "  cp -r ~/.config/retroarch/roms/. $IN/" >&2
            exit 1
          fi

          echo "==> Pass 1: DAT-verified retail ROMs -> $OUT/{platform}/"
          igir move extract playlist report test \
            --dat "$DATS" \
            --input "$IN" \
            --output "$OUT/{romm}/" \
            --input-checksum-quick false \
            --input-checksum-min CRC32 \
            --only-retail \
            --merge-discs \
            --report-output "$REPORTS/igir-%YYYY-%MM-%DDT%HH-%mm-%ss.csv"

          # Whatever pass 1 could not identify is still in $IN: homebrew, hacks,
          # bad dumps, and anything --only-retail excluded. It goes to its own
          # tree rather than into $OUT, because --dir-mirror would preserve the
          # original folder names (GB, GBA, MEGADRIVE) and RomM only recognises
          # its own lowercase platform slugs. Sorting these is a judgement call,
          # so it stays a human one.
          if [ -n "$(find "$IN" -type f -print -quit)" ]; then
            echo "==> Pass 2: unidentified leftovers -> $UNMATCHED/ (structure preserved)"
            igir move \
              --input "$IN" \
              --output "$UNMATCHED" \
              --dir-mirror
          fi

          echo
          echo "verified:  $(find "$OUT" -type f | wc -l) files in $OUT"
          echo "unmatched: $(find "$UNMATCHED" -type f | wc -l) files in $UNMATCHED"
          echo "report:    $(find "$REPORTS" -type f -name '*.csv' -printf '%T@ %p\n' \
            | sort -rn | head -1 | cut -d' ' -f2-)"

          if [ "$PROMOTE" -eq 1 ]; then
            echo
            echo "==> Promoting $OUT -> ${library}/roms/"
            # --chmod so the service can rewrite what we drop in; -a alone
            # would carry the staging tree's modes and lock RomM out of its own
            # library.
            #
            # --no-owner --no-group matter as much as the mode: -a implies -g,
            # which preserves the staging tree's group and so OVERRIDES the
            # setgid bit on the destination directories. Files then land
            # tunnel:users, and with 0660 the romm uid -- which is only ever in
            # group romm -- cannot read its own library at all. Dropping -o/-g
            # lets setgid do what it is there for.
            # --omit-dir-times because the platform directories are owned by
            # romm, and only their owner may set their mtime; without it rsync
            # exits 23 on every one of them after transferring the files fine.
            rsync -a --no-owner --no-group --omit-dir-times \
              --chmod=D2770,F0660 --info=stats1 "$OUT/" "${library}/roms/"
            echo "Done. Run a scan from the RomM UI."
          else
            cat <<EOF

          Nothing was written to the live library. Check $OUT, then either rerun
          with --promote or copy it yourself:

            rsync -a --no-owner --no-group --omit-dir-times \
              --chmod=D2770,F0660 "$OUT/" "${library}/roms/"

          Sort $UNMATCHED into RomM platform slugs by hand before promoting it.
          EOF
          fi
        '';
      };

      romm-save-rename = pkgs.writeShellApplication {
        name = "romm-save-rename";
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          gawk
        ];
        text = ''
          SAVES="$HOME/.config/retroarch/saves"
          OLD_ROMS="$HOME/.config/retroarch/roms"
          NEW_ROMS="${staging}/roms-verified"
          OUT="${staging}/saves-flat"
          APPLY=0

          while [ $# -gt 0 ]; do
            case "$1" in
              --saves) SAVES="$2"; shift 2 ;;
              --old-roms) OLD_ROMS="$2"; shift 2 ;;
              --new-roms) NEW_ROMS="$2"; shift 2 ;;
              --out) OUT="$2"; shift 2 ;;
              --apply) APPLY=1; shift ;;
              -h|--help)
                cat <<'USAGE'
          romm-save-rename [--saves DIR] [--old-roms DIR] [--new-roms DIR] [--out DIR] [--apply]

            Renames save files to follow the names igir gave their ROMs, and
            flattens RetroArch's per-core save subdirectories into one directory
            keyed by filename -- which is what RomM and Grout match on.

            The old->new name map is derived by hashing both ROM trees: a file
            with the same SHA-1 in both is the same ROM, so its save follows the
            new name. Saves whose ROM was not renamed keep their filename.

            Only save files are considered -- the extensions Grout syncs
            (.srm .sav .dsv .mcr .mcd .brm .eep .sra .fla .mpk .nv). Save states
            in the same tree are left where they are: they are core-specific and
            never sync.

            Dry run by default. Copies, never moves: the original saves tree is
            left untouched so it stays the fallback until the migration is
            proven.
          USAGE
                exit 0 ;;
              *) echo "unknown argument: $1" >&2; exit 2 ;;
            esac
          done

          for d in "$SAVES" "$OLD_ROMS" "$NEW_ROMS"; do
            [ -d "$d" ] || { echo "not a directory: $d" >&2; exit 1; }
          done

          work="$(mktemp -d)"
          trap 'rm -rf "$work"' EXIT

          # hash <TAB> basename-without-extension, for both trees.
          hash_tree() {
            find "$1" -type f -print0 \
              | xargs -0 -r sha1sum \
              | awk -F'  ' '{
                  n = $2
                  sub(/.*\//, "", n)
                  sub(/\.[^.]*$/, "", n)
                  print $1 "\t" n
                }'
          }

          echo "==> Hashing $OLD_ROMS" >&2
          hash_tree "$OLD_ROMS" | sort -u > "$work/old"
          echo "==> Hashing $NEW_ROMS" >&2
          hash_tree "$NEW_ROMS" | sort -u > "$work/new"

          # join on the hash -> old name <TAB> new name. A ROM present under two
          # names on the old side legitimately produces two entries; identical
          # old and new names are dropped as no-ops.
          join -t "$(printf '\t')" -j 1 -o 1.2,2.2 "$work/old" "$work/new" \
            | awk -F'\t' '$1 != $2' | sort -u > "$work/map"

          echo "==> $(wc -l < "$work/map") ROMs were renamed by igir" >&2

          mkdir -p "$OUT"
          collisions="$work/collisions"
          : > "$collisions"
          planned="$work/planned"
          : > "$planned"

          while IFS= read -r -d "" src; do
            file="''${src##*/}"
            base="''${file%.*}"
            ext="''${file##*.}"

            new="$(awk -F'\t' -v b="$base" '$1 == b { print $2; exit }' "$work/map")"
            [ -n "$new" ] || new="$base"

            target="$new.$ext"

            # Two cores holding a save for the same game collapse to one target
            # here. Picking a winner by directory order would silently discard a
            # playthrough, so record both and skip.
            prev="$(awk -F'\t' -v t="$target" '$1 == t { print $2; exit }' "$planned")"
            if [ -n "$prev" ] && [ "$prev" != "$src" ]; then
              printf '%s\t%s\t%s\n' "$target" "$prev" "$src" >> "$collisions"
              continue
            fi

            printf '%s\t%s\n' "$target" "$src" >> "$planned"
          done < <(find "$SAVES" -type f \( \
            -iname '*.srm' -o -iname '*.sav' -o -iname '*.dsv' -o -iname '*.mcr' \
            -o -iname '*.mcd' -o -iname '*.brm' -o -iname '*.eep' -o -iname '*.sra' \
            -o -iname '*.fla' -o -iname '*.mpk' -o -iname '*.nv' \) -print0)

          # Drop every target that turned out to be contested, including the
          # first source that claimed it. Matched on the first field only: a
          # substring match would also strike out rows whose source path
          # happens to contain a contested filename.
          if [ -s "$collisions" ]; then
            cut -f1 "$collisions" | sort -u > "$work/contested"
            awk -F'\t' 'NR == FNR { bad[$0] = 1; next } !($1 in bad)' \
              "$work/contested" "$planned" > "$work/planned.clean"
            mv "$work/planned.clean" "$planned"
          fi

          echo
          echo "$(wc -l < "$planned") saves to write into $OUT"

          if [ -s "$collisions" ]; then
            echo
            echo "SKIPPED -- $(cut -f1 "$collisions" | sort -u | wc -l) filenames claimed by more than one save:"
            echo
            while IFS=$'\t' read -r target a b; do
              printf '  %s\n' "$target"
              for f in "$a" "$b"; do
                printf '      %s  %s  %s\n' \
                  "$(date -r "$f" '+%Y-%m-%d %H:%M')" \
                  "$(stat -c '%8s' "$f")" \
                  "$f"
              done
            done < "$collisions"
            echo
            echo "  Pick one of each by hand -- mtime and size are shown above --"
            echo "  and copy it into $OUT yourself. Most of these are stale cores"
            echo "  you stopped using, but some are real second playthroughs."
          fi

          if [ "$APPLY" -eq 0 ]; then
            echo
            echo "Dry run. Rerun with --apply to write $OUT."
            exit 0
          fi

          while IFS=$'\t' read -r target src; do
            cp -n -- "$src" "$OUT/$target"
          done < "$planned"

          echo
          echo "Wrote $OUT. Originals under $SAVES are untouched."
        '';
      };

      romm-save-upload = pkgs.writeShellApplication {
        name = "romm-save-upload";
        runtimeInputs = with pkgs; [
          curl
          jq
          coreutils
          findutils
        ];
        text = ''
          URL="https://rom.finnrut.is"
          SAVES="${staging}/saves-flat"
          TOKEN_FILE="${tokenPath}"
          APPLY=0

          while [ $# -gt 0 ]; do
            case "$1" in
              --url) URL="$2"; shift 2 ;;
              --saves) SAVES="$2"; shift 2 ;;
              --token-file) TOKEN_FILE="$2"; shift 2 ;;
              --apply) APPLY=1; shift ;;
              -h|--help)
                cat <<'USAGE'
          romm-save-upload [--url URL] [--saves DIR] [--token-file PATH] [--apply]

            Seeds RomM with existing save files over the documented API. Matches
            each save to a ROM by filename, the same way Grout does, so run
            romm-save-rename first and scan the library in RomM before this.

            Auth is a RomM Client API Token with the assets.write and roms.read
            scopes (Settings -> API tokens), read from agenix by default. The
            token goes to /api/, which is bypassed at the Cloudflare edge, so
            this works off-LAN.

            Dry run by default.
          USAGE
                exit 0 ;;
              *) echo "unknown argument: $1" >&2; exit 2 ;;
            esac
          done

          [ -r "$TOKEN_FILE" ] || {
            cat >&2 <<EOF
          Cannot read the RomM API token at $TOKEN_FILE

          It comes from agenix. In the nix-secrets repo:

            "media/romm-api-token.age".publicKeys = users ++ systems;
            agenix -e media/romm-api-token.age    # the rmm_... token, one line

          then push, and here: nix flake update secrets && colmena apply.
          EOF
            exit 1
          }
          TOKEN="$(tr -d '\n' < "$TOKEN_FILE")"

          [ -d "$SAVES" ] || { echo "not a directory: $SAVES" >&2; exit 1; }

          api() {
            curl -sS --fail-with-body -H "Authorization: Bearer $TOKEN" "$@"
          }

          work="$(mktemp -d)"
          trap 'rm -rf "$work"' EXIT

          echo "==> Fetching the ROM library from $URL" >&2
          offset=0
          limit=500
          : > "$work/roms"
          while :; do
            page="$(api "$URL/api/roms?limit=$limit&offset=$offset")"
            # RomM has returned both a bare array and a paginated envelope
            # across versions; accept either. fs_name is the on-disk filename,
            # which is what the save has to match.
            count="$(jq -r '(.items // .) | length' <<<"$page")"
            jq -r '(.items // .)[] | [.id, (.fs_name // .file_name)] | @tsv' \
              <<<"$page" >> "$work/roms"
            [ "$count" -lt "$limit" ] && break
            offset=$(( offset + limit ))
          done

          # id <TAB> basename-without-extension
          awk -F'\t' '{ n = $2; sub(/\.[^.]*$/, "", n); print $1 "\t" n }' \
            "$work/roms" | sort -u -k2 > "$work/index"

          echo "==> $(wc -l < "$work/index") ROMs in the library" >&2
          echo

          matched=0
          unmatched=0

          while IFS= read -r -d "" save; do
            file="''${save##*/}"
            base="''${file%.*}"

            id="$(awk -F'\t' -v b="$base" '$2 == b { print $1; exit }' "$work/index")"

            if [ -z "$id" ]; then
              printf 'no ROM matches  %s\n' "$file"
              unmatched=$(( unmatched + 1 ))
              continue
            fi

            matched=$(( matched + 1 ))
            if [ "$APPLY" -eq 0 ]; then
              printf 'would upload    %s -> rom %s\n' "$file" "$id"
              continue
            fi

            printf 'uploading       %s -> rom %s ... ' "$file" "$id"
            # emulator is deliberately omitted: the saves were flattened out of
            # their per-core directories, so claiming one would be a guess, and
            # save files are interchangeable across cores of a platform anyway.
            if api -X POST "$URL/api/saves?rom_id=$id" \
                 -F "saveFile=@$save" >/dev/null; then
              echo "ok"
            else
              echo "FAILED"
            fi
          done < <(find "$SAVES" -maxdepth 1 -type f -print0)

          echo
          echo "matched: $matched   unmatched: $unmatched"
          if [ "$unmatched" -gt 0 ]; then
            echo
            echo "Unmatched saves are games whose ROM is not in the library, or"
            echo "whose name still differs from it. Neither is fixed by retrying:"
            echo "check the library scan and romm-save-rename's output first."
          fi
          if [ "$APPLY" -eq 0 ]; then
            echo
            echo "Dry run. Rerun with --apply to upload."
          fi
        '';
      };
    in
    {
      # Owner is the login user, not romm: these are hand-run migration tools,
      # and nothing decrypts this on the service's behalf.
      age.secrets."romm-api-token" = {
        file = "${inputs.secrets}/media/romm-api-token.age";
        mode = "400";
        owner = "tunnel";
        group = "users";
      };

      environment.systemPackages = [
        romm-igir-import
        romm-save-rename
        romm-save-upload
      ];
    };
}
