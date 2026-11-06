{
  configurations.nixos.iso.module =
    { pkgs, ... }:
    {
      environment.systemPackages = with pkgs; [
        # disk recovery
        testdisk
        testdisk-qt
        safecopy
        parted
        tparted
        wiper
        fsarchiver
        partclone
        ddrescue
        ddrutility

        # cpu
        stress
        stress-ng
        stressapptest

        # memory
        memtester

        # storage
        nvme-cli
        lvm2
        mdadm
        multipath-tools
        pciutils
        hdparm
        sdparm

        # misc hardware
        dmidecode
        read-edid
        edid-decode
        edid-generator
        rwedid
        fanctl
        fan2go
        i2c-tools
        hwinfo
        lm_sensors
        lshw
        smartmontools
        usbutils

        # encryption
        cryptsetup
        gnupg
        age

        # filesystem maintenance
        gptfdisk

        # filesystem support
        dosfstools
        dislocker
        go-mtpfs
        exfatprogs
        f2fs-tools
        mtools
        sshfs
        ntfs3g
        e2fsprogs
        xfsprogs
        btrfs-progs

        # specific filesystem recovery tools
        ext4magic
        myrescue
        extundelete
        xfs-undelete
        fatcat
        ntfs2btrfs

        # boot loader access
        grub2
        efibootmgr

        # os stuff
        arch-install-scripts
        nixos-install-tools
        os-prober
        syslinux

        # network tools
        iproute2
        tcpdump
        netcat-gnu
        dnsutils
        cifs-utils
        nfs-utils

        # miscellaneous tools
        util-linux
        sleuthkit
        coreutils-full

        # windows tooling
        rdesktop
        chntpw
        # WARN: sphinx-9.1.0 not supported for interpreter python3.11
        # samba4Full

        # file archive & compression tools
        gnutar
        gzip
        xz
        zstd
        lz4
        bzip2
        zip
        p7zip

        # ISO utils
        cdrtools

        # Hex editors
        hexedit
      ];
    };
}
