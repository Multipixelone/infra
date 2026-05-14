{ inputs, ... }:
{
  configurations.nixos.iot.module =
    {
      config,
      pkgs,
      ...
    }:
    let
      toggleLabel = pkgs.writeShellApplication {
        name = "ha-todoist-toggle-label-in-project";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          set -euo pipefail
          project="$1"
          mode="$2"   # "add" or "remove"
          label="$3"
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

          # Resolve project name → id, handling both bare-array and wrapped
          # {results, next_cursor} responses. Paginate if needed.
          resolve_project() {
            local target="$1"
            local cursor=""

            while :; do
              if [ -n "$cursor" ]; then
                resp="$(api list-projects -H "Authorization: Bearer $token" \
                  "https://api.todoist.com/api/v1/projects?cursor=$cursor")"
              else
                resp="$(api list-projects -H "Authorization: Bearer $token" \
                  "https://api.todoist.com/api/v1/projects")"
              fi

              id="$(printf '%s' "$resp" | jq -r \
                --arg n "$target" \
                '(if type=="array" then . else .results end)
                 | .[]
                 | select(.name == $n)
                 | .id')"

              if [ -n "$id" ] && [ "$id" != "null" ]; then
                printf '%s' "$id"
                return 0
              fi

              # Check for another page.
              cursor="$(printf '%s' "$resp" | jq -r \
                'if type=="array" then "" else (.next_cursor // "") end')"
              if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
                break
              fi
            done

            echo "todoist: project not found: $target" >&2
            return 22
          }

          # Fetch all projects once, resolve project id.
          project_id="$(resolve_project "$project")"

          # Paginate through tasks in the project; update labels per mode.
          cursor=""
          count=0

          while :; do
            if [ -n "$cursor" ]; then
              url="https://api.todoist.com/api/v1/tasks?project_id=$project_id&cursor=$cursor"
            else
              url="https://api.todoist.com/api/v1/tasks?project_id=$project_id"
            fi

            resp="$(api list-tasks -H "Authorization: Bearer $token" "$url")"

            if [ "$mode" = "add" ]; then
              # Only emit rows where label is NOT already present.
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
                --arg lbl "$label" \
                '(if type=="array" then . else .results end)
                 | .[]
                 | select((.labels // []) | index($lbl) | not)
                 | [.id, ((.labels // []) + [$lbl] | unique | tojson)]
                 | @tsv')
            else
              # Only emit rows where label IS present.
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
                --arg lbl "$label" \
                '(if type=="array" then . else .results end)
                 | .[]
                 | select((.labels // []) | index($lbl))
                 | [.id, ((.labels // []) | map(select(. != $lbl)) | tojson)]
                 | @tsv')
            fi

            cursor="$(printf '%s' "$resp" | jq -r \
              'if type=="array" then "" else (.next_cursor // "") end')"
            if [ -z "$cursor" ] || [ "$cursor" = "null" ]; then
              break
            fi
          done

          echo "todoist: $mode label '$label' on $count task(s) in project '$project'" >&2
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
          todoist_hide_care = "${toggleLabel}/bin/ha-todoist-toggle-label-in-project Chores add hidden";
          todoist_show_care = "${toggleLabel}/bin/ha-todoist-toggle-label-in-project Chores remove hidden";
        };
      };

      # Todoist automations: moved to iotHass.nixAutomations so they're serialized
      # into /etc/home-assistant/automations_nix.yaml and loaded via
      # `automation manual: !include`, alongside the UI-managed automations.yaml.
      iotHass.nixAutomations = [
        {
          alias = "Todoist: tag #Chores with @hidden on leaving home";
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
          alias = "Todoist: untag @hidden from #Chores on arriving home";
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
}
