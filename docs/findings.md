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
| FEID | equals the MAC, `0005B9xxxxxx` | Confirmed (IKE IDi) |
| IKE identity | `<FEID>@femto.sprint.net` | Confirmed |
| EAP identity | `<FEID>` | Confirmed |
| IKE proposal | 3des-sha1-modp1024 (legacy default) | Confirmed |
| Responds to ping | No (ARP only) | Confirmed |
| Boot to first IKE attempt | ~4.5 min | Confirmed |
| IKE version | IKEv2 (`IKE_SA_INIT` to UDP 500) | Confirmed |
| Model | Airvana FC330A (Sprint Airave 2.5) | Confirmed (LAN portal realm) |
| LAN admin portal | http://192.168.17.1  admin / admin | Confirmed |
| Host SoC / FW | Broadcom BCM6358, host FW family 2.5.x (per writeup) | Expected |
| IKE group key | global Airave constant, validated on this unit | Confirmed |
| EAP-MD5 password | per-device, not yet recovered | Blocker |
| FCC ID | | |
| Firmware (2.x / 5.x) | 2.x assumed (profile airave-25-2x; confirm via ACS once up) | Expected |
| 1xBTS profile that works | | |
| FEID equals Ethernet MAC? | | |
| Bootstrap DNS names actually queried | | |
| Other hosts it tries to reach (from OPNsense block log) | | |
| Cold-start GPS lock time | GPS LED solid green within minutes of power-on | Expected |
| Credentials collected (yes/no per field, see docs/03 3.3) | | |

---

### 2026-10-27: IKE group key validated (global); EAP password is per-device
Status: Confirmed

A public reverse-engineering writeup of the Airave 2.5 (Airvana FC330A),
["Sprint Airave 2.5 Femtocell Architecture & Reverse Engineering"](https://studylib.net/doc/28842349/airave-arch),
documents the legacy tunnel/provisioning secrets recovered from a unit's flash (radio
module U-boot env on `mtdblock8`, and the VPD). Tested against our unit through the SeGW
identity probe:

- **`ike_group_key` is a GLOBAL firmware constant and it works on our unit.** With it set,
  the femtocell **accepted our SeGW's PSK authentication** and advanced to EAP: the log goes
  from the old "received unencrypted informational" rejection to
  `parsed IKE_AUTH request 2 [ EAP/RES/MD5 ]`. That is the proof the group key is right.
  (The value is a leetspeak constant; it's stored only in the VM's gitignored
  `config/femto.local.json`, not in this repo.)
- **`eap_password` (EAP-MD5) is per-device and unknown for our unit.** strongSwan reports
  `EAP-MD5 verification failed` / `EAP method EAP_MD5 failed`. Tried the writeup's
  `eap_preshared_key`, the shared operator/ACS password, the FEID, `cdmaFAP`, the
  `sapi_password`, and substrings. **All fail.** So this one really is unique to the unit,
  held in its radio module's U-boot env.
- EAP-MD5 is an offline MD5 challenge/response, but the password is a long random string, so
  capturing a response and cracking it is not practical.

Still-unverified writeup values to apply **after** the tunnel is up (they exercise only once
`femto-core` runs): the shared ACS/VPD/operator password, operator/ACS username
`<OUI>-cdmaFAP-<MAC-without-colons>`, a TR-069 Connection Request password, and the SAPI
password (host/radio only). SIP password was not in the recovered set. The literal values
are in the writeup and in the VM's gitignored config, not here.

**Remaining blocker:** read this unit's `eap_preshared_key` from its flash. Non-invasive
reads are exhausted (see below): telnet/SSH are closed on the customer LAN (the writeup's
root telnet needs `DEBUG_MODE=y`), and the host admin UI is only the consumer router. That
leaves opening the unit for a UART console or a flash dump (as the writeup did).

### 2026-10-27: Device is an Airvana FC330A; LAN port has an admin portal
Status: Confirmed

Looking for a way to read the device's stored credentials without opening it:

- **WAN side** (the port on our LAN, `192.168.1.201`): a top-200 TCP scan is all
  `filtered` (default-drop firewall). UDP shows only the expected 53/67/69/123/161/500/4500
  as `open|filtered`. No management service on the WAN side. A full 65535-port scan was
  still running when this was written.
- **LAN side:** the femtocell's LAN ports run a **DHCP + DNS server on `192.168.17.1`**
  (its LAN MAC is `00:05:b9:0b:51:6c`, one above the WAN MAC, same unit). A laptop plugged
  into a LAN port gets a `192.168.17.0/24` lease.
- A full TCP scan of `192.168.17.1` shows **only port 80 open**. It's an embedded web admin
  portal: `WWW-Authenticate: Basic realm="FC330A"`. Every path (including static assets)
  returns 401 until authenticated; unknown paths return 404; `OPTIONS` returns 501. The
  server banner is blank.
- **`FC330A` is the Airvana model number** for this femtocell (the Sprint Airave 2.5
  hardware). That pins the profile to the `airave-25-*` family.
- The LAN admin portal login is **`admin` / `admin`** (per the Airave 2.5 user manual, and
  confirmed on our unit). It's the Broadcom BCM6358 host's consumer router UI (WAN, LAN,
  VPN, devices), `mini_httpd` + `setup.cgi` framesets. The embedded server is flaky under
  back-to-back requests, so space them out and use `--no-keepalive`.
- Realm `FC330A` 401s on the stylesheet too; after login, the frameset lives at
  `setup.cgi?next_file=menu_ca_voip_sprint.htm` and `s_status.htm`.
- This host UI does **not** expose the radio module's tunnel credentials.

Open question: even with portal access, embedded GUIs rarely show the IKE PSK or EAP
password in plaintext. The portal may still reveal the firmware version (2.x vs 5.x) and
status, which is useful. The tunnel/provisioning secrets most likely require reading the
device's stored config (serial console or flash), or known-global Airave values.

### 2026-10-27: Identity probe: FEID = MAC, blocked on the IKE group key
Status: Confirmed

Ran only the SeGW (`docker compose --profile femto-segw-only up -d`) with placeholder
credentials and `feid` set to the MAC (`0005B9xxxxxx`). The device connected far enough to
reveal its identity before authentication failed. No secrets were sent to the device.

What the `femto-segw` (strongSwan 5.9.8) log showed:

- `192.168.1.201 is initiating an IKE_SA`, proposal
  `3DES_CBC/HMAC_SHA1_96/PRF_HMAC_SHA1/MODP_1024` (the `legacy` default `3des-sha1-modp1024`
  matches, so no proposal tuning needed).
- `IKE_AUTH request ... IDi` = **`0005B9xxxxxx@femto.sprint.net`**, EAP identity
  **`0005B9xxxxxx`**. So **FEID = Ethernet MAC** is confirmed, and the IKE identity is
  `<FEID>@femto.sprint.net` (matches `segw.ike_identity_domain` default `femto.sprint.net`).
- The SeGW selected peer config `fap-0005B9xxxxxx`, authenticated itself with the
  (placeholder) PSK, and sent `EAP/REQ/MD5`.
- The device **rejected** it: `received unencrypted informational ... NOTIFY` that
  strongSwan "could not decrypt". That is the device refusing the SeGW's PSK AUTH, i.e. the
  **`ike_group_key` is wrong** (expected, it was a placeholder). It never got to checking
  the EAP-MD5 password.

Credential model (from `crates/cdma-femto/src`):

| Secret | Where it's checked | Scheme |
| --- | --- | --- |
| `ike_group_key` | `segw.rs` strongSwan `secrets` | IKEv2 PSK the SeGW presents to the device |
| `eap_password` | strongSwan `eap-md5`, id = FEID | device authenticates to the SeGW |
| `acs.username` / `acs.password` | `acs/server.rs` `authenticate_fap` | HTTP Digest (device sends Authorization) |
| `sip.password` | `sip.rs` | SIP Digest |

All four are values the **device already holds**. 1xBTS has to be told the same values; it
can't assign new ones. Order they matter: group key (now), then EAP password, then ACS, then
SIP. The Digest/EAP exchanges only verify a secret, so the plaintext can't be recovered from
watching the device. It has to come from the device's stored config or a known Airave value.

The probe config lives at `~/1xbts/config/femto.local.json` on the VM (placeholders only).
The repo itself has no real credentials.

### 2026-10-27: Everything builds on ARM64
Status: Confirmed

- `docker compose --profile femto build` built `1xbts-femto`, `1xbts-femto-segw`,
  `1xbts-fou-nat`, and `1xbts-speedtest` in **3m47s** with no `exec format error` and
  no emulation.
- `cargo build --release -p cdma-nib --no-default-features` finished in **2m33s**
  (4 vCPU) on Rust 1.96.0 `aarch64-unknown-linux-gnu`.
- So the "ARM64 images" risk is **Disproved** for the femto profile. The `mms` profile
  (`mbuni`) hasn't been built yet.

### 2026-10-27: 1xBTS source, build deps, and legacy SeGW auth
Status: Confirmed (source), Expected (LED meanings)

- **Source:** [chrismoos/1xbts](https://github.com/chrismoos/1xbts), cloned to
  `~/1xbts` on the VM at `c78698f` (2026-10-24). `rust-toolchain.toml` pins Rust
  **1.96.0**, which rustup installs on the first build.
- **Missing build deps:** the official build page also needs `cmake`, `libprotobuf-dev`, and
  `libclang-dev` (for bindgen). They're now in `vm/provision-guest.sh`. The Baresip `re`
  library is only needed for the SIP voice gateway (external calls), not for the femto
  core.
- **The femto Compose profile** uses `postgres:17`, `node:25-bookworm`, `alpine/socat`,
  and local builds from `rust:1-bookworm` / `debian:bookworm-slim`. All are official
  multi-arch images, so arm64 should be fine.
- **Legacy SeGW auth** (`crates/cdma-femto/src/segw.rs`): strongSwan IKEv2 with
  `local auth = psk` (`ike_group_key`) and `remote auth = eap-md5`. `eap_identity` is
  optional and defaults to the FEID. The default IKE identity domain is `femto.sprint.net`.
- **Device LEDs after boot with GPS antenna connected:** Broadband solid green, **GPS solid
  green**, Mobile blinking green, VoIP phone off. Likely meanings: GPS locked, and Mobile
  blinking while the tunnel/service isn't up yet. That matches the unanswered IKE retries.

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
