# 3. Femtocell discovery

Goal: know exactly which device you have, which 1xBTS profile it needs, and which of its
own credentials you need to collect. 1xBTS cannot assign new credentials. The values in
`femto.local.json` must match what the device already expects.

Record everything you learn in [findings](findings.md). Never record secret values there.
Put those in your private `config/femto.local.json` only.

## Ground rules

- **Do not factory-reset or firmware-update the device** until you know what it does to
  the stored credentials. A reset can wipe the values you need.
- Don't let the device reach the real internet unattended. Sprint's servers are gone, but
  limiting its egress (see [DNS 2.4](02-opnsense-dns.md#24-optional-restrict-the-femtocells-egress))
  keeps its behavior predictable and gives you a log of what it tries.
- Photograph the label before you do anything else.

## 3.1 Identify the model

| Clue | Where |
| --- | --- |
| Model name ("AIRAVE 2.5" vs "AIRAVE 2.5+"), manufacturer (Airvana), FCC ID | Bottom label |
| Ethernet MAC address | Label, or the OPNsense DHCP lease |
| Serial number | Label |
| GPS antenna port and antenna | Back panel / box |

Pick the 1xBTS profile:

| Device | Profile | Notes |
| --- | --- | --- |
| Airave 2.5, 2.x firmware | `airave-25-2x` | |
| Airave 2.5, 5.x firmware | `airave-25-5x` | Provisioning also pushes A11 key/SPI and the term-auth PSK |
| Airave 2.5+ | `airave-25plus` | Service is BC1 / 1900 MHz PCS only. The 800 MHz radios are only discovery beacons |
| Anything else | `standard-xs0059` | Generic starting point. Not covered by the Airave support claims |

The FEID in the official example (`0005B9AABBCC`) starts with `0005B9`, which looks like
a MAC OUI. **Check** whether your device's FEID equals its Ethernet MAC without separators,
and record the answer in findings.

## 3.2 Identify the firmware (2.x vs 5.x)

Firmware only matters for the Airave 2.5 (`2x` vs `5x` profiles). Ways to find it, from
least to most invasive:

1. A sticker or the original box/paperwork.
2. A local status web page or LED behavior, if the device has one. Record what you find.
3. **Observe it on the wire.** With DNS cloaking in place (step 2), power it on and watch
   the VM:

   ```bash
   sudo tcpdump -ni any 'udp port 500 or udp port 4500' -c 20
   docker compose logs -f femto-segw     # once the femto stack is running (step 4)
   ```

   The IKE exchange shows the identity the device presents and the proposals it offers.
   Even a failed authentication tells you a lot.
4. **ACS (TR-069) Inform.** Once the tunnel is up, the device's first Inform to the 1xBTS
   ACS reports its software version. If the tunnel only comes up with one of the two
   profiles, that is your answer.

If you can't tell, start with `airave-25-2x`. Switch to `airave-25-5x` if the tunnel comes
up but provisioning misbehaves. Record which one worked.

## 3.3 Credentials checklist

All of these come from **your device**. To find out how a given model or firmware stores
them, check the [1xBTS femtocell docs](https://1xbts.org/docs/guides/femtocells/), or ask in
the project's GitHub Discussions (linked from the [1xbts.org](https://1xbts.org/docs/)
footer) or on IRC `#1xbts`. Collect them into your private
`config/femto.local.json`. The template is
[`config/femto.local.example.json`](../config/femto.local.example.json).

| Value | `femto.local.json` field | Have it? | Source / notes (no secret values here) |
| --- | --- | --- | --- |
| FEID | `sites.<name>.feid` | [ ] | |
| Profile | `sites.<name>.profile` | [ ] | from 3.1 / 3.2 |
| ACS username | `sites.<name>.acs.username` | [ ] | |
| ACS password | `sites.<name>.acs.password` | [ ] | |
| SIP password | `sites.<name>.sip.password` | [ ] | |
| IKE group key | `sites.<name>.segw.ike_group_key` | [ ] | legacy profile: the PSK the SeGW authenticates itself with |
| EAP identity | `sites.<name>.segw.eap_identity` | [ ] | **optional**, defaults to the FEID; only set it if the device's EAP identity differs |
| EAP password | `sites.<name>.segw.eap_password` | [ ] | legacy profile: the femtocell authenticates with EAP-MD5 |

How the `legacy` profile works (from `crates/cdma-femto/src/segw.rs`): strongSwan answers
IKEv2 with `local auth = psk` (the group key) and `remote auth = eap-md5` (the femtocell's
EAP identity and password). The device sends its identity early in `IKE_AUTH`, so
`femto-segw` logs will show the IDi / EAP identity even before the credentials are right.
That confirms the FEID without opening the device.
| Term-auth PSK (5.x, EV-DO) | top-level `term_auth_psk` | [ ] | must equal PDSN `a12.radius_secret` |

Copy this table into findings with the "Have it?" column filled in, but never the values.

### 3.3.1 Identity probe (confirms FEID without credentials)

With DNS cloaking working (step 2), run only the SeGW with **placeholder** secrets and your
guessed FEID. The device reveals its identity before authentication fails:

```bash
cd ~/1xbts
# femto.local.json: set feid to the MAC without separators, profile airave-25-2x,
# security_profile legacy, and any non-empty placeholder ike_group_key / eap_password.
docker compose --profile femto-segw-only up -d
docker compose logs -f femto-segw | grep -E 'IKE_SA_INIT|IDi|peer config|EAP|informational'
docker compose --profile femto-segw-only down
```

Read the result:

| Log line | Meaning |
| --- | --- |
| `looking for peer configs matching ...[<FEID>@femto.sprint.net]` | the device's real IKE identity, so the FEID is confirmed |
| `selected peer config 'fap-<FEID>'` | your `feid` matches the device |
| `no matching peer config found` | your `feid` is wrong; use the identity from the IDi line |
| `received unencrypted informational ... NOTIFY` right after our `AUTH` | the device rejected our PSK, so **`ike_group_key` is wrong** |
| `EAP method EAP_MD5 succeeded` | group key right, EAP password right |

On this unit the probe confirmed FEID = MAC, validated the global IKE group key, and
stopped at the per-device EAP-MD5 password (see findings). Leave the radio disabled for
this test; the SeGW never sends configuration to the device.

### 3.3.2 Where the Airave 2.5 (FC330A) credentials come from

The device is a two-processor Airvana FC330A: a Broadcom BCM6358 host (router, web UI,
DHCP) and an MPC8313 radio module that terminates the IPsec tunnel and runs the CDMA stack.
A public writeup,
["Sprint Airave 2.5 Femtocell Architecture & Reverse Engineering"](https://studylib.net/doc/28842349/airave-arch),
documents how the secrets are stored and recovered.

| Secret | 1xBTS field | Scope | How to get it |
| --- | --- | --- | --- |
| IKE group key | `segw.ike_group_key` | **global** Airave 2.5 constant | from the writeup; validated by the probe advancing to EAP |
| EAP-MD5 password | `segw.eap_password` | **per-device** | read from the radio module's U-boot env / VPD (requires a shell or flash dump) |
| ACS password | `acs.password` | shared constant | from the writeup |
| ACS/operator username | `acs.username` | derived | `<OUI>-cdmaFAP-<MAC-without-colons>` |
| SIP password | `sip.password` | unknown | not in the recovered set; TBD |

Non-invasive reads that **don't** work on a stock unit: telnet/SSH are closed on the
customer LAN unless `DEBUG_MODE=y` is set in the radio's U-boot env, and the host web UI
(`admin`/`admin`) only shows the router, not the radio's keys. Getting the per-device EAP
password therefore means opening the unit and either attaching a 3.3V UART to get a shell or
dumping the flash to read the U-boot env, as the writeup did.

## 3.4 Radio-side facts to collect

These decide the `1x` / `evdo` blocks:

| Fact | Why |
| --- | --- |
| Supported band class(es) | Airave 2.5+ serves BC1 only. Your handset must support the same band |
| A channel the device accepts | `1x.channel`. Use the official example (BC1 ch 50) until you know better |
| Minimum transmit power | Airave 2.5 rejects below **-30 dBm** |
| GPS lock time at your antenna position | The radio won't come up without timing |
| Whether EV-DO is supported/wanted | `evdo.enabled` is a separate carrier |

## 3.5 Handset facts

For each test phone: IMSI (or MIN), ESN or MEID, supported bands, and whether you can
edit its PRL / SID / NID. You'll add these under **Subscribers** in the dashboard in
[step 4](04-1xbts-bringup.md#47-first-handset).

Next: [1xBTS bring-up](04-1xbts-bringup.md).
