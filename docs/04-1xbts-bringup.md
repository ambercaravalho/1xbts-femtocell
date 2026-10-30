# 4. 1xBTS bring-up

Goal: the femtocell's tunnel comes up, ACS shows **Provisioned**, SIP shows **Registered**,
GPS locks, and a handset registers. This is the
[official femtocell guide](https://1xbts.org/docs/guides/femtocells/) adapted to the VM.
Everything runs **in the VM**.

Assumed layout in the VM:

```text
~/1xbts             # git clone https://github.com/chrismoos/1xbts.git
~/1xbts-femtocell   # this repo
```

The scripts read `ONEXBTS_DIR`, which defaults to `~/1xbts`.

## 4.1 Clone and check ARM64 support first

The biggest unknown on an M4 is whether every image and crate builds for `aarch64`. Check
that before you fill in any configs.

```bash
cd ~/1xbts
docker compose --profile femto config --images          # list the images the profile uses
docker compose --profile femto build 2>&1 | tee ~/femto-build.log
cargo build --release -p cdma-nib --no-default-features 2>&1 | tee ~/nib-build.log
```

For any image that is **pulled** rather than built, confirm it has an arm64 variant:

```bash
docker buildx imagetools inspect <image> | grep -E 'Platform:.*arm64'
```

`exec format error` at container start means an amd64-only image. Record it in
[findings](findings.md). Possible fixes, from best to worst: build that image from its
Dockerfile locally, swap in a multi-arch equivalent, or run it under qemu emulation with
`binfmt` (slow, and a poor fit for timing-sensitive services).

## 4.2 Local config files

Copy the templates from this repo into the 1xBTS `config/` directory and fill them in:

```bash
cp ~/1xbts-femtocell/config/femto.local.example.json ~/1xbts/config/femto.local.json
cp ~/1xbts-femtocell/config/msc.local.example.json   ~/1xbts/config/msc.local.json
chmod 600 ~/1xbts/config/*.local.json
```

Replace every `${...}` placeholder in `femto.local.json` with your device's values (see
[discovery](03-femto-discovery.md#33-credentials-checklist)). Quick check for anything you
missed:

```bash
grep -n '\${' ~/1xbts/config/*.local.json && echo "placeholders remain"
jq empty ~/1xbts/config/femto.local.json && echo "valid JSON"
```

Things to know about these files:

- Top-level `term_auth_psk` only applies to the `airave-25-5x` profile with EV-DO. Delete
  that line otherwise, rather than leaving the placeholder in place. Any `${...}` string
  left in the file is used literally as a secret.
- `1x.enabled` stays **false** until you have reviewed band, channel, and power.
- `max_sector_power_dbm` must be **-30 or higher** on the Airave 2.5 (anything lower is
  rejected). **+6 dBm is the proven usable max** on the FC330A (Sprint's own production value,
  accepted fault-free; see [findings](findings.md)). Start at the floor and raise after
  verifying; asking for more than +6 just faults 9002 and keeps the prior value.
- Keep `mcc` and `imsi_11_12` as **strings** so leading zeros survive.
- `msc.local.json` arrays **replace** the base config's arrays. If you later add SDR cells,
  list them all.
- `voice.voice_bearer_bind_ip` is `172.31.0.1`, the host's address on the femto Docker
  network. Confirm it after the stack is up, with
  `docker network inspect $(docker network ls -q --filter name=femto) | jq '.[].IPAM.Config'`.
  Never use a loopback address here.

## 4.3 Start the femto containers

```bash
cd ~/1xbts
sudo modprobe fou ipip              # already persistent if you followed step 1.7
docker compose --profile femto up -d --build
sudo docker/femto/host-route.sh add
docker compose ps
```

Rerun `sudo docker/femto/host-route.sh add` **every time the `femto-segw` container is
recreated**, including after `up --build` or a config change that recreates it. Without
the routes, the tunnel comes up but calls and data have nowhere to go.

## 4.4 Start the core (no SDR)

Wait for PostgreSQL to be healthy:

```bash
docker compose ps postgres          # STATUS: healthy
```

Then start the core with the helper script. It starts HLR, SMSC, and events, waits for HLR
to be listening, and then starts PDSN and MSC:

```bash
~/1xbts-femtocell/scripts/start-core.sh
# logs: ~/1xbts-femtocell/logs/core-a.log, core-b.log
~/1xbts-femtocell/scripts/stop-core.sh
```

The manual equivalent is two terminals, in this order:

```bash
target/release/cdma-nib --config-dir config --component cdma-hlr --component cdma-smsc --component cdma-events
# wait for HLR + SMSC "gRPC listening", then:
target/release/cdma-nib --config-dir config --component cdma-pdsn --component cdma-msc
```

If PDSN logs that MEID-to-IMSI lookup is disabled because HLR couldn't be reached, restart
the second process.

PDSN needs extra capabilities for packet data. Set them up now or later in
[packet data](05-packet-data.md). Voice and SMS work without them.

## 4.5 Power on the femtocell

Connect the GPS antenna, place it near a window, and power the device. Then watch:

```bash
docker compose logs -f --tail=100 femto-segw femto-core
docker compose exec femto-segw swanctl --list-sas     # an ESTABLISHED IKE SA = tunnel up
```

No IKE traffic at all? Run `sudo tcpdump -ni any udp port 500`. If nothing arrives, the
problem is DNS or the network, not 1xBTS. Go back to
[OPNsense DNS](02-opnsense-dns.md#25-verify).

## 4.6 Dashboard

Open `http://192.168.1.50:3000` from a LAN machine. Select the femtocell and check, in
order:

1. **ACS: Provisioned**
2. **SIP: Registered**
3. **GPS lock and timing**. This can take a while after a cold start.
4. **Radio** matches what you requested

After editing `femto.local.json`, run `docker compose restart femto-core` and then click
**Sync femtocell**.

To enable the radio once band, channel, and power look right, set `1x.enabled: true` in
`femto.local.json`, restart `femto-core`, and sync. The dashboard's **Enable femtocell**
button only *requests* the change. Wait until the reported radio state confirms it.

## 4.7 First handset

1. **Subscribers > add**: IMSI, ESN or MEID, and any auth credentials the handset needs.
2. Set the handset's PRL / SID / NID / band / channel to match the `1x` block. The
   template uses SID 22, NID 65535, BC1 channel 50.
3. Check **Mobiles** for the registration.
4. Test a call between two handsets on the cell, then an SMS. Calls to outside numbers need
   a SIP trunk (see the 1xBTS Voice Gateway guide).

This femto path uses **open registration with no CAVE auth**, so a compatible handset
registers on its native programming even with no HLR subscriber, and 1xBTS auto-sends a
welcome SMS on a mobile's first attach. Adding a subscriber (IMSI + ESN/MEID) still matters
for a stable MDN and for mobile-terminated SMS/calls to resolve. On this setup a Treo 700w
registered, received the welcome SMS, and completed a two-way call. Record what worked in
[findings](findings.md). Next: [packet data](05-packet-data.md).
