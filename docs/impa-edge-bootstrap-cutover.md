# Impa edge bootstrap, cutover, and rollback

This runbook is operational guidance only. Firmware, FortiGate/DHCP/client, agenix recipient, provider, backend ACL, deployment, connector-retirement, and final-cutover actions are manual and require separate authorization.

The general bare-metal-to-hive-node procedure lives in [`new-host.md`](new-host.md) and is not repeated here. This runbook covers only what is specific to Impa: the edge hardware prerequisites, the secret-free first install, and the ingress cutover and rollback.

## Hardware prerequisites

Enable automatic power-on after AC loss in firmware and disable firmware sleep where available. From the repository installer ISO, record the real persistent disk path under `/dev/disk/by-id`, wired NIC name and MAC, and a `nixos-facter` report. Never guess them.

## Stage 1: secret-free bootstrap

1. Boot the repository installer ISO. Confirm the disk with `ls -l /dev/disk/by-id` and interface with `ip -br link`.
2. Supply the reviewed disk path as `impa.install.diskDevice` in an installer-only module, and **commit that module** — nix drops untracked files from a dirty flake source, so an uncommitted installer module leaves `diskDevice` null and configures no Disko layout at all. Then run Disko against Impa. The layout is GPT, a 1 GiB EFI partition, and unencrypted Btrfs `@root`, `@home`, `@nix`, and `@swap`. `@swap` carries no swapfile at install time; the first boot creates the 16 GiB `/swap/swapfile` declared in `modules/impa/swap.nix`.
3. Generate and review the Impa `nixos-facter` report and hardware configuration. Commit those facts separately, replacing the architecture-only bootstrap report. Pin the discovered NIC/MAC then if stable matching is required.
4. Install without agenix secrets. Use `192.168.6.50/24`, gateway `192.168.6.1`, disabled IPv6, and local DNS.
5. Boot and verify console, network, key-only SSH, Mosh, `impa.hosts.nyc.finnrut.is`, disabled sleep, and the generated SSH host public key. Never copy the private host key into Git.

## Stage 2: secret enrollment

Finn manually enrolls Impa's SSH host public key as an agenix recipient in the private secrets repository, following [`new-host.md`](new-host.md) step 5. Review that private change independently. Only afterward, and with separate authorization, perform the first secret-bearing Colmena deployment.

Link and Impa reference the same existing `cloudflare/service-publication-tunnel.age`; never create another token or plaintext copy. That entry names its recipients explicitly rather than using `systems`, so adding Impa to `systems` is not sufficient — Impa must also be added to that entry's own `publicKeys` list before `agenix -r`. Deploying without it half-activates Impa: the connector's secret fails to decrypt, activation reports failure, and the system profile has already switched.

## Pre-cutover validation

1. Validate Impa nginx routes, ACME coverage, Blocky records, Node Exporter, Blocky metrics, and direct DNS probes.
2. Read-only verify the adopted Cloudflare account, zone, Tunnel named `link`, Tunnel membership, and shared concurrent credential. Confirm no unmodeled Link-only hostnames. Do not run OpenTofu or mutate the provider.
3. Migrate and verify Link on the generated shared connector, then start and verify Impa. Keep both connectors active.
4. Verify both resolvers independently for generated internal records, the controlled blocking fixture, an unknown `nyc.finnrut.is` name (no public fallback), and an external upstream name.
5. Manually apply Alexandria/backend runtime ACLs and confirm Impa can reach every declared backend while required loopback consumers remain functional.

## Cutover

Manually update only trusted DHCP clients on `192.168.3.0/24` and `192.168.6.0/24` to advertise Impa first and Link second. Do not advertise Impa to WireGuard, IoT, guest, or `192.168.5.0/24`; Link remains WireGuard DNS at `10.100.0.1`.

Move ingress to Impa and validate every generated route. Hold the Link connector for 48 clean hours. Then manually retire only Link's ingress connector while retaining Link DNS and Link-centered observability. Provider changes and connector retirement remain manual.

## Rollback

After sustained generated-record mismatch, public-fallback leakage, resolver failure, or ingress failure lasting more than five minutes:

1. Restore Link ingress and the prior trusted-client DHCP resolver order.
2. Keep Link DNS and observability running and preserve probe evidence.
3. Remediate and repeat all pre-cutover validation.
4. Restart the 48-hour clean-overlap clock from zero.
