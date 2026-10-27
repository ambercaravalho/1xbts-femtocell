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
