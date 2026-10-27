# Findings

A dated log of what actually happened on this setup. Add new entries at the top. Mark each
one **Confirmed** (you tested it), **Expected** (from docs or reasoning, not yet tested),
or **Disproved**.

Never paste secret values, IMSIs, MEIDs, or unredacted logs here.

## Template

```markdown
### YYYY-MM-DD: short title
Status: Confirmed | Expected | Disproved
Context: what you were doing
Observed: what happened (commands, redacted log lines)
Fix / takeaway:
```

---

## Device facts (fill in as discovered)

| Fact | Value | Status |
| --- | --- | --- |
| LAN address / alias | 192.168.1.201 / `sprint_femtocell` | Confirmed |
| MAC OUI | 00:05:B9 (Airvana) | Confirmed |
| Responds to ping | No (ARP only) | Confirmed |
| Boot to first IKE attempt | ~4.5 min | Confirmed |
| IKE version | IKEv2 (`IKE_SA_INIT` to UDP 500) | Confirmed |
| Model (label) | | |
| FCC ID | | |
| Firmware (2.x / 5.x) | | |
| 1xBTS profile that works | | |
| FEID equals Ethernet MAC? | | |
| Bootstrap DNS names actually queried | | |
| Other hosts it tries to reach (from OPNsense block log) | | |
| Cold-start GPS lock time | | |
| Credentials collected (yes/no per field, see docs/03 3.3) | | |

---

### 2026-10-27: Femtocell sends IKEv2 to the VM after a power cycle
Status: Confirmed

- About 4.5 minutes after power-on, the femtocell started sending **IKEv2 `IKE_SA_INIT`**
  from `192.168.1.201:500` to `192.168.1.50:500`. The cloaked `segw*.femto.sprint.net`
  answer is reaching it, so the DNS bootstrap works end to end.
- Retries come every 5 seconds in bursts, with longer gaps between bursts.
- The VM answers `ICMP port 500 unreachable` because nothing listens yet. That's expected
  until the 1xBTS `femto-segw` container is running.
- So the device speaks IKEv2. Its identity (IDi) and proposals will appear in the
  `femto-segw` logs once the SeGW answers `IKE_SA_INIT`.

### 2026-10-27: Femtocell on the LAN; DNS redirect confirmed
Status: Confirmed (DNS), Expected (IKE)

- Static lease `192.168.1.201`, OPNsense alias `sprint_femtocell`.
- The femtocell **doesn't answer ping** but does answer ARP. Its MAC has the Airvana OUI
  `00:05:B9`, the same prefix as the FEID in the official example. That supports the idea
  that FEID = MAC, which is still to be confirmed once the device presents its IKE identity.
- The OPNsense **network-wide** port-53 redirect works. From the VM, `dig` to 8.8.8.8,
  1.1.1.1, and 9.9.9.9, over both UDP and TCP, returns the cloaked `192.168.1.50`. So even a
  femtocell with hardcoded resolvers gets the cloaked answer.
- A 60-second capture on the VM saw **no traffic** from the femtocell while it was idling
  after boot. It has probably cached DNS or backed off. Next step: power-cycle it while
  capturing.

### 2026-10-27: Bootstrap DNS cloaking works on OPNsense
Status: Confirmed

- The OPNsense dnscrypt-proxy plugin has no "Cloaking" tab. Its **Overrides** tab is the
  place for cloaking rules. One override, `femto.sprint.net` -> `192.168.1.50`, covers the
  whole subdomain: `segw.femto.sprint.net` and a random `preflight-NNNN.femto.sprint.net`
  both resolve to the VM.
- Answers have TTL 600 (the `cloak_ttl` default). AAAA queries return no address.
- From the VM, `scripts/preflight.sh` now passes every DNS check.
- Not yet verified: the femtocell itself using OPNsense for DNS (needs the device online;
  see docs/02 2.3 for the redirect rule).

### 2026-10-27: VM built headlessly from the Ubuntu cloud image
Status: Confirmed

Host: Mac mini M4, macOS 26.7.1, VirtualBox 7.2.22 (ARMv8 only). VMs live on
`/Volumes/ssd_array/virtualbox_machines`, next to an existing `home_assistant_os` VM.

- **The cloud image works.** `noble-server-cloudimg-arm64.img` converted with
  `qemu-img convert -O vdi` boots under VirtualBox ARM with EFI, chipset `armv8virtual`,
  graphics `qemuramfb`, a VirtioSCSI disk, and virtio-net. A cloud-init NoCloud seed
  (`hdiutil makehybrid ... cidata`) on the same VirtioSCSI controller is picked up as
  `/dev/sr0`. No installer, no autoinstall confirmation prompt. Disk resized to 64 GB and
  `growpart` expanded root to 61 GB.
- **Use the full bridge adapter name.** `--bridge-adapter1 en0` gives
  `warning: Interface "en0" doesn't seem to exist` and the NIC isn't attached. The name has
  to match `VBoxManage list bridgedifs` exactly: `"en0: Ethernet"`. `controlvm 1xbts nic1
  bridged "en0: Ethernet"` fixed it on the running VM.
- **No Local Network permission prompt.** A VM started headless over SSH bridged fine and
  answered on 192.168.1.50 immediately.
- **`fou` and `ipip` ship in the stock kernel** (`6.8.0-147-generic`), so
  `linux-modules-extra` isn't needed. They autoload from `/etc/modules-load.d/1xbts.conf`
  after a reboot.
- **The VM also gets IPv6 via SLAAC** (`2601:602:...`). That's harmless; cloaking and the
  tunnel are IPv4.
- `cloud-init status` reads `disabled` after the seed ISO is ejected. That's expected, and
  the static netplan config it wrote stays in place.
- **Toolchain:** Docker 29.9.2 (aarch64) with Compose v5.6.1, and the Rust stable
  `aarch64-unknown-linux-gnu` toolchain.
- **Preflight:** everything passes except the bootstrap DNS checks. Cloaking isn't
  configured yet on OPNsense (`segw.femto.sprint.net` returns no answer), and the 1xBTS
  checkout doesn't exist yet. Upstream DNS through OPNsense works.

### 2026-10-27: Mac mini SSH and host quirks
Status: Confirmed

- **macOS temporarily rejects SSH password logins** after about 5 password logins in a
  couple of minutes ("Permission denied ... Too many authentication failures", with a
  correct password). It cleared by itself within a few minutes.
  `scripts/remote.sh` now reuses one connection (`ControlMaster`/`ControlPersist`), so
  that doesn't happen anymore.
- **The non-interactive SSH PATH** doesn't include `/usr/local/bin` (VBoxManage) or
  `/opt/homebrew/bin` (brew, qemu-img). Scripts export it explicitly.
- **Power settings were already server-grade** (`sleep 0`, `disksleep 0`, `womp 1`,
  `autorestart 1`), so nothing changed there.
- **Auto-login is off**, so the autostart LaunchAgent only runs after someone logs in. See
  docs/01 "Optional: start the VM headless at boot".


### 2026-10-27: Known risks going in
Status: Expected

- **ARM64 images.** The Mac mini M4 only runs ARM64 guests. Any 1xBTS Compose service
  that pulls an amd64-only image fails with `exec format error`. Check with
  `docker buildx imagetools inspect` before debugging anything else (docs/04 4.1).
- **VirtualBox bridging on macOS.** Bridged mode on Apple Silicon VirtualBox is newer than
  on x86. If the VM gets no DHCP or ARP replies, check promiscuous mode "Allow All", the
  macOS Local Network permission, and that the bridge is on Ethernet (`en0`), not Wi-Fi.
  The fallback is UTM with bridged networking.
- **Hardcoded DNS.** The femtocell may ignore DHCP-provided DNS. The OPNsense port-forward
  that redirects `femtocell:53` to the local resolver covers this (docs/02 2.3).
- **dnscrypt-proxy, not dnsmasq.** The official docs show `address=/femto.sprint.net/IP`
  (dnsmasq). The dnscrypt-proxy equivalent is a cloaking rule, `femto.sprint.net IP`, which
  matches the domain and all subdomains.
- **GPS/timing.** A tunnel that is up doesn't mean the radio works. The Airave needs GPS
  lock first. Cold start indoors may take a long time or never succeed. Antenna placement
  matters.
- **Host routes vanish.** `docker/femto/host-route.sh add` must be rerun every time
  `femto-segw` is recreated. Symptoms: tunnel up, but no audio or data.
- **Capabilities vanish.** `setcap` on `cdma-nib` is lost on every rebuild. Symptom: PDSN
  can't bind UDP 699 or receive GRE.
- **Credentials can't be invented.** 1xBTS has to be configured with the device's existing
  ACS, SIP, IKE, and EAP values. Avoid factory resets or firmware updates before you have
  them.
- **Mac sleep.** If the Mac sleeps, the VM pauses and the cell drops. Use `pmset`
  (docs/01 1.1).
