_: {
  flake.modules = {
    homeManager.laptop =
      { pkgs, lib, ... }:
      {
        programs.looking-glass-client = {
          enable = true;
          settings = {
            app.shmFile = "/dev/kvmfr0";
            app.allowDMA = "yes";
            input.escapeKey = 119;
            input.rawMouse = "yes";
            spice.enable = "yes";
            win.autoScreensaver = "yes";
            win.fullScreen = "yes";
            win.jitRender = "yes";
            win.quickSplash = "yes";
            wayland.fractionScale = "no";
          };
        };
        home.packages = [
          (pkgs.writeScriptBin "win" ''
            #!${lib.getExe pkgs.fish}
            #!/usr/bin/env fish
            set VM_NAME "win11"
            set STATE (virsh --connect qemu:///system domstate $VM_NAME 2>/dev/null)
            if string match -q "running*" $STATE
                echo "$VM_NAME is already running."
            else
                echo "Starting $VM_NAME..."
                virsh --connect qemu:///system start $VM_NAME
                sleep 3
            end

            set -e WAYLAND_DISPLAY
            looking-glass-client &
            exit
          '')
          (pkgs.makeDesktopItem {
            name = "windows";
            desktopName = "Windows VM";
            exec = "win";
            terminal = false;
            type = "Application";
            icon = "windows95";
          })
        ];
      };
    nixos.laptop =
      { config, pkgs, ... }:
      {
        boot.extraModulePackages = with config.boot.kernelPackages; [ kvmfr ];
        boot.extraModprobeConfig = ''
          options kvmfr static_size_mb=64
        '';
        boot.kernelModules = [ "kvmfr" ];

        services.udev.extraRules = ''
          SUBSYSTEM=="kvmfr", GROUP="kvm", MODE="0660", TAG+="systemd"
        '';
        boot.kernel.sysctl = {
          "vm.compaction_proactiveness" = 0;
        };
        boot.kernelParams = [
          # cpu isol
          "isolcpus=0-15"
          "nohz_full=0-15"
          "rcu_nocbs=0-15"
          # 20GB = 20 * 1024 / 2 = 10240 2MB pages (add buffer:  10500)
          "hugepagesz=2M"
          "hugepages=10500"
          "transparent_hugepage=never"
        ];
        systemd.mounts = [
          {
            what = "hugetlbfs";
            where = "/dev/hugepages";
            type = "hugetlbfs";
            options = "mode=0775,gid=libvirtd";
          }
        ];
        environment.etc."libvirt/hooks/qemu" = {
          source = pkgs.writeText "qemu" ''
            #!/usr/bin/env bash

            OBJECT="$1"
            OPERATION="$2"
            SUB_OPERATION="$3"
            EXTRA_ARG="$4"

            if [[ "$OBJECT" == "win11" ]]; then
                CORES=$(seq 0 15)

                if [[ "$OPERATION" == "prepare" ]]; then
                    echo "Hook: Setting performance governor for $OBJECT"
                    for core in $CORES; do
                        echo performance > /sys/devices/system/cpu/cpu$core/cpufreq/scaling_governor
                    done

                elif [[ "$OPERATION" == "release" ]]; then
                    echo "Hook: Reverting to powersave governor for $OBJECT"
                    for core in $CORES; do
                        echo powersave > /sys/devices/system/cpu/cpu$core/cpufreq/scaling_governor
                    done
                fi
            fi
          '';
          mode = "0755";
        };
        virtualisation.libvirtd.qemu = {
          verbatimConfig = ''
            cgroup_device_acl = [
              "/dev/null", "/dev/full", "/dev/zero",
              "/dev/random", "/dev/urandom",
              "/dev/ptmx", "/dev/kvm",
              "/dev/kvmfr0"
            ]
            hugetlbfs_mount = "/dev/hugepages"
          '';
        };
      };
  };
}
