{ lib, ... }:
let
  ci = import ../../lib/ci.nix { inherit lib; };

  # Rendered into a `case` pattern list: `configurations/*|files:*|treefmt`.
  gatingPattern = lib.concatStringsSep "|" ci.gatingCheckPatterns;
in
{
  perSystem =
    { pkgs, ... }:
    {
      # The bridge between one nix-fast-build and 85 individual green lights.
      #
      # In Forgejo there is no separate "Checks" subsystem: an Actions job
      # result *is* a commit status, written through the same service this
      # script POSTs to. A status created here is therefore indistinguishable
      # from a job status in the database and in the UI — it shows in the PR
      # merge box, on the commit page, in the commits list, and it satisfies
      # branch protection, which matches required contexts as globs. That last
      # part is the real win: `checks / configurations/*` is one rule covering
      # every host, which the old 85-job matrix could not express at all.
      #
      # A writeShellApplication rather than a tracked `*.sh` (which
      # checks.no-raw-shell-scripts forbids) or inline workflow YAML: this way
      # shellcheck runs at build time and the script becomes its own check.
      packages.forgejo-check-status = pkgs.writeShellApplication {
        name = "forgejo-check-status";
        meta.description = "Report each flake check as its own Forgejo commit status from one nix-fast-build run";
        runtimeInputs = with pkgs; [
          coreutils
          curl
          jq
          gnugrep
        ];
        # `set -euo pipefail` comes from writeShellApplication. Every place a
        # predicate may legitimately return non-zero is written as an explicit
        # `if`, never `pred && action` — as the last command in a body the
        # latter would trip `errexit` when the predicate simply says "no".
        text = ''
          : "''${FORGE_API:?}" "''${FORGE_REPO:?}" "''${FORGE_SHA:?}" "''${FORGE_TOKEN:?}"

          dir="''${CI_STATUS_DIR:-''${RUNNER_TEMP:-$PWD}/ci-status}"
          mkdir -p "$dir"
          expected="$dir/expected"
          resolved="$dir/resolved"

          # Namespaced so a status reads as a check rather than as something
          # the forge produced itself, and so branch protection can require the
          # whole family with one glob.
          prefix="checks / "

          # Which checks may turn the job red. Generated from
          # lib/ci.nix:gatingCheckPatterns so the policy has one home.
          is_gating() {
            case "$1" in
              ${gatingPattern}) return 0 ;;
              *) return 1 ;;
            esac
          }

          # Exact whole-line match on the first column. A substring or
          # unanchored grep would let `packages/foot` claim the ledger entry
          # for `foot`, and `-F` keeps the dots in `files:*` names literal.
          seen() {
            cut -f1 -- "$resolved" 2>/dev/null | grep -qxF -- "$1"
          }

          post() {
            local code
            code="$(
              jq -nc \
                --arg s "$2" \
                --arg d "''${3:0:180}" \
                --arg u "''${FORGE_TARGET_URL:-}" \
                --arg c "$prefix$1" \
                '{state: $s, description: $d, target_url: $u, context: $c}' \
              | curl -sS --max-time 30 -o /dev/null -w '%{http_code}' \
                  -X POST "$FORGE_API/repos/$FORGE_REPO/statuses/$FORGE_SHA" \
                  -H "Authorization: token $FORGE_TOKEN" \
                  -H 'Content-Type: application/json' \
                  --data @-
            )" || code=000
            # A failed POST must never fail the run: the build result is what
            # matters and the commit page degrades to a missing row. Plain
            # stderr rather than `::error::`, which Forgejo's runner returns
            # unhandled and echoes literally into the log.
            case "$code" in
              200 | 201) ;;
              *) echo "WARN: status POST for $1 returned $code" >&2 ;;
            esac
          }

          record() {
            if seen "$1"; then return 0; fi
            printf '%s\t%s\n' "$1" "$2" >> "$resolved"
            post "$1" "$2" "$3"
          }

          case "''${1:-}" in
            seed)
              # Ground truth for the reconciliation sweep, and why every check
              # shows a pending dot the moment the job starts rather than
              # appearing one at a time. Sequential on purpose: each POST
              # reopens the git repo, rewrites commit_status_summary and runs
              # the auto-merge check server-side, against a Forgejo unit capped
              # at 2G.
              jq -r '.[]' > "$expected"
              : > "$resolved"
              while IFS= read -r attr; do
                post "$attr" pending "Queued"
              done < "$expected"
              ;;

            consume)
              # nix-fast-build JSON Lines on stdin. Its stdout carries nothing
              # else — every renderer, log record and subprocess writes to
              # stderr — so the human-readable build log still reaches the job
              # log untouched. `--unbuffered` so a light goes green as each
              # check lands rather than all at once at the end.
              #
              # nix-eval-jobs double-quotes an attribute name that is not a
              # valid Nix identifier. Measured against nix-eval-jobs 2.35:
              # names containing a DOT are quoted and nothing else is, so
              # `configurations/nixos/link` and `packages/foot` arrive raw
              # while every one of the 11 `files:*` checks arrives as
              # "files:.gitignore" — quotes included. Strip them or those
              # checks post under a context nobody is watching.
              #
              # An EVAL row is emitted for EVERY attribute BEFORE --skip-cached
              # decides to skip it (workers.py enqueues the result, then
              # continues), so a cached check is never left pending: it greens
              # on its EVAL row and simply never gets a BUILD row. An EVAL row
              # that is successful and uncached falls through to `empty` and
              # stays pending until its BUILD row arrives.
              jq --unbuffered -r '
                def unq: if startswith("\"") and endswith("\"") then .[1:-1] else . end;
                def msg: (.error // "") | gsub("[\t\r\n]+"; " ");
                if .type == "EVAL" and (.success | not) then
                  [(.attr | unq), "fail", "Evaluation failed: \(msg)"]
                elif .type == "EVAL" and .cacheStatus == "cached" then
                  [(.attr | unq), "ok", "Substituted from cache"]
                elif .type == "EVAL" and .cacheStatus == "local" then
                  [(.attr | unq), "ok", "Already in store"]
                elif .type == "BUILD" then
                  [ (.attr | unq),
                    (if .success then "ok" else "fail" end),
                    (if .success then "Built in \(.duration | floor)s" else msg end) ]
                else
                  empty
                end
                | @tsv' \
              | while IFS=$'\t' read -r attr verdict desc; do
                  if [ "$verdict" = ok ]; then
                    record "$attr" success "$desc"
                  elif is_gating "$attr"; then
                    record "$attr" failure "$desc"
                  else
                    # `warning` is a real Forgejo state — a yellow "!" ranked
                    # between failure and pending. Visibly not green without
                    # reading as a merge blocker.
                    record "$attr" warning "$desc"
                  fi
                done
              ;;

            finish)
              rc="''${2:-1}"
              # Does a GATING check say this run is bad?
              fail=0
              # Did ANY check come back non-green? This is not the same
              # question. nix-fast-build exits non-zero for an advisory failure
              # just as loudly as for a gating one, so without this the
              # infrastructure fallback below would escalate every advisory
              # package failure back into a red run — exactly the behaviour the
              # gating policy exists to prevent.
              nongreen=0

              # Anything seeded but never resolved. nix-eval-jobs can die
              # before reaching an attribute, and a failure to evaluate the
              # root emits ZERO rows and only a non-zero exit code — without
              # this sweep those checks would sit pending forever.
              while IFS= read -r attr; do
                if seen "$attr"; then continue; fi
                post "$attr" error "No result reported"
                nongreen=1
                if is_gating "$attr"; then fail=1; fi
              done < "$expected"

              # A ledger `failure` is only ever written for a gating check;
              # advisory ones are recorded as `warning`.
              while IFS=$'\t' read -r _ state; do
                case "$state" in
                  failure | error)
                    fail=1
                    nongreen=1
                    ;;
                  warning) nongreen=1 ;;
                  *) ;;
                esac
              done < "$resolved"

              if [ "$fail" -eq 0 ] && [ "$rc" -ne 0 ] && [ "$nongreen" -eq 0 ]; then
                # Every single check is green yet nix-fast-build still failed,
                # so the failure was infrastructural — an attic upload, most
                # likely. Its exit code cannot distinguish that from a build
                # failure, which is why the ledger is consulted first and this
                # is the fallback rather than the primary signal.
                echo "nix-fast-build exited $rc with no failing check; see the log above." >&2
                fail=1
              fi

              exit "$fail"
              ;;

            *)
              echo "usage: forgejo-check-status {seed|consume|finish <exit-code>}" >&2
              exit 2
              ;;
          esac
        '';
      };
    };
}
