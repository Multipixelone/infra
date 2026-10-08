{ lib, ... }:
{
  configurations.nixos.link.module =
    { config, pkgs, ... }:
    let
      cfg = config.link.cooling;
      cpuUid = "c1770000-0000-4000-8000-000000000001";
      caseCpuUid = "c1770000-0000-4000-8000-000000000002";
      caseGpuUid = "c1770000-0000-4000-8000-000000000003";
      caseUid = "c1770000-0000-4000-8000-000000000004";
      functionUid = "c1770000-0000-4000-8000-000000000005";
      graph = uid: name: source: curve: {
        inherit uid name;
        p_type = "Graph";
        function_uid = functionUid;
        temp_source = source;
        speed_profile = curve;
      };
      library = pkgs.writeText "link-cooling-profiles.json" (
        builtins.toJSON {
          case_profile_uid = caseUid;
          profiles = [
            (graph cpuUid "CPU cooler (Nix)" cfg.cpuSource cfg.cpuCurve)
            (graph caseCpuUid "Case CPU (Nix)" cfg.cpuSource cfg.caseCpuCurve)
            (graph caseGpuUid "Case GPU temperature (Nix)" cfg.gpuSource cfg.caseGpuCurve)
            {
              uid = caseUid;
              name = "Case CPU/GPU max (Nix)";
              p_type = "Mix";
              function_uid = "0";
              member_profile_uids = [
                caseCpuUid
                caseGpuUid
              ];
              mix_function_type = "Max";
            }
          ];
          functions = [
            {
              uid = functionUid;
              name = "Fast rise, slow fall (Nix)";
              f_type = "Standard";
              # These are step sizes, not minimum/maximum duty. The curves
              # supply the non-stopping 30% floor, adjustable after calibration.
              duty_minimum = 2;
              duty_maximum = 100;
              step_size_min_decreasing = 2;
              step_size_max_decreasing = 5;
              response_delay = 5;
              deviance = 2.0;
              only_downward = true;
              threshold_hopping = true;
              bypass_min_at_extremes = false;
            }
          ];
        }
      );
      python = pkgs.python3.withPackages (ps: [ ps.tomlkit ]);
      helper = pkgs.writeShellApplication {
        name = "link-cooling-config";
        text = ''
          exec ${lib.getExe python} ${../../lib/link-cooling-config.py} \
            --library ${library} "$@"
        '';
      };
      sourceType = lib.types.submodule {
        options = {
          device_uid = lib.mkOption { type = lib.types.str; };
          temp_name = lib.mkOption { type = lib.types.str; };
        };
      };
      curveOption =
        description: default:
        lib.mkOption {
          inherit description default;
          type = lib.types.listOf (lib.types.listOf lib.types.number);
        };
    in
    {
      options.link.cooling = {
        package = lib.mkOption {
          type = lib.types.package;
          readOnly = true;
          internal = true;
          default = helper;
          description = "Packaged CoolerControl configuration reconciler.";
        };
        cpuSource = lib.mkOption {
          type = sourceType;
          default = {
            device_uid = "493d3808155f2e271d9fa420bdc778631ee43f6c01244088874f5305d331a4cb";
            temp_name = "temp1";
          };
          description = "CoolerControl Ryzen 5900XT Tctl source; update after a CPU replacement.";
        };
        gpuSource = lib.mkOption {
          type = sourceType;
          default = {
            device_uid = "13d8f4a5be256999d60cb90f5cb7c6418a3f5a70946d2761c2049de37081d0d1";
            temp_name = "temp1";
          };
          description = "AMDGPU edge temperature source for case fans; does not configure the GPU fan.";
        };
        cpuCurve = curveOption "CPU cooler temperature/duty pairs; calibrate the duty floor." [
          [
            30
            30
          ]
          [
            50
            30
          ]
          [
            60
            50
          ]
          [
            70
            75
          ]
          [
            80
            100
          ]
        ];
        caseCpuCurve = curveOption "Case fan Tctl temperature/duty pairs." [
          [
            30
            30
          ]
          [
            50
            30
          ]
          [
            60
            45
          ]
          [
            70
            70
          ]
          [
            80
            100
          ]
        ];
        caseGpuCurve = curveOption "Case fan GPU edge temperature/duty pairs." [
          [
            30
            30
          ]
          [
            45
            30
          ]
          [
            55
            45
          ]
          [
            65
            70
          ]
          [
            80
            100
          ]
        ];
      };
      config = {
        environment.systemPackages = [ helper ];
        systemd.services.coolercontrold.serviceConfig.ExecStartPre = [
          "${lib.getExe helper} --config-dir /etc/coolercontrol"
        ];
      };
    };
}
