# Adding a host: bare metal to hive node

The general procedure for turning a machine into a Colmena node in this
repository. Host-specific runbooks layer on top of it —
[`impa-edge-bootstrap-cutover.md`](impa-edge-bootstrap-cutover.md) covers the
NYC edge cutover and refers back here for everything below.

Two facts govern the whole sequence and explain most of its ordering:

- **Nix cannot see untracked files.** A dirty flake source drops files git does
  not track, so a new `modules/<host>/*.nix` does nothing at all until it is
  `git add`ed. Every step that creates a file ends with a `git add`.
- **agenix enrolment must precede the first secret-bearing deploy.** A host that
  is in no recipient list still deploys successfully and then half-activates:
  `age --decrypt` fails, the activation script's `ERR` trap sets status 1, and
  Colmena reports the failure only *after* the system profile has already been
  switched. The host is left running a generation whose secrets are absent.
  Enrol the key first; do not "deploy and fix it after".

## 1. Declare the host in the registry

`modules/hosts.nix` is the single registry every projection reads — Colmena
tags, `known_hosts`, WireGuard peers, README tables. Add the host there before
anything else, and start it non-deployable:

```nix
newhost = {
  isNixOS = true;
  deployable = false;
  roles = [ "server" ];
  description = "…";
  readmeRole = "Server";
  homeAddress = "192.168.6.60";
};
```

`deployable = false` keeps the host out of the Colmena hive while it is still
being built, so a bare `just colmena-apply` cannot reach a machine that has no
secrets yet. It is the option that makes the rest of this procedure safe to
perform in stages.

`roles` is a closed enum and drives module injection (`modules/roles.nix`) as
well as the deployment tags, so a role you do not want the modules for does not
belong in the list.

## 2. Scaffold `modules/<host>/`

One concern per file, matching the existing hosts:

- `hostname.nix` — `networking.hostName` (and `networking.domain` if the host is
  not on the default one).
- `state-version.nix` — `system.stateVersion`, pinned to the release the machine
  is *first installed from* and never bumped afterwards.
- `imports.nix` — `imports = with config.flake.modules.nixos; [ … ];` for the
  shared modules the role map does not already inject, plus
  `inputs.disko.nixosModules.disko`, without which the `disko.devices` options
  below do not exist. `modules/impa/imports.nix` is the shape.
- `facter.nix` — `facter.report.system = "x86_64-linux";` as a placeholder until
  the real `nixos-facter` report exists. Replace it in step 4.
- `disko.nix` — the partition layout, gated on an installer-supplied disk path.
  Model it on `modules/impa/disko.nix`: an option defaulting to `null`, with the
  `disko.devices` block wrapped in `lib.mkIf (… != null)` so the host still
  evaluates before the disk is known.

Then:

```
git add modules/newhost
```

Confirm the host evaluates before touching hardware:

```
nix eval .#nixosConfigurations.newhost.config.system.build.toplevel.drvPath
```

That forces the whole module system without building anything. Do not run
`nix flake check` — a full check builds every host and takes hours.

## 3. Boot the installer

```
just iso
```

The result is portable recovery media and deliberately carries no machine's
hardware report, so the same stick works for every host. Boot the target from
it and record, without guessing:

- the persistent disk path from `ls -l /dev/disk/by-id` (never `/dev/sdX`, which
  is not stable across boots),
- the wired interface name and MAC from `ip -br link`,
- a `nixos-facter` report (`nixos-facter` is on the ISO).

Set `<host>.install.diskDevice` to the reviewed `by-id` path **in a committed
module** — the installer module is subject to the same untracked-file rule as
everything else, and an uncommitted one silently leaves `diskDevice` null and
disko unconfigured.

## 4. Install

```
just install newhost 192.168.6.60
```

The recipe wraps `nix run .#nixos-anywhere`, which partitions the target using
the host's own `disko.nix` and installs its evaluated toplevel over SSH. The
disk layout, filesystems, and bootloader all come from the repository; nothing
is chosen interactively.

Install **without secrets**. Then boot the machine and verify console access,
networking, key-only SSH, and Mosh before going further.

Generate the real `nixos-facter` report on the installed machine, replace the
placeholder `facter.nix`, commit, and re-run the `drvPath` evaluation from
step 2 to confirm the host still evaluates against its real hardware.

## 5. Enrol the SSH host key as an agenix recipient

This is the step whose omission produces the half-activation described at the
top. It happens in the private `nix-secrets` repository, not here.

1. On the new host, read its public host key:

   ```
   cat /etc/ssh/ssh_host_ed25519_key.pub
   ```

   Only the public half ever leaves the machine. The private host key is never
   copied anywhere, and never into git.

2. In `nix-secrets`, add that key as a binding in `secrets.nix` and append it to
   the `systems` list. Everything defined as `users ++ systems` becomes
   decryptable by the new host at that point.

3. Extend the **host-narrowed** secrets separately. Some entries do not use
   `systems` and name their recipients explicitly — the shared Cloudflare
   connector credential is one:

   ```nix
   "cloudflare/service-publication-tunnel.age".publicKeys = users ++ [ link newhost ];
   ```

   A host that consumes such a secret but is missing from its list is exactly
   the failure mode this step exists to prevent. Grep the modules the host
   imports for `age.secrets` and check each corresponding entry. Never create a
   second copy of a credential to work around a missing recipient.

4. Re-key and commit in `nix-secrets`:

   ```
   agenix -r
   ```

   `-r` re-encrypts every secret to its current recipient list. Review that
   private change independently before pushing.

5. Bump the pin in this repository so the re-keyed files are the ones deployed:

   ```
   nix flake update secrets
   ```

   Commit `flake.lock`. Until this lands, deploys still ship the old ciphertext
   and the new host still cannot decrypt.

## 6. Pin the host key for `known_hosts`

Record the *same* public key from step 5.1 in the registry:

```nix
newhost.sshHostKey = "ssh-ed25519 AAAA… root@newhost";
```

`modules/ssh.nix` projects this into `programs.ssh.knownHosts` on every host, so
SSH to the new machine is verified rather than trust-on-first-use. The two
values must be byte-identical to the agenix recipient — they are the same key,
and a mismatch means one of the two is stale.

## 7. Make it deployable

Flip the registry:

```nix
newhost.deployable = true;
```

Build before applying:

```
just colmena-build newhost      # colmena build --on @newhost
```

A build failure at this point costs nothing; a failed apply has already touched
the machine. Only once the build succeeds:

```
just colmena-apply-tag newhost
```

Every node carries its own name as a Colmena tag, so `--on @newhost` selects
exactly this host.

Verify on the target that the agenix secrets actually materialised under
`/run/agenix` and that the units consuming them are running — a clean Colmena
exit is necessary but, per the ordering note at the top, not by itself
sufficient.

## Checklist

- [ ] Host declared in `modules/hosts.nix` with `deployable = false`
- [ ] `modules/<host>/` created **and `git add`ed**
- [ ] `drvPath` evaluates
- [ ] Disk path discovered from `/dev/disk/by-id` and committed
- [ ] Installed with `just install`, secret-free, and booted
- [ ] Real `nixos-facter` report committed
- [ ] Host public key enrolled in `nix-secrets` `systems` **and** in every
      host-narrowed secret it consumes; `agenix -r` run
- [ ] `flake.lock` bumped for `secrets` in this repository
- [ ] Same public key recorded as `hosts.<name>.sshHostKey`
- [ ] `deployable = true`, `just colmena-build` clean, then first apply
- [ ] Secrets present under `/run/agenix` on the target after the apply
