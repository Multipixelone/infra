{
  # link has 62 GiB of RAM and a 6 GiB swapfile that sits pinned at 100% used,
  # so the next allocation spike is an OOM kill rather than a slowdown. The
  # swapfile lived on the 235 GiB SATA root (`Linux`), which is 77% full and
  # has no room to grow it. The 4 TiB NVMe behind /media/Data (`4Tera`) has
  # ~1.1 TiB free, so /swap moves there and grows to 64 GiB — headroom that is
  # free on that disk and faster than the SATA it came from.
  #
  # The file lives in its own @swap subvolume rather than inside @music: a
  # swapfile must be NODATACOW and unsnapshottable, and keeping it out of the
  # data subvolume means nothing that snapshots or send/receives @music ever
  # has to reason about it.
  #
  # `size` is what creates the file. NixOS's mkswap-<device> unit makes it when
  # it is missing or the wrong size, and on btrfs it uses
  # `btrfs filesystem mkswapfile`, which sets NODATACOW — the only shape btrfs
  # accepts a `swapon` for. The old 6 GiB file on `Linux` is left behind by
  # this change and can be deleted by hand to reclaim that space.
  configurations.nixos.link.module = {
    fileSystems."/swap" = {
      device = "/dev/disk/by-label/4Tera";
      fsType = "btrfs";
      options = [
        "subvol=/@swap"
        "noatime"
        "ssd"
        "discard=async"
        "space_cache=v2"
      ];
    };

    swapDevices = [
      {
        device = "/swap/swapfile";
        size = 65536; # MiB
      }
    ];

    # Overflow, not working memory: keep the desktop's resident pages resident
    # and use the 64 GiB for the bursts that were getting OOM-killed.
    boot.kernel.sysctl."vm.swappiness" = 10;
  };
}
