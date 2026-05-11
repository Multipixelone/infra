{ inputs, ... }:
{
  configurations.nixos.iot.module =
    { config, pkgs, ... }:
    let
      renameLabel = pkgs.writeShellApplication {
        name = "ha-todoist-rename-label";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          set -euo pipefail
          old_name="$1"
          new_name="$2"
          token="$(< "${config.age.secrets."todoist".path}")"

          # Echo response body to stderr on HTTP error so HA logs show what Todoist said.
          api() {
            local stage="$1"; shift
            local out status body
            out="$(curl -sS -w $'\n%{http_code}' "$@")"
            status="''${out##*$'\n'}"
            body="''${out%$'\n'*}"
            if [ "$status" -lt 200 ] || [ "$status" -ge 300 ]; then
              echo "todoist: $stage http $status: $body" >&2
              return 22
            fi
            printf '%s' "$body"
          }

          encoded_label="$(jq -rn --arg s "$old_name" '$s|@uri')"
          cursor=""
          count=0

          while :; do
            if [ -n "$cursor" ]; then
              url="https://api.todoist.com/api/v1/tasks?label=$encoded_label&cursor=$cursor"
            else
              url="https://api.todoist.com/api/v1/tasks?label=$encoded_label"
            fi

            resp="$(api list-tasks -H "Authorization: Bearer $token" "$url")"

            while IFS=$'\t' read -r task_id new_labels; do
              [ -z "$task_id" ] && continue
              api update-task \
                -X POST \
                -H "Authorization: Bearer $token" \
                -H 'Content-Type: application/json' \
                -d "$(jq -nc --argjson l "$new_labels" '{labels:$l}')" \
                "https://api.todoist.com/api/v1/tasks/$task_id" >/dev/null
              count=$((count + 1))
            done < <(printf '%s' "$resp" | jq -r \
              --arg old "$old_name" --arg new "$new_name" \
              '(if type=="array" then . else .results end)
               | .[]
               | [.id,
                  ((.labels // []) | map(if . == $old then $new else . end) | tojson)]
               | @tsv')

            cursor="$(printf '%s' "$resp" | jq -r \
              'if type=="array" then "" else (.next_cursor // "") end')"
            if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
              break
            fi
          done

          echo "todoist: rewrote $count task(s): $old_name -> $new_name" >&2
        '';
      };
    in
    {
      age.secrets."todoist" = {
        file = "${inputs.secrets}/todoist.age";
        owner = "hass";
        group = "hass";
        mode = "0400";
      };

      services.home-assistant.config = {
        shell_command = {
          todoist_hide_care = "${renameLabel}/bin/ha-todoist-rename-label care care_hidden";
          todoist_show_care = "${renameLabel}/bin/ha-todoist-rename-label care_hidden care";
        };

        automation = [
          {
            alias = "Todoist: hide @care on leaving home";
            trigger = [
              {
                platform = "zone";
                entity_id = "person.finn";
                zone = "zone.home";
                event = "leave";
              }
            ];
            action = [
              { service = "shell_command.todoist_hide_care"; }
            ];
          }
          {
            alias = "Todoist: show @care on arriving home";
            trigger = [
              {
                platform = "zone";
                entity_id = "person.finn";
                zone = "zone.home";
                event = "enter";
              }
            ];
            action = [
              { service = "shell_command.todoist_show_care"; }
            ];
          }
        ];
      };
    };
}
