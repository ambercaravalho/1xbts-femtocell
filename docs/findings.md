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
| EAP-MD5 password | per-device, recovered from radio U-boot env via root | Confirmed |
| Radio root access | radio SSH/telnet relay via host `/setup.cgi` ping injection; `su` password `root` | Confirmed |
| ACS username format | `<OUI>-cdmaFAP-<MAC>` (`0005B9-cdmaFAP-0005B9xxxxxx`) | Confirmed |
| Firmware (2.x / 5.x) | 5.x (device reports `SoftwareVersion 5.0.02.094` in its ACS Inform) | Confirmed |
| 1xBTS profile that works | `airave-25-5x` (the `2x` profile faults with CPE 9005 on this firmware) | Confirmed |
| Sector power range | -30 dBm floor; **+6 dBm** accepted fault-free for both 1x and EV-DO (Sprint production value) | Confirmed |
| Bootstrap DNS names queried | `segw.femto.sprint.net` family, cloaked to the VM (proven by IKE reaching the VM end to end) | Confirmed |
| Cold-start GPS lock time | GPS LED solid green within minutes of power-on; ACS readback reports `GPSGotFix=True`, `TimingGood=True` | Confirmed |
| Credentials collected (yes/no per field, see docs/03 3.3) | FEID, IKE group key, EAP identity, EAP password, ACS username, ACS password: all yes | Confirmed |

---

### 2026-10-30: Raised 1x and EV-DO sector power to +6 dBm (hardware max); carrier confirmed on air
Status: Confirmed
Context: Coverage was only a few feet at -10 dBm. Raised transmit power to the hardware max.

Observed:
- **Authoritative max.** The reverse-engineering writeup's captured Sprint *production*
  `airvana.xml` for this exact FC330A ran the 1x carrier at `sectorTxPower 6` (**+6 dBm**).
  1xBTS enforces only the **-30 floor** (`crates/cdma-femto/src/config.rs`
  `MIN_SECTOR_POWER_DBM`); there is no max in code, and the device self-limits to its FCC
  certification - it rejects out-of-range values with fault 9002 and keeps the prior value, so
  probing is non-destructive.
- **Applied.** Set 1x `max_sector_power_dbm` -10 -> 6 and `evdo.tx_power` -10 -> 6 in the VM's
  gitignored `femto.local.json` (timestamped backups kept), restarted `femto-core`.
- **Both applied clean.** The ACS pushed `MaxSectorPowerIndBm=6` and `sectorElementTxPower=6`,
  every `SetParameterValuesResponse status=0 (applied)`, **no 9002**. Readback confirms
  `MaxSectorPowerIndBm=6` and EV-DO `sectorElementAdminStatus=2` / `sectorElementOperStatus=2`.
- **Carrier confirmed On air.** The readback now shows `OneXSectorOperState=0` (`0` = On air),
  not the usual post-unlock `1` sampling artifact. That is ~16 dB (~40x) more power than before.

Fix / takeaway: **+6 dBm is the proven usable max for this FC330A** - it matches Sprint's own
production value and is accepted fault-free. Start new deployments at the -30 floor (radio
disabled) and raise after verifying; asking for more than +6 just faults 9002 and keeps the
prior value.

### 2026-10-30: Two-way voice call and handset data attach/browsing confirmed
Status: Confirmed (voice + data attach), Expected (EV-DO vs 1x throughput to verify)
Context: Physical handset tests after the packet core and MMS stack were stood up.

Observed:
- **Two-way voice call completed** over the femto 1x carrier.
- **Handset attached for packet data and browsed** the internet through the PDSN / `fou-nat`
  path.
- Throughput looked like **1x rather than EV-DO**; which bearer actually carried the session
  is not yet confirmed.

Fix / takeaway: Voice and data both work end to end on real hardware. Remaining: confirm the
data session is on EV-DO and not falling back to 1x (check `evdo.enabled`, the DO sector
admin/oper state in the ACS readback, the handset's EV-DO capability and PRL, and that
`term_auth_psk` matches `a12.radius_secret`); MT SMS delivery; and a round-trip MMS test.

### 2026-10-30: Enabled packet data (1x + EV-DO) and stood up the MMS stack
Status: Confirmed (infrastructure); handset attach/send is the remaining physical test

Context: Enabling data services and MMS. Both bearers (1xRTT + EV-DO) and manual MMS
routing (phone points at the local MMSC / WAP gateway).

Observed:
- **Packet core wired.** Created the VM's gitignored `pdsn.local.json` and added a top-level
  `packet` block (`adapter: external_pdsn`, `a11_spi: 256`) plus `term_auth_psk` to
  `femto.local.json`. PDSN comes up healthy: A11 bound on `172.31.0.1:699` (UDP), packet
  gRPC on `127.0.0.1:17021`, `raw_gre` A10 bearer. Host routing/firewall from
  `host-route.sh` already present: routes to `10.55.100.0/24` and `10.56.0.2` via the SeGW
  `172.31.0.2`, and iptables `ACCEPT` for A11 (udp 699), GRE (proto 47), A12 (udp 1812).
- **A11 `SecurityKey` must not change once the device has stored it.** First re-provision
  faulted `configure-onex-pdsn -> BatchTableOneXPcfPdsn: 9002 Internal Error`. The stage had
  run cleanly on every inform for a full day; the *only* thing that changed was the A11
  `OneXbatchTableSecurityKey` value (I had generated a fresh random key). The device accepts
  re-writing the 1x PCF/PDSN batch table with the value it already holds, but faults 9002
  when the key actually changes. **Fix / takeaway:** the A11 shared secret only has to
  *match* on both ends - set the PDSN's `a11_security.shared_secret_hex` to the key the
  device already trusts (the project default) rather than minting a new one. Fault cleared;
  both `configure-onex-pdsn` and `configure-do-pdsn` now apply with no fault.
- **EV-DO `sectorId` is hex-prefixed and effectively write-once; 9002 means "value the
  firmware won't take."** After the PDSN batch tables were clean, `configure-do` faulted
  `is856SectorElement.sectorId: 9002`. Two clues: (1) the code already documents the 1x power
  floor with "Lower values fault 9002," i.e. 9002 is this Airvana's generic "RF value out of
  range / not accepted"; (2) the device readback returns `sectorId=0x...` **with a `0x`
  prefix**, while the repo's reference value and a bare-hex copy of the readback both lack it,
  so drift detection kept trying to `SET` a value the firmware rejected. **Fix / takeaway:**
  set the desired `evdo.sector_id` to exactly match the readback (`0x` + the device's current
  128-bit value). It then drops out of the drift set, no `SET` is attempted on it, and
  `configure-do` applies the remaining RF params cleanly.
- **Both bearers on air, fault-free.** Final readback: 1x `AdminState=unlock`,
  `OneXSectorAdminState=unlock`, `MaxSectorPowerIndBm=-10`; EV-DO `sectorElementAdminStatus=2`,
  `sectorElementOperStatus=2`, `is856CarBandClass=1`, `is856CarChannelNumber=75`,
  `colorCode=58` (our value applied), cell id 403, tx power -10 dBm; `DataService=1`,
  `pdsnHealthStatus=1`, device points `OneXpdsnIpAddress=172.31.0.1` at our PDSN;
  `GPSGotFix=True`, `TimingGood=True`. (`OneXSectorOperState` still samples as `1` right after
  unlock - the known readback artifact, not a real off.)
- **Mbuni MMS stack builds and runs on arm64.** `docker compose build mbuni` succeeded on
  aarch64 (Mbuni 1.6.0 + Kannel 1.4.5 from pinned source) - the previously untested arm64
  build is confirmed good. `docker compose --profile mms up -d` brings up the MMSC (delivery
  queue threads running) and the in-tree smsc-bridge (Kannel bearerbox connected on 13002).
  Reachable from mobiles at `http://mmsc.local.1xbts.org/` via the fou-nat captive DNS.
- **Edge MSISDN resolver fixed for the femto path.** The `edge-resolver` sidecar in fou-nat
  looks up a data-plane IP -> subscriber MSISDN over `pdsn_management.v1.PdsnManagementService`
  (default `MGMT_GRPC_ADDR` = the BSC on `:17016`). On the femtocell path there is no BSC, and
  grep showed **no running component serves that service** - only the MSC's
  `mgmt.v1.NetworkManagementService.GetPdsnSessionByIp` (`:17017`) implements the same proxy,
  under a different gRPC service name. **Fix:** patched the upstream core checkout
  (`chrismoos/1xbts`, not this repo) so `cdma-msc` *also* serves
  `pdsn_management.v1.PdsnManagementService` on its existing management endpoint, delegating to
  the same packet-core client (`mgmt_proxy.rs` new `PdsnManagement` facade + one `add_service`
  in `runtime.rs`). Rebuilt `cdma-nib`, re-applied `setcap`, set
  `MGMT_GRPC_ADDR=host.docker.internal:17017`. Verified end to end: `edge-resolver` reaches the
  facade and a test lookup returns `10.55.0.2 -> no active session` (a clean miss, HTTP 200 with
  an empty `X-1xBTS-MSISDN` header) rather than a gRPC "unknown service" error. A real data
  session will resolve to the subscriber's `phone_number`.
- **Still to do (physical).** On the Treo: enable data, confirm 1x/EV-DO attach and browsing,
  set the MMSC URL to `mmsc.local.1xbts.org` and the WAP gateway to `10.55.0.1:9200/9201`, then
  send and receive a test MMS. Note the A11 `SecurityKey` and EV-DO `sectorId` lessons above if
  the device is ever factory-reset (the stored values are what the PDSN/ACS must match).

---

### 2026-10-30: Raised sector power to -10 dBm and provisioned the Treo as an HLR subscriber
Status: Confirmed
Context: Acting on the on-air confirmation below - more coverage so the handset holds, and a
stable identity for it.

Observed:
- **Sector power raised and confirmed live.** Set `1x.max_sector_power_dbm` from the `-30` floor
  to **`-10` dBm** in the VM's gitignored `femto.local.json` (timestamped backup kept) and
  restarted `femto-core`. On the next inform the ACS logged `configured parameter drift:
  MaxSectorPowerIndBm`, ran the full configure stages (`configure-onex-pdsn`,
  `configure-do-pdsn`, `configure-all`), pushed `MaxSectorPowerIndBm = -10`, and the status
  readback confirms `MaxSectorPowerIndBm=-10` on the device. That is ~20 dB (≈100x) more than
  before - room-level coverage instead of a few feet.
- **Treo provisioned in the HLR.** Created a subscriber via the dashboard API with IMSI (310/00
  + its MIN-based MSIN) + ESN as the primary identity, MDN = its MIN-based number, display name
  "Palm Treo 700w (Verizon)", status active. Subscriber list now `total: 1`. Identifiers kept
  out of this repo.
- **The handset is a Verizon device, not Sprint.** Acquisition on our SID 22 / BC1 ch50 works on
  its native programming regardless, but any later MSL recovery / PRL / OTASP work must use
  Verizon tooling and defaults - not the Sprint-Airave toolkit values.
- The welcome SMS will not re-fire (no longer `is_new`); the pending test SMS ("hello!!") should
  deliver when the phone next registers / is paged.

Fix / takeaway: Power and identity are in place and confirmed on the device. The remaining
confirmation is RF-side: the handset re-registering at the higher power, staying attached, and
MT SMS delivering to the now-known subscriber.

### 2026-10-29: Carrier confirmed ON AIR - the real Treo 700w registered and got the welcome SMS, unprovisioned
Status: Confirmed
Context: While staging the handset steps, the Treo 700w powered up near the femto and attached
on its own. This supersedes the "never observed on air" caveat in the entry below.

Observed:
- **RF-side proof the 1x carrier is radiating.** The MSC repeatedly accepted the handset's
  registration (A1 `CompleteLayer3Information` -> `LocationUpdatingAccept`, `MSC: registration
  accepted for IMSI <redacted>`), and the dashboard `/api/mobiles` shows it `state: Registered`
  on serving cell 403 / sector 0. So the dashboard `radioOperationalState: Off` is confirmed to
  be only the post-unlock sampling artifact from the entry below - the radio is NOT actually off.
- **It attached on its NATIVE Sprint programming with no HLR subscriber** (subscribers total 0)
  and no reprogramming. This femto path uses OPEN registration and no CAVE auth, so an
  unprovisioned mobile registers. Its IMSI (`310` + `00` + MIN-based MSIN) and ESN/pESN are now
  known from the registration - kept out of this repo.
- **1xBTS auto-sent the welcome SMS.** It is MSC-owned, queued for a first-time mobile
  (`is_new`) in `crates/cdma-msc/src/runtime.rs` (text "Welcome! You are now connected to a live
  CDMA2000 1X base station..."); the SMSC logged it `Delivered`. That is the "welcome text" seen
  on the phone.
- **A later test SMS** (from the dashboard Messages page, originating `5551234`, "hello!!") is
  queued `accepted` with `failureReason: no attached serving node` because the handset has since
  gone idle/detached (last heard ~7 min before this check). It should deliver when the phone is
  paged / re-registers.
- Registration recurs on the handset's own periodic timer (pairs roughly every ~30 min in the
  log). Sector power is at the `-30 dBm` floor, so coverage is only a few feet; small movement or
  attenuation drops the pilot and the Treo re-scans, which is the likely "it disconnected".

Fix / takeaway: The radio works; the reuse-identity plan is validated end to end. To keep the
handset attached reliably: raise `max_sector_power_dbm` above the `-30` floor for more coverage;
optionally create an HLR subscriber (IMSI + ESN/MEID) to give it a stable MDN and so MT SMS /
calls resolve cleanly; a custom PRL pinning the femto system improves adhesion. OTASP/MSL and
QPST reads are not required just to attach.

### 2026-10-29: Radio "Off" diagnosed - carrier never observed on air; the readback samples post-unlock; LocationCheckStatus UNKNOWN
Status: Confirmed (diagnosis), Expected (a handset is the real on-air test)
Superseded by: 2026-10-29 "Carrier confirmed ON AIR" below - the carrier is radiating; the
`OneXSectorOperState=1` "Off" readback was only the post-unlock sampling artifact.
Context: Determining why `radioOperationalState` stays Off now that the core is up and the
sector is admin-unlocked, as the gate before connecting a Treo 700w. Read live over SSH to the
VM and the dashboard API; nothing was changed.

Observed:
- **Everything 1xBTS controls is healthy.** Live `getFemtoCellStatus` (the dashboard call,
  `GET /api/femtocells/status?baseStation=http://127.0.0.1:17024&peerId=<FEID>`):
  `acsProvisioned`/`acsConfigured`/`sipRegistered` all true, `gpsStatus: Locked`,
  `timingStatus: Synchronized`, `profile: airave-25-5x`, GPS fix at the expected coordinates.
  The IKE/CHILD SA is `ESTABLISHED`/`INSTALLED` with steady bidirectional ESP.
- **The ACS readback is correct on every axis except oper state.** Each periodic inform shows
  `AdminState=unlock`, `OneXSectorAdminState=unlock`, `TimingGood=True`, `GPSGotFix=True`,
  `OneXSectorBandClass=1`, `OneXSectorChannelFreq=50`, `OneXSectorSID=22`,
  `OneXSectorNID=65535`, `MaxSectorPowerIndBm=-30`. The only off value is
  `OneXSectorOperState=1` (Off).
- **The Off reading is sampled too early to be trustworthy.** Every provisioning pass runs
  `lock-onex -> lock-sector -> unlock` and then reads status ~1 s after the unlock. A CDMA
  carrier needs tens of seconds to come up, so this snapshot can never show On air. Across all
  10 readbacks in the current log window `OneXSectorOperState` is `1` and has **never** read
  `0`. That is not proof the carrier is dead - but there is also no positive confirmation it is
  radiating.
- **`LocationCheckStatus=UNKNOWN` (and `TimingSource=0`) in the inform.** 1xBTS records
  `LocationCheckStatus` (`crates/cdma-femto/src/cell.rs:425`, as `location_validation_status`)
  but never acts on it and sends no location approval, so the Airave's own location-validation
  transmit gate is left unsatisfied. There is no location-approval stage in the ACS.
- `sectorElementOperStatus=1` is the **EV-DO/DO** sector, intentionally admin-down
  (`EVDO_SECTOR_ADMIN_DOWN="1"`), not the 1x carrier. Femto radio-metric streaming is
  `UNIMPLEMENTED` and the channels endpoint is SDR-only (empty here), so neither gives a live
  RF view of the femto carrier.

Fix / takeaway: Nothing in the 1xBTS configuration is wrong; the dashboard "Off" is at least
partly an artifact of reading `OneXSectorOperState` immediately after `unlock`. The
authoritative on-air test is RF-side - a handset acquiring the pilot (plan Phase 4). Optional
network-side confirmation without a handset: re-run the Sprint-Airave root toolkit
(`Sprint-Airave-Airvana-2.5-Root/2-5/airave-provision.py`) to reopen the radio-module relay and
query the sector's live operational/RF state directly (runtime-only, needs a laptop on the
femto LAN `192.168.17.x`; the relay is lost on power cycle). Handset auth posture: the HLR
`upsertSubscriber` API takes IMSI + ESN/MEID only (no A-key field), so CAVE authentication is
not enforced - a subscriber with no A-key will register.

### 2026-10-29: CDMA core up, base station attached, radio administratively enabled
Status: Confirmed (core + admin-unlock), Expected (carrier on air after timing warm-up)
Superseded by: 2026-10-29 "Carrier confirmed ON AIR" below - the carrier went on air once GPS
timing settled.
Context: Brought up the shared `cdma-nib` core and enabled the 1x radio so a handset can be
connected. Voice/SMS scope; packet data deferred.

Observed:
- **`msc.local.json` was required and is now in place.** Copied from the template; the
  defaults are correct for this setup (`base_stations[0].management_endpoint`
  `http://127.0.0.1:17024`, `voice.voice_bearer_bind_ip` `172.31.0.1`, which is the confirmed
  femto Docker network gateway/host).
- **`cdma-nib` needs `cap_net_bind_service,cap_net_raw`.** `scripts/start-core.sh` launches
  PDSN+MSC in one process; without the caps the PDSN A11 bind on UDP 699 fails and can take
  the MSC down. `sudo setcap cap_net_raw,cap_net_bind_service+ep target/release/cdma-nib`
  fixed it (dropped on every rebuild - reapply). No `pdsn.local.json` is needed for voice;
  the base `femto.json` `packet` block provides working PDSN defaults that idle.
- **Core came up clean and the base station attached.** HLR (17019), SMSC (17020),
  events (17023), MSC (17017) all listening; `MSC: base station femto-fcs-1 attached
  (management=127.0.0.1:17024 a1=172.31.0.2:17013)`; the dashboard base-station API shows the
  cell `inService: true` (SID 22, NID 65535, MCC 310). BSC 17016 stays down - that is the SDR
  radio-access port and not used on the femto path. The MSC voice-gateway warning
  (`127.0.0.1:17015 unavailable`) is expected; that gateway is only for external/PSTN SIP
  trunking.
- **Radio enabled in config and pushed to the device.** Set `1x.enabled: true`, restarted
  `femto-core`. On the next device inform the ACS ran the `unlock` stage and the readback
  showed `AdminState=unlock`, `OneXSectorAdminState=unlock`. So the sector is administratively
  on.
- **ACS-initiated Connection Request / "Sync" does not work through the tunnel.** From the
  host (which has the route to the FAP VIP via the SeGW), `curl http://10.55.100.1/acscall`
  times out, and `RequestProvisioningSync` returns `DEADLINE_EXCEEDED`. The device only
  re-provisions on its own **periodic/boot inform**. Takeaway: after a config change, either
  wait for the periodic inform or **power-cycle the device** to force a fresh provisioning
  pass; the dashboard Sync/Reboot buttons rely on the same unreachable connection-request path.
- **Carrier on-air is gated on GPS timing after a cold boot.** `radioOperationalState` maps
  from `OneXSectorOperState` (`0` = On air, `1` = Off; `crates/cdma-femto/src/fap.rs:335`).
  After the power-cycle, `GPSGotFix=True` quickly but `TimingGood` oscillates and the carrier
  stays `OneXSectorOperState=1` (Off) until timing holds. Expected cold-start warm-up; the
  carrier should go On air once timing is stable, reported on the following inform.

Fix / takeaway: Core bring-up and radio admin-enable are done and survive on the VM. Remaining
to actually place a call: let GPS timing settle so the carrier goes On air, then provision a
subscriber in the HLR and program a compatible CDMA 1x (PCS/BC1) handset to SID 22 / NID 65535
/ channel 50 with a matching MIN/IMSI. The handset acquiring the pilot is the real confirmation
that the carrier is live.

### 2026-10-29: Tunnel established and ACS Provisioned; device firmware is 5.x, profile corrected
Status: Confirmed
Context: Applied the recovered per-device credentials to the VM and brought the femto stack up
end to end. The six values live only in the host's gitignored `.env` and in the VM's
gitignored `~/1xbts/config/femto.local.json`; nothing secret is pasted here.

Observed:
- **Two credentials on the VM were stale.** Comparing each field by SHA-256 (never printing
  the value), the VM's `femto.local.json` matched `.env` for `feid`, `ike_group_key`, and
  `acs.username`, but its `segw.eap_password` and `acs.password` were different/wrong, so the
  SeGW was looping `EAP-MD5 verification failed` on every device retry. Patched both fields to
  the `.env` values (piped over SSH on stdin, re-`chmod 600`, backup at `femto.local.json.bak`).
- **EAP passed and the tunnel came up.** `femto-segw-config` regenerated `swanctl.conf`, the
  SeGW monitor loop auto-reloaded it, and the next `IKE_AUTH` logged
  `EAP method EAP_MD5 succeeded`. `swanctl --list-sas` shows an `ESTABLISHED` IKEv2 SA plus an
  `INSTALLED` CHILD_SA (ESP, device VIP `10.55.100.1`), with steady traffic in both directions.
- **The device firmware is 5.x, not 2.x.** Its ACS Inform reports `SoftwareVersion=5.0.02.094`.
  Under the configured `airave-25-2x` profile, every ACS session ended with
  `CPE Fault 9005 Invalid Parametername -> EndSession` (the 2x `batch_queries` pre-read and
  `status_query` reference parameter paths this firmware does not expose), and the device kept
  re-informing as `0 BOOTSTRAP` without finalizing.
- **Switching to `airave-25-5x` fixed provisioning.** All stages now apply `status=0`
  (`configure-onex-pdsn`, `configure-do-pdsn`, `configure-all`, `unlock`), the full status
  readback completes with real values, and no session-ending fault remains. The EV-DO (`is856`
  / DO) "cannot derive ... from its configured source" lines are expected WARNINGs because
  EV-DO is disabled (no `term_auth_psk`); the DO sector is left admin-down.
- **Authoritative state** from the femto management API (`getFemtoCellStatus`, the same call the
  dashboard uses): `acsProvisioned: true`, `acsConfigured: true`, `sipRegistered: true`,
  `gpsStatus: Locked`, `timingStatus: Synchronized`, `radioOperationalState: Off`.

Confirms / clarifies earlier findings:
- The `.env` `eap_password` (16 chars) and `acs.password` (8 chars) are the correct per-device
  values; the previously stored VM values were stale. Keep `.env` as the source of truth.
- **SIP registers with the SIP password already on the VM**, even though SIP was never in the
  recovered set. No SIP value was needed from `.env` for this unit.
- EAP identity: the bare FEID worked; the domain-form fallback was not needed.

Fix / takeaway: On this unit use `profile: "airave-25-5x"`. The radio is intentionally left
disabled (`1x.enabled: false`, `radioOperationalState: Off`); enabling it, starting the CDMA
core, and registering a handset are the next steps. The SeGW unlock from the recovery day is
not required for normal operation (that was only to read the credentials). After any power
cycle, the device re-establishes the tunnel on its own and the ACS re-provisions it.

### 2026-10-27: Root on the radio module; all six credentials recovered (blocker cleared)
Status: Confirmed
Context: The remaining blocker was reading this unit's per-device `eap_preshared_key` from
flash without opening the case. Cloned the public root toolkit
[dondaplayer1/Sprint-Airave-Airvana-2.5-Root](https://github.com/dondaplayer1/Sprint-Airave-Airvana-2.5-Root)
into this repo and ran its `2-5/airave-provision.py` against the host admin LAN.

Observed:
- The script unlocks runtime access through the host's consumer router: it uses a
  `/setup.cgi` diagnostics **ping command injection** to (1) allow LAN access to host
  telnet/HTTPS, (2) enable IP forwarding, (3) remove the blackhole route to the internal
  radio (`192.168.255.2`), (4) forward LAN TCP `23022` -> radio SSH `22`, and (5) forward
  LAN TCP `23023` -> radio telnet `23`. It then logs into the radio and reads credentials
  from its environment/config, supplementing masked values from the raw env partition.
- Ran it with the laptop on a LAN port (`192.168.17.2`), `--host 192.168.17.1 --lan
  192.168.17.0/24`. All five unlock steps succeeded and it printed the **six fields**:
  FEID, IKE group key, EAP identity, **EAP password**, ACS username, ACS password.
- SSH'd to the radio as `0005B9-cdmaFAP-0005B9xxxxxx` on port `23022` (legacy
  KEX/host-key/cipher/MAC algorithms required), authenticated with the printed radio
  password, then `su` with password `root` -> `sh-3.1#`. Confirmed a root shell on the
  **radio module** (separate from the host shell on port 23).

Confirms / clarifies earlier findings:
- **EAP password (the blocker) is now in hand.** It is a per-device value held in the radio
  module's U-boot env, exactly as reasoned. Clears the "Remaining blocker" from the entry
  below.
- **IKE group key matches the global leetspeak constant** already validated via the SeGW
  probe. Independent confirmation that the recovered value is correct.
- **ACS username = `<OUI>-cdmaFAP-<MAC>`**, matching the writeup's predicted format.
- Nuance on EAP identity: the device's **stored** `EAP_IDENTITY` includes the domain
  (`0005B9xxxxxx@femto.sprint.net`), whereas during the IKE probe it presented the **bare
  FEID** on the wire for EAP. Keep the 1xBTS `eap_identity` as the bare FEID unless auth
  fails, then try the domain form.

Fix / takeaway: Blocker cleared. Put the six real values only in the VM's gitignored
`config/femto.local.json` (never in this repo). The unlock is **runtime only** and does not
survive a reboot, so rerun `airave-provision.py` after any power cycle (use `--skip-unlock`
only if the relays already exist). Next: bring up the SeGW with the real group key + EAP
password and watch for `IKE_AUTH` success past EAP-MD5, then wire ACS (and SIP later).

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
