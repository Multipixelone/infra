{
  # impa ships with no swap: the disko layout is @root, @home and @nix and
  # nothing else. That is a bad trade for a 8 GiB box that is simultaneously
  # the house's public ingress, one of two DNS resolvers and a forge — a
  # forgejo repack or an ACME renewal spike has nowhere to overflow to, so the
  # OOM killer is the first backstop, and on this host it would take blocky or
  # unbound with it. The disk is 931 GiB with 11 GiB used, so 16 GiB of
  # file-backed swap buys that headroom for nothing that will ever be missed.
  #
  # `size` is what makes this work on a machine that is already installed.
  # NixOS's mkswap-<device> unit creates the file when it is missing or the
  # wrong size, and on btrfs it does so with `btrfs filesystem mkswapfile`,
  # which sets NODATACOW — the only shape btrfs will accept a `swapon` for.
  # Disko's own `subvolumes.<name>.swap` option is deliberately not used: it
  # creates the file at install time only and emits a *sizeless* swapDevices
  # entry, so it would leave a running impa with no swap and no way to get it
  # short of a reinstall. The subvolume that holds the file is still declared
  # in disko.nix, so a fresh install gets the mount and first boot creates the
  # file into it.
  configurations.nixos.impa.module = {
    swapDevices = [
      {
        device = "/swap/swapfile";
        size = 16384; # MiB
      }
    ];

    # Overflow, not working memory. The default (60) would happily page out
    # resident pages of the two daemons whose latency the whole house feels;
    # this keeps swap for the case it is here for, which is a burst that would
    # otherwise be an OOM kill.
    boot.kernel.sysctl."vm.swappiness" = 10;
  };
}
