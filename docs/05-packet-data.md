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

1. Fill in the site's `evdo` block (band, channel, sector ID, color code) and set
   `enabled: true`.
2. For `airave-25-5x`: set top-level `term_auth_psk` in `femto.local.json` **equal to**
   `a12.radius_secret` in `pdsn.local.json`. Provisioning sends it to the device. Don't
   leave the PDSN secret empty while the device still holds a different one.
3. Handset data credentials must match the packet core's auth policy. The defaults
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
