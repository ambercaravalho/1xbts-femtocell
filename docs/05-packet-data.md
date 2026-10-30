# 5. Packet data (1x and EV-DO)

Do this after voice and SMS work. Everything runs in the VM, in `~/1xbts`.

## 5.1 Generate secrets

```bash
~/1xbts-femtocell/scripts/gen-secrets.sh
```

This writes `~/1xbts-femtocell/secrets/packet.env` (mode 600) with:

- `A11_SHARED_SECRET_HEX`: 16 random bytes as hex, for `a11_security.shared_secret_hex`
- `A12_RADIUS_SECRET`: for `a12.radius_secret` and the femtocell's `term_auth_psk`

It never prints the values. It refuses to overwrite an existing file unless you pass
`--force`, because rotating the keys means re-syncing the femtocell.

## 5.2 `pdsn.local.json`

```bash
cp ~/1xbts-femtocell/config/pdsn.local.example.json ~/1xbts/config/pdsn.local.json
chmod 600 ~/1xbts/config/pdsn.local.json
```

Fill in `shared_secret_hex` (and `a12.radius_secret` if you use EV-DO) from
`secrets/packet.env`. If you don't use EV-DO, delete the `a12` block instead of leaving the
placeholder. Things to know:

- The `null` values under `a10_bearer` are deliberate. They remove the UDP endpoints
  inherited from the base config, and raw GRE mode rejects a config that still has them.
- `a11.bind_addr` is `172.31.0.1:699`, the same femto Docker network host address as
  `voice_bearer_bind_ip`.
- With `airave-25-5x`, provisioning pushes the A11 key and SPI to the femtocell. With
  `airave-25-2x`, check whether it does and record the answer in findings.
- **The A11 `SecurityKey` is effectively write-once.** Once the device has stored a key,
  re-provisioning with a *different* value faults `BatchTableOneXPcfPdsn: 9002 Internal Error`.
  The shared secret only has to **match** on both ends, so point `a11_security.shared_secret_hex`
  at the key the device already trusts rather than minting a fresh one. Only generate a new key
  (5.1) for a device that has never stored one, or expect to re-sync after a factory reset.
- If you define `a11_peers`, each one needs its own SPI. Select the femtocell's SPI with
  `packet.a11_spi` in `femto.local.json`.

## 5.3 PDSN privileges

PDSN needs `CAP_NET_RAW` (native GRE) and `CAP_NET_BIND_SERVICE` (UDP 699). Grant them to
the binary instead of running the core as root:

```bash
cd ~/1xbts
cargo build --release -p cdma-nib --no-default-features
sudo setcap cap_net_raw,cap_net_bind_service+ep target/release/cdma-nib
getcap target/release/cdma-nib
```

**Every rebuild drops the capability**, so reapply it each time. `start-core.sh` warns if
it's missing.

## 5.4 EV-DO (optional)

1. Fill in the site's `evdo` block (band, channel, sector ID, color code, `tx_power`) and set
   `enabled: true`. `tx_power` follows the same range as the 1x sector: -30 dBm floor, **+6 dBm**
   proven max on the FC330A (accepted fault-free).
2. **Match `evdo.sector_id` to the device's readback, including its `0x` prefix.** The Airave
   returns the 128-bit sector ID as `0x...`; a bare-hex value drifts against it, so the ACS
   keeps trying to `SET` a value the firmware rejects with `is856SectorElement.sectorId: 9002`
   (this unit's generic "RF value out of range / not accepted"). Set `sector_id` to exactly the
   `0x`-prefixed readback and it drops out of the drift set, no `SET` is attempted, and
   `configure-do` applies the rest cleanly.
3. For `airave-25-5x`: set top-level `term_auth_psk` in `femto.local.json` **equal to**
   `a12.radius_secret` in `pdsn.local.json`. Provisioning sends it to the device. Don't
   leave the PDSN secret empty while the device still holds a different one.
4. Handset data credentials must match the packet core's auth policy. The defaults
   accept some unverified authentication. That's fine for your own phones, but review it
   before anyone else's device can attach.

## 5.5 Apply and test

```bash
~/1xbts-femtocell/scripts/stop-core.sh
docker compose restart femto-core
~/1xbts-femtocell/scripts/start-core.sh
```

Then click **Sync femtocell** in the dashboard. Keep the `fou-nat` container running,
because it provides internet routing and DNS for handsets. Check **Packet Sessions** and
browse from the handset.

If data fails, check in this order: the PDSN address, matching A11 key and SPI on both
ends, `getcap`, the host routes (`host-route.sh add` after any SeGW recreate), and `fou-nat`.

On this setup both bearers come up fault-free and a handset attaches and browses. One open
item: confirm traffic actually rides **EV-DO** and is not falling back to 1x speeds (check
`evdo.enabled`, the DO sector admin/oper state in the ACS readback, the handset's EV-DO
capability and PRL, and that `term_auth_psk` matches `a12.radius_secret`).

## 5.6 MMS (optional)

MMS runs from a separate Compose profile in the 1xBTS checkout and does not need the SDR.

```bash
cd ~/1xbts
docker compose build mbuni                 # Mbuni 1.6.0 + Kannel 1.4.5, builds on arm64
docker compose --profile mms up -d         # MMSC + in-tree smsc-bridge (Kannel bearerbox)
```

The MMSC is reachable from mobiles at `http://mmsc.local.1xbts.org/` via the `fou-nat`
captive DNS; the WAP gateway is `10.55.0.1:9200/9201`. On the handset, set the MMSC URL and
WAP gateway to those values.

The `fou-nat` `edge-resolver` sidecar maps a data-plane IP to the subscriber's MSISDN. On the
femtocell path there is no BSC, so point it at the MSC's management endpoint
(`MGMT_GRPC_ADDR=host.docker.internal:17017`), which serves the equivalent lookup. See
[findings](findings.md) for the upstream `cdma-msc` change that exposes
`pdsn_management.v1.PdsnManagementService` there; that patch lives in the `chrismoos/1xbts`
checkout, not this repo.
