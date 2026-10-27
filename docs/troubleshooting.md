# Troubleshooting

Work top to bottom. Each layer depends on the one above it. Run
[`scripts/preflight.sh`](../scripts/preflight.sh) first. It covers most of the first three
rows.

| Symptom | Likely layer | What to check |
| --- | --- | --- |
| VM has no LAN address / can't ping OPNsense | VirtualBox bridge | Adapter is **Bridged** to `en0` (Ethernet), promiscuous mode **Allow All**, macOS Local Network permission for VirtualBox, netplan interface name matches `ip -br link` |
| Containers fail with `exec format error` | ARM64 | amd64-only image; `docker buildx imagetools inspect <image>`; build it locally (docs/04 4.1) |
| `modprobe fou` fails | Kernel | `sudo apt install linux-modules-extra-$(uname -r)` |
| `dig @OPNsense segw.femto.sprint.net` doesn't return the VM IP | dnscrypt-proxy | Cloaking rule saved and service restarted. Is dnscrypt-proxy (not Unbound) really answering on port 53? Check **Services > DNSCrypt-Proxy > General** listen address |
| dig works from the VM, but the femtocell never sends IKE | Femtocell DNS | Packet capture on OPNsense LAN for `host <femto-ip> and port 53`: is it querying OPNsense at all? Add the DNS redirect NAT rule (docs/02 2.3). Is the femtocell on its static lease? |
| IKE packets arrive (`tcpdump udp port 500`) but no SA | SeGW / credentials | `docker compose logs femto-segw`. Check the IKE group key, EAP identity/password, and `security_profile: legacy`. Try the other Airave profile (2x vs 5x) |
| No IKE packets arrive at the VM at all | Network | `ufw` rules for UDP 500/4500. Is the femtocell on the same LAN? Is the cached cloak TTL pointing at an old IP? Reboot the femtocell |
| SA established, ACS pending | Provisioning | `docker compose logs femto-core`. Check ACS username/password and profile. Check the in-tunnel DNS names (`FEMTO_ACS_DOMAIN` default `fsmhdm.femto.spcsdns.net`) |
| ACS provisioned, SIP not registered | SIP | SIP password and realm, `FEMTO_SIP_DOMAIN` (default `fap.airave2.ims.spcsdns.net`) |
| Device online, radio unavailable | Radio | `1x.enabled`, a supported band and channel, `max_sector_power_dbm` >= -30, **GPS lock** (antenna near a window, allow time) |
| Radio up, handset doesn't register | Handset | Subscriber IMSI and ESN/MEID in **Subscribers**. Handset PRL, band, channel, SID 22 / NID 65535 matching the `1x` block |
| HLR lookups fail / PDSN "MEID-to-IMSI disabled" | Core start order | HLR must be up before PDSN: `stop-core.sh && start-core.sh` |
| Call connects, no audio | Voice bearer | Rerun `sudo docker/femto/host-route.sh add` (after any SeGW recreate). Does `voice_bearer_bind_ip` equal the femto Docker network host IP (not loopback)? |
| Data fails | Packet core | A11 key and SPI match on both ends, `getcap target/release/cdma-nib`, host routes, `fou-nat` container running, `a10_bearer` nulls present (docs/05) |
| EV-DO auth fails | A12 | `term_auth_psk` (femto) equals `a12.radius_secret` (PDSN); re-sync the femtocell |
| Everything drops overnight | Mac host | Mac slept (`pmset -g`). Did the VM stop or the Mac reboot? |

## Useful commands (in the VM, from `~/1xbts`)

```bash
docker compose ps
docker compose logs --tail=200 femto-segw femto-core
docker compose exec femto-segw swanctl --list-sas
sudo tcpdump -ni any 'udp port 500 or udp port 4500 or proto gre'
ip route | grep -v docker
tail -f ~/1xbts-femtocell/logs/core-a.log ~/1xbts-femtocell/logs/core-b.log
```

Redact identities and credentials before sharing any of this output, including in
[findings](findings.md).
