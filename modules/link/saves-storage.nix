# Local version history, off-host copies and the recovery path for the RetroArch
# save authority. Everything else in this system can be rebuilt from a flake or
# re-downloaded; a battery save cannot, and the moment a WebDAV endpoint starts
# accepting PUTs from three clients the save tree becomes the one dataset here
# with no second copy anywhere.
#
# WHY A NESTED SUBVOLUME AND NOT A MOUNT
#
# /media/Data is subvol=@music (subvolid 257) on 4Tera, and the SAME subvolume
# is also mounted at /volume1/Media. Nothing on that device is mounted
# subvolid=5, so there is no top-level view to hang a `fileSystems` entry off,
# and adding one would give @music a third mountpoint for no gain. Snapshotting
# @music wholesale is worse: it pins every deleted media file -- Music/,
# TranscodedMusic/, ~1 GB of stray .mkv sitting at the top level -- so the first
# cleanup anyone attempts frees nothing until 12 months of monthly snapshots
# expire, on a disk already 73% full. The subvolume therefore has to be narrow
# and dedicated, and a nested subvolume inside the existing @music mount is
# exactly that: btrfs snapshots it independently, and no mount unit, no
# fileSystems entry and no second mountpoint appear anywhere.
#
# The price is that Nix cannot create it. systemd-tmpfiles has no subvolume verb
# that is safe here (`v` silently degrades to mkdir on a non-btrfs target, which
# is precisely the failure this module exists to make impossible), so creation is
# a one-time operator action and every tool below refuses loudly, with the exact
# command, until it has happened. The snapshot, quarantine and export
# directories ARE plain directories and tmpfiles owns those.
#
# WHY A DEDICATED restic BACKUP AND NOT infra.backup.srvPaths
#
#   (a) default-restic-options passes --one-file-system. A btrfs subvolume is a
#       distinct st_dev, so `restic-backups-srv` would walk right past the save
#       tree and report success. The offsite layer would break at the exact
#       moment the local layer was added, and nothing would say so.
#   (b) The backup target is not the live tree, it is the newest COMPLETED
#       read-only btrbk snapshot. That path carries a timestamp and is chosen at
#       runtime; srvPaths holds string literals and cannot express it.
#   (c) srvPaths has no per-path precondition hook. This backup must be gated by
#       a freshness guard that FAILS the unit rather than shipping a copy that is
#       already behind the live tree, and a failing guard on a shared unit would
#       take the other srv paths down with it.
#
# WHY btrbk BRINGS A PASSWORDLESS-ROOT SURFACE
#
# services.btrbk unconditionally adds a NOPASSWD sudo rule for user `btrbk` over
# ${pkgs.btrfs-progs}/bin/btrfs and /run/current-system/sw/bin/btrfs -- which
# includes `btrfs subvolume delete` against ANY path on the system, not just the
# ones named here -- plus mkdir and readlink. That is not configurable and not
# optional: the module's backend is btrfs-progs-sudo and it runs the service as
# an unprivileged user. It is the price of the module, it is new attack surface
# on link, and it is written down here rather than discovered later.
#
# Snapshots are ALWAYS read-only in btrbk. There is no config key that changes
# that, and the recovery tools below therefore never restore in place: they
# `btrfs subvolume snapshot <ro-snap> <dest>` WITHOUT -r into a quarantine
# namespace. Flipping ro=false on a btrbk snapshot instead would clear its
# Received UUID bookkeeping and make btrbk treat it as an unrelated subvolume.
{ config, lib, ... }:
let
  inventory = config.flake.saveSyncInventory;

  dataDir = inventory.webdav.dataDir;
  snapshotDir = inventory.webdav.snapshotDir;

  # btrbk addresses a subvolume as <volume>/<name>, and snapshot_dir is resolved
  # relative to the volume -- so both are derived here rather than restated, and
  # an assertion below keeps the derivation honest if the policy moves either.
  volume = dirOf dataDir;
  subvolName = baseNameOf dataDir;
  snapshotDirRelative = lib.removePrefix "${volume}/" snapshotDir;

  # Recovery never writes into the live namespace, so it needs somewhere else to
  # write. Both live beside the snapshot directory on the same filesystem:
  # `btrfs subvolume snapshot` cannot cross filesystems, so a quarantine under
  # /tmp or /var would not work at all.
  quarantineDir = "${volume}/.retroarch-save-quarantine";
  exportDir = "${volume}/.retroarch-save-exports";

  instance = "retroarch-saves";
  resticTag = "retroarch-saves";

  markerDir = "/var/lib/retroarch-saves";
  offsiteMarker = "${markerDir}/offsite-last-success";
  textfileDir = "/var/lib/prometheus-node-exporter-text-files";

  # RetroArch keeps its Cloud Sync bookkeeping in core_assets_directory, which is
  # the one path in this whole system whose name gives no hint of what it holds.
  # Every recovery instruction that tells the operator to reset a client has to
  # name it, so it comes from the policy rather than from memory.
  manifestPath = "${inventory.clients.link.paths.coreAssets}/manifest.local";

  q = lib.escapeShellArg;

  # Built once and shared by perSystem.packages (operator tooling, shellcheck'd
  # and `nix run .#<name>`-able) and by link's own module (the metrics emitter
  # and the units that call the selector). Same derivations either way.
  mkTools = pkgs: rec {
    preflight = pkgs.writeShellApplication {
      name = "retroarch-saves-preflight";
      meta.description = "Assert the save subvolume and snapshot directory exist as declared";
      runtimeInputs = with pkgs; [
        btrfs-progs
        coreutils
      ];
      text = ''
        DATA=${q dataDir}
        SNAPS=${q snapshotDir}
        VOL=${q volume}
        QUIET=0

        while [ $# -gt 0 ]; do
          case "$1" in
            --quiet) QUIET=1; shift ;;
            -h|--help)
              echo "retroarch-saves-preflight [--quiet]"
              echo
              echo "  Exits 0 only when the save subvolume and the snapshot directory"
              echo "  are both present and shaped the way btrbk needs them. Prints the"
              echo "  fix, not just the fault, for every way they can be wrong."
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        done

        if [ ! -e "$DATA" ]; then
          cat >&2 <<EOF
        $DATA does not exist.

        The save subvolume is deliberately NOT created by Nix. systemd-tmpfiles
        can only make a plain directory here, and a plain directory would leave
        btrbk with nothing to snapshot while every other layer kept reporting
        success. Create it once, by hand, on link:

          sudo btrfs subvolume create $DATA

        then re-run this command.
        EOF
          exit 1
        fi

        if [ ! -d "$DATA" ]; then
          echo "$DATA exists but is not a directory. Move it aside by hand and re-run." >&2
          exit 1
        fi

        # A subvolume root is always inode 256. This is the one check that works
        # without CAP_SYS_ADMIN: `btrfs subvolume show` and `subvolume list` both
        # fail with EPERM for an unprivileged caller on this filesystem, so the
        # obvious test is unavailable to the operator tooling.
        data_ino=$(stat -c %i "$DATA")
        if [ "$data_ino" != 256 ]; then
          cat >&2 <<EOF
        $DATA is a plain directory, not a Btrfs subvolume (inode $data_ino; a
        subvolume root is always inode 256).

        btrbk will refuse it and no local version history will ever exist. Fix it
        without deleting anything:

          sudo mv $DATA $DATA.plain
          sudo btrfs subvolume create $DATA
          sudo rsync -a "$DATA.plain/" "$DATA/"

        Keep $DATA.plain until the first snapshot AND the first offsite backup
        have both been verified, then remove it by hand.
        EOF
          exit 1
        fi

        if [ "$(btrfs property get -ts "$DATA" ro 2>/dev/null || true)" = "ro=true" ]; then
          echo "$DATA is a read-only subvolume; the WebDAV endpoint cannot write to it." >&2
          echo "  sudo btrfs property set -ts $DATA ro false" >&2
          exit 1
        fi

        if [ ! -d "$SNAPS" ]; then
          cat >&2 <<EOF
        $SNAPS does not exist.

        btrbk does not create snapshot_dir; the tmpfiles rule in
        modules/link/saves-storage.nix does. If the host has been rebuilt since
        that module landed, run:

          sudo systemd-tmpfiles --create
        EOF
          exit 1
        fi

        if [ "$(stat -c %i "$SNAPS")" = 256 ]; then
          echo "$SNAPS is a subvolume; btrbk needs a plain directory to place snapshots in." >&2
          exit 1
        fi

        # Snapshots land in $SNAPS and can only be taken within one filesystem.
        if [ "$(stat -c %d "$VOL")" != "$(stat -c %d "$SNAPS")" ]; then
          echo "$SNAPS is not on the same filesystem as $VOL; btrfs cannot snapshot across it." >&2
          exit 1
        fi

        if [ "$QUIET" -eq 0 ]; then
          echo "subvolume:    $DATA (ok)"
          echo "snapshot dir: $SNAPS (ok)"
        fi
      '';
    };

    # One selector, four callers: the restic freshness guard, the restic
    # files-from producer, the metrics emitter and the operator. Keeping the
    # "which snapshot counts" rule in a single place is the point -- a second
    # implementation is how the backup and the alert start disagreeing about
    # what is current.
    snapshotSelect = pkgs.writeShellApplication {
      name = "retroarch-saves-snapshot-select";
      meta.description = "Resolve the newest completed read-only RetroArch save snapshot";
      runtimeInputs = with pkgs; [
        btrfs-progs
        coreutils
        findutils
        gawk
        preflight
      ];
      text = ''
        SNAPS=${q snapshotDir}
        DATA=${q dataDir}
        PREFIX=${q "${subvolName}."}
        MODE=report
        GUARD=0
        # Relative limit: how far the newest snapshot may trail the newest save
        # write. This, not an absolute age, is the correct staleness test --
        # snapshot_create is "onchange", so a week-old snapshot of a tree nobody
        # has touched in a week is exactly current, and an absolute threshold
        # would fail the backup for doing the right thing.
        MAX_LAG=7200
        # Absolute backstop, for the case the relative test cannot see: btrbk
        # stopped running AND nothing has been written since, or the subvolume is
        # empty so there is no mtime to compare against.
        MAX_AGE=2592000

        while [ $# -gt 0 ]; do
          case "$1" in
            --print)     MODE=print; shift ;;
            --timestamp) MODE=timestamp; shift ;;
            --guard)     GUARD=1; shift ;;
            --max-lag)   MAX_LAG="$2"; shift 2 ;;
            --max-age)   MAX_AGE="$2"; shift 2 ;;
            -h|--help)
              cat <<'USAGE'
        retroarch-saves-snapshot-select [--print|--timestamp] [--guard]
                                        [--max-lag SECONDS] [--max-age SECONDS]

          Picks the newest COMPLETED read-only btrbk snapshot of the save
          subvolume, skipping anything read-write or half-built.

          --print      emit only the snapshot path (restic --files-from input)
          --timestamp  emit only its creation time as a unix timestamp
          --guard      refuse, loudly and non-zero, if that snapshot trails the
                       live tree by more than --max-lag, or is older than
                       --max-age outright
        USAGE
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        done

        retroarch-saves-preflight --quiet

        best=""
        best_ts=0
        while IFS= read -r -d "" candidate; do
          base=$(basename "$candidate")
          case "$base" in
            "$PREFIX"*) ;;
            *) continue ;;
          esac
          # inode 256 => subvolume root; anything else in here is a stray
          # directory, not a snapshot.
          [ "$(stat -c %i "$candidate")" = 256 ] || continue
          # A read-write subvolume in the snapshot directory is either a restore
          # working copy or a snapshot btrfs never finished. Neither is a version
          # of anything, and backing one up would ship a torn tree.
          [ "$(btrfs property get -ts "$candidate" ro 2>/dev/null || true)" = "ro=true" ] || continue
          # %W is the btrfs otime, which for a snapshot is its creation time.
          # Unlike `btrfs subvolume show` it needs no privileges, and unlike
          # parsing the name out of timestamp_format it cannot be broken by
          # someone changing that format later.
          ts=$(stat -c %W "$candidate")
          case "$ts" in
            *[!0-9]*|"") ts=0 ;;
          esac
          [ "$ts" -gt "$best_ts" ] || continue
          best_ts="$ts"
          best="$candidate"
        done < <(find "$SNAPS" -mindepth 1 -maxdepth 1 -type d -print0)

        if [ -z "$best" ]; then
          cat >&2 <<EOF
        No completed read-only snapshot under $SNAPS.

        Nothing can be backed up offsite until one exists. Take one now:

          sudo systemctl start btrbk-${instance}.service
          journalctl -u btrbk-${instance}.service -n 40 --no-pager
        EOF
          exit 1
        fi

        case "$MODE" in
          print)     printf '%s\n' "$best"; ;;
          timestamp) printf '%s\n' "$best_ts"; ;;
        esac

        if [ "$GUARD" -eq 0 ] && [ "$MODE" != report ]; then
          exit 0
        fi

        now=$(date +%s)
        age=$(( now - best_ts ))
        # mtimes only. Nothing in this module ever reads a save's contents; the
        # newest write time is all the freshness test needs.
        data_newest=$(find "$DATA" -type f -printf '%T@\n' 2>/dev/null \
          | awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { printf "%d\n", m }')
        lag=$(( data_newest - best_ts ))

        if [ "$MODE" = report ]; then
          echo "snapshot:      $best"
          echo "created:       $(date -d "@$best_ts" -Is) ($age s ago)"
          if [ "$data_newest" -gt 0 ]; then
            echo "newest save:   $(date -d "@$data_newest" -Is)"
          else
            echo "newest save:   (no files under $DATA)"
          fi
          echo "lag:           $lag s (limit $MAX_LAG s)"
        fi

        if [ "$GUARD" -eq 1 ]; then
          if [ "$lag" -gt "$MAX_LAG" ]; then
            cat >&2 <<EOF
        REFUSING: the newest snapshot is behind the live save tree.

          snapshot     $best
          created      $(date -d "@$best_ts" -Is)
          newest save  $(date -d "@$data_newest" -Is)
          lag          $lag s, limit $MAX_LAG s

        Backing this up would put a copy offsite that is already missing the most
        recent save, and the unit would report success while doing it. Take a
        snapshot first, then retry the backup:

          sudo systemctl start btrbk-${instance}.service
          sudo systemctl start restic-backups-${instance}.service
        EOF
            exit 1
          fi
          if [ "$age" -gt "$MAX_AGE" ]; then
            cat >&2 <<EOF
        REFUSING: the newest snapshot is $age s old, past the $MAX_AGE s backstop.

        Nothing has been written to $DATA in that time either, so the relative
        check cannot see this. Either the save authority has been idle that long
        -- in which case say so and raise --max-age -- or btrbk has quietly
        stopped:

          systemctl status btrbk-${instance}.timer
          journalctl -u btrbk-${instance}.service -n 60 --no-pager
        EOF
            exit 1
          fi
        fi
      '';
    };

    versions = pkgs.writeShellApplication {
      name = "retroarch-saves-versions";
      meta.description = "List retained RetroArch save versions, local snapshots and offsite";
      runtimeInputs = with pkgs; [
        btrfs-progs
        coreutils
        findutils
        preflight
      ];
      text = ''
        SNAPS=${q snapshotDir}
        PREFIX=${q "${subvolName}."}

        if [ $# -gt 0 ]; then
          case "$1" in
            -h|--help)
              echo "retroarch-saves-versions"
              echo
              echo "  Lists every retained version of the save tree: local btrbk"
              echo "  snapshots first, then the offsite restic snapshots."
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        fi

        retroarch-saves-preflight --quiet

        echo "== local snapshots ($SNAPS)"
        printf '%-44s  %-25s  %-9s  %s\n' NAME CREATED STATE FILES
        found=0
        while IFS= read -r -d "" candidate; do
          base=$(basename "$candidate")
          case "$base" in
            "$PREFIX"*) ;;
            *) continue ;;
          esac
          [ "$(stat -c %i "$candidate")" = 256 ] || continue
          ro=$(btrfs property get -ts "$candidate" ro 2>/dev/null || echo "ro=?")
          case "$ro" in
            ro=true)  state=complete ;;
            ro=false) state=WRITABLE ;;
            *)        state=unknown ;;
          esac
          ts=$(stat -c %W "$candidate")
          case "$ts" in
            *[!0-9]*|"") ts=0 ;;
          esac
          files=$(find "$candidate" -type f 2>/dev/null | wc -l)
          printf '%-44s  %-25s  %-9s  %s\n' \
            "$base" "$(date -d "@$ts" -Is)" "$state" "$files"
          found=$(( found + 1 ))
        done < <(find "$SNAPS" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

        if [ "$found" -eq 0 ]; then
          echo "(none -- run: sudo systemctl start btrbk-${instance}.service)"
        fi
        echo
        echo "A snapshot marked WRITABLE is a restore working copy or an unfinished"
        echo "snapshot. It is not a version and nothing will ever back it up."

        echo
        echo "== offsite snapshots (restic, tag ${resticTag})"
        if command -v restic-onedrive >/dev/null 2>&1; then
          # restic-onedrive (modules/backup/restic.nix) wraps repository,
          # password file and rclone config behind sudo, so no credential is
          # typed, exported, or reachable from this process.
          restic-onedrive snapshots --tag ${resticTag} || {
            echo "restic could not list the repository; see the error above." >&2
            exit 1
          }
        else
          echo "(restic-onedrive is not on PATH -- run this on link, or by hand:)"
          echo "  restic-onedrive snapshots --tag ${resticTag}"
        fi
      '';
    };

    quarantine = pkgs.writeShellApplication {
      name = "retroarch-saves-quarantine";
      meta.description = "Restore a RetroArch save snapshot into the quarantine namespace";
      runtimeInputs = with pkgs; [
        btrfs-progs
        coreutils
        findutils
        preflight
        snapshotSelect
      ];
      text = ''
        SNAPS=${q snapshotDir}
        QUARANTINE=${q quarantineDir}
        DATA=${q dataDir}
        SNAPSHOT=""
        APPLY=0

        while [ $# -gt 0 ]; do
          case "$1" in
            --snapshot) SNAPSHOT="$2"; shift 2 ;;
            --newest)   SNAPSHOT=""; shift ;;
            --apply)    APPLY=1; shift ;;
            -h|--help)
              cat <<'USAGE'
        retroarch-saves-quarantine [--snapshot NAME | --newest] [--apply]

          Materialises a read-only btrbk snapshot as a WRITABLE copy in the
          quarantine namespace, so it can be inspected and compared without
          touching the live save tree. Dry run unless --apply.

          Nothing is ever restored in place. The snapshot itself stays read-only:
          flipping ro=false on a btrbk snapshot clears its Received UUID
          bookkeeping and makes btrbk treat it as an unrelated subvolume from
          then on, which quietly breaks its retention accounting.
        USAGE
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        done

        retroarch-saves-preflight --quiet

        if [ -z "$SNAPSHOT" ]; then
          SRC=$(retroarch-saves-snapshot-select --print)
        else
          SRC="$SNAPS/$SNAPSHOT"
        fi

        if [ ! -d "$SRC" ]; then
          echo "no such snapshot: $SRC" >&2
          echo "  retroarch-saves-versions" >&2
          exit 1
        fi
        if [ "$(btrfs property get -ts "$SRC" ro 2>/dev/null || true)" != "ro=true" ]; then
          echo "$SRC is not a completed read-only snapshot; refusing to copy it." >&2
          exit 1
        fi

        DEST="$QUARANTINE/$(basename "$SRC")"
        case "$DEST" in
          "$DATA"|"$DATA"/*)
            echo "refusing: quarantine destination is inside the live namespace." >&2
            exit 1 ;;
        esac

        if [ ! -d "$QUARANTINE" ]; then
          echo "$QUARANTINE does not exist -- run: sudo systemd-tmpfiles --create" >&2
          exit 1
        fi

        if [ -e "$DEST" ]; then
          echo "already quarantined: $DEST"
          echo "Nothing to do. To take a fresh copy, remove it deliberately first:"
          echo "  sudo btrfs subvolume delete $DEST"
          exit 0
        fi

        echo "source:      $SRC"
        echo "destination: $DEST"
        if [ "$APPLY" -eq 0 ]; then
          echo
          echo "Dry run. Rerun with --apply to create the writable copy:"
          echo "  sudo btrfs subvolume snapshot $SRC $DEST"
          exit 0
        fi

        command -v sudo >/dev/null 2>&1 || {
          echo "sudo is not on PATH; btrfs subvolume snapshot needs CAP_SYS_ADMIN." >&2
          exit 1
        }

        # No -r. The copy is meant to be poked at; the ORIGINAL stays read-only.
        sudo btrfs subvolume snapshot "$SRC" "$DEST"
        echo "quarantined $(find "$DEST" -type f | wc -l) files in $DEST"
        echo
        echo "Next: compare it against the live tree before deciding anything."
        echo "  retroarch-saves-inspect $DATA $DEST"
      '';
    };

    inspect = pkgs.writeShellApplication {
      name = "retroarch-saves-inspect";
      meta.description = "Compare RetroArch save candidates by size and hash only";
      runtimeInputs = with pkgs; [
        coreutils
        diffutils
        findutils
      ];
      text = ''
        DATA=${q dataDir}
        QUARANTINE=${q quarantineDir}

        if [ $# -gt 0 ] && { [ "$1" = -h ] || [ "$1" = --help ]; }; then
          cat <<'USAGE'
        retroarch-saves-inspect [DIR ...]

          Reports every save file in each tree as size + SHA-256, and with exactly
          two trees, which files differ. With no arguments it compares the live
          namespace against every quarantined candidate.

          It never prints, diffs or decodes save CONTENT. A battery save is the
          one artifact here whose bytes are worth nothing to a human and
          everything to the emulator, so the only questions this answers are "is
          it the same file" and "how big is it".
        USAGE
          exit 0
        fi

        TREES=("$@")
        if [ "''${#TREES[@]}" -eq 0 ]; then
          TREES=("$DATA")
          while IFS= read -r -d "" candidate; do
            TREES+=("$candidate")
          done < <(find "$QUARANTINE" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null | sort -z)
        fi

        work=$(mktemp -d)
        trap 'rm -rf "$work"' EXIT

        # The snapshots are created by root through btrbk's sudo rule, so their
        # contents are frequently unreadable to the operator. Escalate only for
        # the trees that need it, and say so.
        run() {
          if [ "$1" = sudo ]; then
            shift
            sudo "$@"
          else
            shift
            "$@"
          fi
        }

        n=0
        for tree in "''${TREES[@]}"; do
          if [ ! -d "$tree" ]; then
            echo "skipping $tree (not a directory)" >&2
            continue
          fi
          esc=direct
          if [ ! -r "$tree" ]; then
            command -v sudo >/dev/null 2>&1 || {
              echo "$tree is not readable and sudo is not available." >&2
              exit 1
            }
            esc=sudo
          fi
          n=$(( n + 1 ))
          out="$work/tree.$n"
          run "$esc" find "$tree" -type f -printf '%P\0' \
            | sort -z \
            | while IFS= read -r -d "" rel; do
                size=$(run "$esc" stat -c %s "$tree/$rel")
                hash=$(run "$esc" sha256sum "$tree/$rel" | cut -d' ' -f1)
                printf '%s  %12s  %s\n' "$hash" "$size" "$rel"
              done > "$out"
          bytes=$(awk '{ t += $2 } END { printf "%d\n", t }' "$out")
          echo "== $tree"
          [ "$esc" = direct ] || echo "   (read via sudo)"
          echo "   $(wc -l < "$out") files, $bytes bytes"
          cat "$out"
          echo
          printf '%s\n' "$tree" > "$work/name.$n"
        done

        if [ "$n" -eq 2 ]; then
          echo "== differences"
          a=$(cat "$work/name.1")
          b=$(cat "$work/name.2")
          if diff -u --label "$a" --label "$b" "$work/tree.1" "$work/tree.2"; then
            echo "identical: same files, same sizes, same hashes."
          else
            echo
            echo "Lines starting with - are only in, or differ in, $a."
            echo "Lines starting with + are only in, or differ in, $b."
            echo "A changed hash on the same path is the case that matters: two"
            echo "clients wrote the same game and one of these is the loser."
          fi
        elif [ "$n" -gt 2 ]; then
          echo "== differences"
          echo "(pass exactly two trees to get a diff; $n were given)"
        fi
      '';
    };

    promote = pkgs.writeShellApplication {
      name = "retroarch-saves-promote";
      meta.description = "Deliberately reseed the live RetroArch save namespace from a candidate";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        preflight
        rsync
      ];
      text = ''
        DATA=${q dataDir}
        QUARANTINE=${q quarantineDir}
        FROM=""
        APPLY=0
        FROZEN=0

        while [ $# -gt 0 ]; do
          case "$1" in
            --from)   FROM="$2"; shift 2 ;;
            --apply)  APPLY=1; shift ;;
            --i-have-frozen-every-client) FROZEN=1; shift ;;
            -h|--help)
              cat <<'USAGE'
        retroarch-saves-promote --from DIR [--apply --i-have-frozen-every-client]

          Replaces the contents of the live save namespace with a candidate from
          quarantine. This is the only tool here that writes to the live tree, it
          is a dry run by default, and --apply alone is NOT enough: the interlock
          flag has to be passed too, because the failure it guards against is not
          a bad candidate, it is a second client still running.

          Before it overwrites anything it copies the current live tree into
          quarantine, so the state being replaced remains readable afterwards.
        USAGE
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        done

        require_sudo() {
          command -v sudo >/dev/null 2>&1 || {
            echo "sudo is not on PATH; the live save tree is not writable as this user." >&2
            exit 1
          }
        }

        cat <<EOF
        == before promoting, in this order

        1. FREEZE every client. Quit RetroArch on link, force-quit it on the iOS
           device, and quit it on the RG Slide. A client left running will push
           its own copy back over the one you are about to promote the moment it
           unloads a core, and there is no queue and no retry to inspect
           afterwards -- RetroArch syncs on startup, on core UNLOAD, on menu
           "Sync Now", and on iOS resume after 60s backgrounded, and at no other
           time.
        2. Promote (this tool).
        3. DISCARD the stale sync manifests on every client, so none of them
           believes it already has the newest copy of a file that just changed
           underneath it:
             ${manifestPath}
           and manifest.server beside it. Same directory on the other clients:
           the policy calls it coreAssets. Delete both, do not edit them.
        4. CONNECT ONE CLIENT, let it complete a full sync, and confirm the game
           loads with the expected progress.
        5. Only then bring the remaining clients back, one at a time.

        EOF

        if [ -z "$FROM" ]; then
          echo "--from is required. Candidates:" >&2
          find "$QUARANTINE" -mindepth 1 -maxdepth 1 -type d 2>/dev/null >&2 || true
          echo "  retroarch-saves-versions" >&2
          exit 2
        fi
        if [ ! -d "$FROM" ]; then
          echo "no such candidate: $FROM" >&2
          exit 1
        fi

        retroarch-saves-preflight --quiet

        case "$FROM" in
          "$DATA"|"$DATA"/*)
            echo "refusing: --from is inside the live namespace; there is nothing to promote." >&2
            exit 1 ;;
        esac

        src_files=$(find "$FROM" -type f | wc -l)
        if [ "$src_files" -eq 0 ]; then
          echo "refusing: $FROM holds no files. Promoting it would empty the live namespace." >&2
          exit 1
        fi
        live_files=$(find "$DATA" -type f 2>/dev/null | wc -l)

        echo "candidate: $FROM ($src_files files)"
        echo "live:      $DATA ($live_files files)"
        echo

        if [ "$APPLY" -eq 0 ] || [ "$FROZEN" -eq 0 ]; then
          echo "Dry run -- nothing has been written."
          if [ "$APPLY" -eq 1 ] && [ "$FROZEN" -eq 0 ]; then
            echo
            echo "REFUSING: --apply was given without --i-have-frozen-every-client."
            echo "Step 1 above is the one that actually loses saves. Do it, then:"
          else
            echo "To promote, after step 1 above:"
          fi
          echo "  retroarch-saves-promote --from $FROM --apply --i-have-frozen-every-client"
          if [ "$APPLY" -eq 0 ]; then
            exit 0
          fi
          # --apply without the interlock is a refusal, not a dry run.
          exit 1
        fi

        require_sudo

        preserved="$QUARANTINE/pre-promote-$(date -u +%Y%m%dT%H%M%SZ)"
        echo "==> preserving the current live tree at $preserved"
        # A copy, not a move: the live namespace keeps its identity as a
        # subvolume and the state being replaced stays readable afterwards. The
        # btrbk snapshots are the real safety net; this is the one that does not
        # depend on a timer having fired recently.
        sudo mkdir -p "$preserved"
        sudo rsync -a "$DATA/" "$preserved/"

        echo "==> reseeding $DATA from $FROM"
        sudo rsync -a --delete "$FROM/" "$DATA/"

        echo
        echo "promoted. Now do steps 3, 4 and 5 above -- the promotion is not"
        echo "finished until one client has completed a full sync against it."
        echo "Preserved copy of what was replaced: $preserved"
      '';
    };

    export = pkgs.writeShellApplication {
      name = "retroarch-saves-export";
      meta.description = "Export raw RetroArch saves for migration to a future replacement";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        rsync
      ];
      text = ''
        DATA=${q dataDir}
        EXPORTS=${q exportDir}
        FROM=""
        TO=""
        APPLY=0

        while [ $# -gt 0 ]; do
          case "$1" in
            --from)  FROM="$2"; shift 2 ;;
            --to)    TO="$2"; shift 2 ;;
            --apply) APPLY=1; shift ;;
            -h|--help)
              cat <<'USAGE'
        retroarch-saves-export [--from DIR] [--to DIR] [--apply]

          Writes a self-describing copy of the raw save tree, for carrying the
          collection to whatever replaces this system. Reads one tree and writes
          another; it never moves or deletes an original. Dry run unless --apply.

          Sync bookkeeping is excluded, because it is meaningful only to the
          system that wrote it: .stfolder, .stversions/ and the
          *.sync-conflict-* files Syncthing left behind. Those conflict copies
          are not saves to migrate -- they are evidence of the failure mode this
          whole design exists to end, and they belong in the recovery record,
          not in a clean export.
        USAGE
              exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
          esac
        done

        [ -n "$FROM" ] || FROM="$DATA"
        [ -n "$TO" ] || TO="$EXPORTS/export-$(date -u +%Y%m%dT%H%M%SZ)"

        if [ ! -d "$FROM" ]; then
          echo "no such source: $FROM" >&2
          exit 1
        fi
        case "$TO" in
          "$DATA"|"$DATA"/*)
            echo "refusing: --to is inside the live namespace." >&2
            exit 1 ;;
        esac

        files=$(find "$FROM" -type f \
          -not -path '*/.stversions/*' \
          -not -name '.stfolder' \
          -not -name '*.sync-conflict-*' | wc -l)

        echo "source:      $FROM ($files files after exclusions)"
        echo "destination: $TO"

        if [ "$APPLY" -eq 0 ]; then
          echo
          echo "Dry run. Rerun with --apply to write the export."
          exit 0
        fi

        command -v sudo >/dev/null 2>&1 || {
          echo "sudo is not on PATH; snapshots are root-owned and cannot be read." >&2
          exit 1
        }

        if ! mkdir -p "$TO" 2>/dev/null; then
          sudo mkdir -p "$TO"
          sudo chown "$(id -un):$(id -gn)" "$TO"
        fi

        # sudo to READ: btrbk snapshots are created by root through the module's
        # sudo rule. --chown hands the copy back to the caller, so the manifest
        # below and every later step run unprivileged.
        sudo rsync -a \
          --exclude '.stfolder' \
          --exclude '.stversions/' \
          --exclude '*.sync-conflict-*' \
          --chown="$(id -un):$(id -gn)" \
          "$FROM/" "$TO/data/"

        # Sizes and hashes, never contents. This is the file that lets a future
        # importer prove it read the same bytes out that went in.
        find "$TO/data" -type f -printf '%P\0' | sort -z \
          | while IFS= read -r -d "" rel; do
              printf '%s  %s  %s\n' \
                "$(sha256sum "$TO/data/$rel" | cut -d' ' -f1)" \
                "$(stat -c %s "$TO/data/$rel")" \
                "$rel"
            done > "$TO/MANIFEST.sha256"

        cat > "$TO/README" <<EOF
        RetroArch save export, $(date -u -Is)

        data/           the raw save tree, exactly as RetroArch wrote it
        MANIFEST.sha256 sha256, size and relative path for every file in data/

        LAYOUT CONTRACT -- the directory name above each save is load-bearing.
        RetroArch was configured with sort_savefiles_by_content_enable = true and
        sort_savefiles_enable = false, so the directory holding a save is the
        ROM's immediate PARENT DIRECTORY name, not the core's display name. Those
        directory names are the emulated-system identifiers from the Core policy
        (gb, gba, snes, ...), and they are the same string on every client. An
        importer that flattens this tree, or that re-sorts it by core name, has
        silently forked every game's save history.

        Excluded on purpose: .stfolder, .stversions/, *.sync-conflict-*. Those are
        Syncthing bookkeeping and conflict debris, not saves.
        EOF

        echo "exported $(wc -l < "$TO/MANIFEST.sha256") files to $TO"
      '';
    };

    metrics = pkgs.writeShellApplication {
      name = "retroarch-saves-storage-metrics";
      meta.description = "Emit snapshot and offsite-backup age gauges for the textfile collector";
      runtimeInputs = with pkgs; [
        coreutils
        findutils
        gawk
        snapshotSelect
      ];
      text = ''
        metrics_dir=${q textfileDir}
        metrics_tmp="$metrics_dir/retroarch-saves.prom.tmp"
        metrics_out="$metrics_dir/retroarch-saves.prom"

        data=${q dataDir}
        snaps=${q snapshotDir}
        prefix=${q "${subvolName}."}
        marker=${q offsiteMarker}

        present=0
        if [ -d "$data" ] && [ "$(stat -c %i "$data")" = 256 ]; then
          present=1
        fi

        count=0
        if [ -d "$snaps" ]; then
          count=$(find "$snaps" -mindepth 1 -maxdepth 1 -type d -name "$prefix*" | wc -l)
        fi

        # The selector owns "which snapshot counts"; asking it here is what keeps
        # the alert and the backup from disagreeing about what is current.
        newest=$(retroarch-saves-snapshot-select --timestamp 2>/dev/null || echo 0)
        case "$newest" in
          *[!0-9]*|"") newest=0 ;;
        esac

        data_newest=0
        if [ "$present" -eq 1 ]; then
          data_newest=$(find "$data" -type f -printf '%T@\n' 2>/dev/null \
            | awk 'BEGIN { m = 0 } { if ($1 + 0 > m) m = $1 + 0 } END { printf "%d\n", m }')
        fi

        offsite=0
        if [ -e "$marker" ]; then
          offsite=$(stat -c %Y "$marker")
        fi

        {
          echo '# HELP retroarch_saves_subvolume_present Whether the save path is a Btrfs subvolume.'
          echo '# TYPE retroarch_saves_subvolume_present gauge'
          echo "retroarch_saves_subvolume_present $present"
          echo '# HELP retroarch_saves_snapshot_count Retained local btrbk snapshots of the save subvolume.'
          echo '# TYPE retroarch_saves_snapshot_count gauge'
          echo "retroarch_saves_snapshot_count $count"
          echo '# HELP retroarch_saves_snapshot_newest_timestamp_seconds Creation time of the newest completed read-only snapshot.'
          echo '# TYPE retroarch_saves_snapshot_newest_timestamp_seconds gauge'
          echo "retroarch_saves_snapshot_newest_timestamp_seconds $newest"
          echo '# HELP retroarch_saves_data_newest_mtime_seconds Newest file mtime in the live save tree.'
          echo '# TYPE retroarch_saves_data_newest_mtime_seconds gauge'
          echo "retroarch_saves_data_newest_mtime_seconds $data_newest"
          echo '# HELP retroarch_saves_offsite_last_success_timestamp_seconds Completion time of the last successful offsite backup.'
          echo '# TYPE retroarch_saves_offsite_last_success_timestamp_seconds gauge'
          echo "retroarch_saves_offsite_last_success_timestamp_seconds $offsite"
          echo '# HELP retroarch_saves_storage_metrics_timestamp_seconds When this collector last ran.'
          echo '# TYPE retroarch_saves_storage_metrics_timestamp_seconds gauge'
          echo "retroarch_saves_storage_metrics_timestamp_seconds $(date +%s)"
        } > "$metrics_tmp"
        chmod 0644 "$metrics_tmp"
        mv "$metrics_tmp" "$metrics_out"
      '';
    };
  };
in
{
  # Operator tooling: `nix run .#retroarch-saves-versions` and friends, and each
  # one becomes a shellcheck'd `packages/<name>` check for free. None of these
  # reads a secret, which is what lets them live here rather than on link only.
  perSystem =
    { pkgs, ... }:
    let
      tools = mkTools pkgs;
    in
    {
      packages = {
        retroarch-saves-preflight = tools.preflight;
        retroarch-saves-snapshot-select = tools.snapshotSelect;
        retroarch-saves-versions = tools.versions;
        retroarch-saves-quarantine = tools.quarantine;
        retroarch-saves-inspect = tools.inspect;
        retroarch-saves-promote = tools.promote;
        retroarch-saves-export = tools.export;
      };
    };

  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      tools = mkTools pkgs;
      rcloneCfg = config.infra.rclone;
      resticPkg = config.services.restic.backups.${instance}.package;
      resticCmd = "${lib.getExe resticPkg} -r ${config.infra.backup.repository} -p ${
        config.age.secrets."restic/password".path
      }";

      yaml = pkgs.formats.yaml { };

      storageRules = yaml.generate "retroarch-saves-storage-rules.yaml" {
        groups = [
          {
            # Distinct from the WebDAV endpoint's group on purpose: these alerts
            # are about whether a version of the data still exists, which stays
            # true or false regardless of whether anything can reach it.
            name = "retroarch-saves-storage";
            interval = "1m";
            rules = [
              {
                alert = "RetroarchSavesSubvolumeMissing";
                expr = ''retroarch_saves_subvolume_present{instance="link"} == 0'';
                for = "15m";
                labels.severity = "critical";
                annotations.summary = "${dataDir} is not a Btrfs subvolume; btrbk is snapshotting nothing";
              }
              {
                alert = "RetroarchSavesNoSnapshots";
                expr = ''retroarch_saves_snapshot_count{instance="link"} == 0'';
                for = "3h";
                labels.severity = "critical";
                annotations.summary = "No local btrbk snapshots of the RetroArch save subvolume exist";
              }
              {
                # Not an absolute age: snapshot_create is "onchange", so an old
                # snapshot of an untouched tree is correct. What is never correct
                # is the live tree having moved on without one following it.
                alert = "RetroarchSavesSnapshotStale";
                expr = ''retroarch_saves_data_newest_mtime_seconds{instance="link"} > retroarch_saves_snapshot_newest_timestamp_seconds{instance="link"} + 7200'';
                for = "30m";
                labels.severity = "warning";
                annotations.summary = "RetroArch saves changed more than 2h ago with no snapshot since";
              }
              {
                alert = "RetroarchSavesOffsiteBackupStale";
                expr = ''time() - retroarch_saves_offsite_last_success_timestamp_seconds{instance="link"} > 172800'';
                for = "1h";
                labels.severity = "critical";
                annotations.summary = "RetroArch saves have not reached the offsite repository in 48h";
              }
              {
                # Without this, a dead collector freezes every gauge above at its
                # last good value and the presence and count alerts go quiet
                # forever. The offsite alert would still fire eventually because
                # it is written against time(), but it is the only one that would.
                alert = "RetroarchSavesStorageMetricsStale";
                expr = ''time() - retroarch_saves_storage_metrics_timestamp_seconds{instance="link"} > 1800'';
                for = "15m";
                labels.severity = "warning";
                annotations.summary = "RetroArch save storage metrics have stopped refreshing";
              }
              # Unit-level failure of btrbk-retroarch-saves,
              # restic-backups-retroarch-saves and restic-forget-retroarch-saves
              # is deliberately NOT alerted here: the node exporter's systemd
              # collector already feeds the generic SystemdUnitFailed rule in
              # modules/link/observability.nix, and each unit carries
              # onFailure = notify-telegram@%n. A fourth copy of the same signal
              # would only make the real ones easier to ignore.
            ];
          }
        ];
      };
    in
    {
      assertions = [
        {
          # btrbk resolves snapshot_dir relative to the volume, so the relative
          # path derived above is only correct while the policy keeps the
          # snapshot directory a direct child of the volume that holds dataDir.
          assertion = dirOf snapshotDir == volume;
          message = ''
            saveSync.webdav.snapshotDir (${snapshotDir}) must be a direct child of
            ${volume}, the Btrfs volume holding saveSync.webdav.dataDir. btrbk's
            snapshot_dir is relative to the volume and cannot address anything else.
          '';
        }
      ];

      systemd.tmpfiles.rules = [
        # NOT the save subvolume itself. tmpfiles has no verb that creates a
        # Btrfs subvolume and fails when it cannot: `v` degrades to a plain
        # mkdir, which is the exact silent failure this module is built to
        # prevent. Creation stays a one-time operator action.
        #
        # Owned by btrbk so it can place and reap snapshots without needing its
        # sudo rule for the directory operations too.
        "d ${snapshotDir} 0755 btrbk btrbk -"
        "d ${quarantineDir} 0755 root root -"
        "d ${exportDir} 0755 tunnel users -"
        "d ${markerDir} 0755 root root -"
      ];

      services.btrbk.instances.${instance} = {
        # The module default is "daily", which cannot satisfy 48h of hourly
        # retention -- btrbk would dutifully keep 48 hourly slots and never fill
        # more than one a day.
        onCalendar = "hourly";
        # Left false on purpose. snapshotOnly and "no target" are orthogonal:
        # omitting `target` below is what makes this snapshot-only, while
        # snapshotOnly changes the subcommand from `run` to `snapshot` and would
        # imply there is a target being deferred. There isn't one -- offsite is
        # restic's job, from the snapshot, over rclone.
        snapshotOnly = false;
        settings = {
          # snapshot_preserve_min defaults to "all", which makes snapshot_preserve
          # SILENTLY INERT: btrbk keeps everything and the retention line reads
          # like it is doing something. On a disk already 73% full that is a slow
          # leak nobody notices. "latest" is the floor that still guarantees the
          # newest snapshot is never the one reaped.
          snapshot_preserve_min = "latest";
          snapshot_preserve = "48h 30d 12m";
          # Save files change in bursts and then not at all for weeks. "always"
          # would mint 48 byte-identical hourly snapshots of an idle tree, each
          # one another set of metadata to reap later, and would make snapshot
          # age useless as a health signal. "onchange" compares the subvolume
          # generation and skips when nothing moved -- which is why the freshness
          # guard and the staleness alert are both written against the newest
          # save mtime rather than against wall-clock age.
          snapshot_create = "onchange";
          # The default "long" format is YYYYMMDDThhmm with no zone. On an hourly
          # instance that collides on the autumn DST fallback, when 01:00-02:00
          # happens twice: two snapshots want one name. "long-iso" carries seconds
          # and the UTC offset, so the repeated hour produces two distinct,
          # correctly-ordered names.
          timestamp_format = "long-iso";
          volume.${volume} = {
            snapshot_dir = snapshotDirRelative;
            # No `target`: snapshot-only. Snapshots are always read-only in btrbk
            # and there is no key that changes that -- the recovery tools take a
            # writable copy instead of ever touching these.
            subvolume.${subvolName} = { };
          };
        };
      };

      systemd.services."btrbk-${instance}".onFailure = [ "notify-telegram@%n.service" ];

      # Offsite. Everything default-restic-options gives the other units --
      # repository, password file, mutable rclone config, initialize,
      # --exclude-caches, --retry-lock 2h, rclone-seed ordering, Telegram on
      # failure -- with two deliberate departures.
      services.restic.backups.${instance} = {
        inherit (config.infra.backup) repository;
        passwordFile = config.age.secrets."restic/password".path;
        rcloneConfigFile = rcloneCfg.configFile;
        initialize = true;

        # Guard first: preStart runs with `set -e`, so a stale or missing
        # snapshot fails the unit here, before restic touches the network. The
        # alternative -- discovering it inside restic -- is a successful backup
        # of the wrong thing.
        backupPrepareCommand = ''
          #!${pkgs.runtimeShell}
          exec ${lib.getExe tools.snapshotSelect} --guard
        '';
        # The target path is chosen at runtime and is never the live tree.
        dynamicFilesFrom = ''
          #!${pkgs.runtimeShell}
          exec ${lib.getExe tools.snapshotSelect} --print
        '';

        extraBackupArgs = [
          "--exclude-caches"
          "--retry-lock 2h"
          # NOT --one-file-system. It is in default-restic-options and it is the
          # reason this unit exists at all: the target IS a subvolume, so on the
          # shared srv unit it would be skipped without a word.
          #
          # Every run names a different snapshot directory, so restic's default
          # --group-by host,paths would put each snapshot in a group of one: no
          # parent is ever found, and -- worse -- the repo-wide `restic-prune`
          # unit would evaluate each group separately and keep every snapshot
          # forever. A stable tag fixes both ends.
          "--tag ${resticTag}"
          "--group-by host,tags"
        ];

        # 02:00: clear of `home` (00:00 +20m), `srv` (01:00 +20m) and the
        # repo-wide `restic-prune` (03:00 +20m), so no two rclone processes ever
        # refresh the rotating OneDrive token at once.
        timerConfig = {
          OnCalendar = "02:00";
          Persistent = true;
          RandomizedDelaySec = "20m";
        };
      };

      systemd.services = {
        "restic-backups-${instance}" = {
          path = [ rcloneCfg.package ];
          wants = [ "rclone-seed.service" ];
          after = [ "rclone-seed.service" ];
          onFailure = [ "notify-telegram@%n.service" ];
          # ExecStartPost runs only when every ExecStart line succeeded, which
          # makes this marker mean "the last time saves actually reached
          # OneDrive" rather than "the last time the unit stopped". Reading
          # InactiveEnterTimestamp instead would let a failing run overwrite the
          # last known-good time and hide how long the gap has really been.
          serviceConfig.ExecStartPost = "${lib.getExe' pkgs.coreutils "touch"} ${offsiteMarker}";
        };

        # Retention for this tag only. The repo-wide restic-prune groups by
        # host,paths and would therefore never expire a single one of these --
        # every snapshot is its own group of one and --keep-daily 14 keeps it.
        # Forget without --prune takes a shared lock and only drops references;
        # the 03:00 prune reclaims the space on its next pass, so there is still
        # exactly one prune in this repository.
        #
        # The keep window mirrors retentionOpts in modules/backup/restic.nix. It
        # is restated rather than shared because that list is a private let
        # binding in a module this one does not own.
        "restic-forget-${instance}" = {
          description = "Expire offsite RetroArch save snapshots (tag ${resticTag})";
          path = [ rcloneCfg.package ];
          wants = [
            "rclone-seed.service"
            "network-online.target"
          ];
          after = [
            "rclone-seed.service"
            "network-online.target"
          ];
          onFailure = [ "notify-telegram@%n.service" ];
          serviceConfig = {
            Type = "oneshot";
            Environment = "RCLONE_CONFIG=${rcloneCfg.configFile}";
            ExecStart = "${resticCmd} forget --tag ${resticTag} --group-by host,tags --retry-lock 2h --keep-last 7 --keep-daily 14 --keep-weekly 8 --keep-monthly 12 --keep-yearly 5";
          };
        };

        retroarch-saves-storage-metrics = {
          description = "Export RetroArch save snapshot and backup age metrics";
          serviceConfig = {
            Type = "oneshot";
            ExecStart = lib.getExe tools.metrics;
            NoNewPrivileges = true;
            PrivateTmp = true;
            ProtectHome = true;
            ProtectSystem = "strict";
            # /media/Data is read for stat and readdir only -- ProtectSystem
            # strict leaves it readable, and nothing here needs to write there.
            ReadWritePaths = [ textfileDir ];
          };
        };
      };

      systemd.timers = {
        "restic-forget-${instance}" = {
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnCalendar = "04:00";
            Persistent = true;
            RandomizedDelaySec = "20m";
          };
        };

        retroarch-saves-storage-metrics = {
          description = "Refresh RetroArch save storage metrics";
          wantedBy = [ "timers.target" ];
          timerConfig = {
            OnBootSec = "3m";
            OnUnitActiveSec = "5m";
            Unit = "retroarch-saves-storage-metrics.service";
          };
        };
      };

      services.prometheus.ruleFiles = lib.mkAfter [ storageRules ];

      # Hand-run recovery, in the order the runbook uses them. The offsite
      # restore is the one that must read an agenix path at runtime, which is
      # why it is built here against the host's config rather than shipped as a
      # portable perSystem package like the rest.
      environment.systemPackages = [
        tools.preflight
        tools.snapshotSelect
        tools.versions
        tools.quarantine
        tools.inspect
        tools.promote
        tools.export
        (pkgs.writeShellApplication {
          name = "retroarch-saves-offsite-restore";
          meta.description = "Restore an offsite RetroArch save snapshot into quarantine";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            rcloneCfg.package
            resticPkg
          ];
          text = ''
            QUARANTINE=${q quarantineDir}
            DATA=${q dataDir}
            SNAPSHOT=latest
            APPLY=0

            while [ $# -gt 0 ]; do
              case "$1" in
                --snapshot) SNAPSHOT="$2"; shift 2 ;;
                --apply)    APPLY=1; shift ;;
                -h|--help)
                  cat <<'USAGE'
            retroarch-saves-offsite-restore [--snapshot ID] [--apply]

              Restores an offsite restic snapshot into the quarantine namespace,
              never into the live save tree. Dry run unless --apply.

              Run this as root: the repository password is an agenix path readable
              only by root, and it is passed by path so nothing is exported into
              the environment or typed on a command line.
            USAGE
                  exit 0 ;;
                *) echo "unknown argument: $1" >&2; exit 2 ;;
              esac
            done

            if [ ! -r ${config.age.secrets."restic/password".path} ]; then
              echo "cannot read the restic password; run this as root:" >&2
              echo "  sudo retroarch-saves-offsite-restore $*" >&2
              exit 1
            fi

            export RCLONE_CONFIG=${rcloneCfg.configFile}

            DEST="$QUARANTINE/offsite-$SNAPSHOT-$(date -u +%Y%m%dT%H%M%SZ)"
            case "$DEST" in
              "$DATA"|"$DATA"/*)
                echo "refusing: destination is inside the live namespace." >&2
                exit 1 ;;
            esac

            echo "== offsite snapshots (tag ${resticTag})"
            ${resticCmd} snapshots --tag ${resticTag} --retry-lock 2h

            echo
            echo "restoring: $SNAPSHOT"
            echo "into:      $DEST"

            if [ "$APPLY" -eq 0 ]; then
              echo
              echo "Dry run. Rerun with --apply to restore."
              exit 0
            fi

            mkdir -p "$DEST"
            ${resticCmd} restore "$SNAPSHOT" --tag ${resticTag} --target "$DEST" --retry-lock 2h

            echo
            echo "restored under $DEST -- restic recreates the full absolute path,"
            echo "so the save tree is at:"
            find "$DEST" -mindepth 1 -maxdepth 6 -type d -name '${subvolName}.*' -print
            echo
            echo "Next: compare it against the live tree before deciding anything."
            echo "  retroarch-saves-inspect $DATA <the path printed above>"
            echo
            echo "Nothing is promoted by restoring. When you have chosen a"
            echo "candidate, freeze every client, then:"
            echo "  retroarch-saves-promote --from <candidate>"
            echo "and afterwards delete the stale sync manifests on each client:"
            echo "  ${manifestPath}   (and manifest.server beside it)"
          '';
        })
      ];
    };
}
