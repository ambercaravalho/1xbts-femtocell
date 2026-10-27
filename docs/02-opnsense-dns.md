# 2. OPNsense DNS (dnscrypt-proxy)

Goal: when the femtocell looks up its security gateway (`segw*.femto.sprint.net`),
OPNsense answers with the VM's LAN address (`192.168.1.50` in these examples). This must
work **before** the tunnel exists, so it has to happen on the LAN resolver, not inside
1xBTS.

This setup has dnscrypt-proxy (the `os-dnscrypt-proxy` plugin) answering LAN clients
directly on port 53, with Unbound not in the path. dnscrypt-proxy's equivalent of a
dnsmasq `address=/femto.sprint.net/...` override is **cloaking**.

## What to configure

| Step | Where in OPNsense | Purpose |
| --- | --- | --- |
| Static lease for the femtocell | Services > DHCP (ISC or Kea) > LAN > static mappings | Stable IP to use in NAT and firewall rules |
| Cloaking rule | Services > DNSCrypt-Proxy > **Overrides** (the plugin's name for cloaking rules) | `femto.sprint.net` -> VM IP |
| DNS redirect NAT rule | Firewall > NAT > Port Forward | Catches a femtocell that ignores DHCP DNS and uses hardcoded resolvers |
| (Optional) egress restriction | Firewall > Rules > LAN | Keeps the femtocell from talking to anything but the VM, DNS, and NTP |

## 2.1 Static lease for the femtocell

The femtocell's MAC is on its label. You can also find it under **Services > DHCP > Leases**
after its first boot. Create a static mapping outside the dynamic pool. This setup uses
`192.168.1.201`. Leave the DNS server field empty, or set it to the OPNsense LAN address
`192.168.1.1`.

Then create a host alias in **Firewall > Aliases**. This setup uses
`sprint_femtocell = 192.168.1.201`. The rules below use it.

## 2.2 Cloaking rule

The OPNsense plugin has no tab named "Cloaking". Its **Overrides** tab is where you add
cloaking rules. Add one override:

| Name / pattern | Destination |
| --- | --- |
| `femto.sprint.net` | `192.168.1.50` |

In dnscrypt-proxy, a bare domain pattern matches the domain **and every subdomain**, so
`segw.femto.sprint.net`, `segw01.femto.sprint.net`, and backup names are all covered.
You don't need a `segw*` wildcard, which DNS wouldn't support anyway. The same rule in file
form is in [`opnsense/dnscrypt-cloaking.txt`](../opnsense/dnscrypt-cloaking.txt).

Notes:

- Cloak only `femto.sprint.net`. The `*.spcsdns.net` provisioning and SIP names
  (`fsmhdm.femto.spcsdns.net`, `fap.airave2.ims.spcsdns.net`) are answered by 1xBTS
  **inside** the tunnel. Cloaking them on the LAN does nothing useful and can be confusing.
- Cloaked answers are cached for `cloak_ttl` seconds (600 by default). If you change the
  VM's IP, lower the TTL or reboot the femtocell so it re-resolves.
- An AAAA query for a cloaked name gets no address back. That's fine because the tunnel is
  IPv4.
- Apply or save, then restart the dnscrypt-proxy service.

## 2.3 Make the femtocell actually use OPNsense

The femtocell normally uses the DNS server handed out by DHCP. That is the OPNsense LAN
address, as long as a DNS service listens on port 53 there. Embedded devices sometimes
hardcode public resolvers, so add a redirect as a safety net.

This setup already has a **network-wide** redirect that sends every LAN client's port-53
traffic to OPNsense, so nothing femtocell-specific is needed. Confirmed from the VM:
`dig @8.8.8.8`, `@1.1.1.1`, and `@9.9.9.9` (UDP and TCP) for `segw.femto.sprint.net` all
return `192.168.1.50`. If you don't have one, add a rule scoped to the femtocell:

**Firewall > NAT > Port Forward > Add:**

| Field | Value |
| --- | --- |
| Interface | LAN |
| Protocol | TCP/UDP |
| Source | alias `sprint_femtocell` (or `LAN net` for a network-wide redirect) |
| Destination | `This Firewall`, with **Destination / Invert** checked |
| Destination port | DNS (53) |
| Redirect target IP | `127.0.0.1` |
| Redirect target port | the port dnscrypt-proxy listens on (53, unless you moved it) |
| Filter rule association | Add associated filter rule |

Check where dnscrypt-proxy listens under **Services > DNSCrypt-Proxy > General >
Listen address**. If it binds only to the LAN address and not loopback, use the LAN
address as the redirect target.

Also consider blocking TCP 853 (DNS over TLS) from `sprint_femtocell`. It shouldn't be used, but
blocking it costs nothing.

## 2.4 (Optional) restrict the femtocell's egress

Sprint's network is gone, so the femtocell only needs to reach:

- OPNsense: DNS (53), DHCP, and NTP (123) if you run the OPNsense NTP service
- The VM: UDP 500 and 4500 (IKE/IPsec)

Add rules on LAN with source `sprint_femtocell`: pass to `This Firewall` on 53/123, pass
to the VM on UDP 500/4500, then block everything else from `sprint_femtocell` and log it. The block log
is useful later because it shows what else the device tries to reach (see
[discovery](03-femto-discovery.md)). Same-subnet traffic from the femtocell to the VM
doesn't pass through OPNsense, so these rules only affect traffic leaving the LAN.

## 2.5 Verify

From the VM, or any LAN client that uses OPNsense for DNS:

```bash
dig @192.168.1.1 segw.femto.sprint.net +short        # -> 192.168.1.50
dig @192.168.1.1 segw-backup.femto.sprint.net +short # -> 192.168.1.50 (any label works)
dig @192.168.1.1 femto.sprint.net +short             # -> 192.168.1.50
dig @192.168.1.1 example.com +short                  # normal answer, so upstream still works
```

Test the redirect from any LAN host the redirect covers. With a network-wide redirect that
means any host. With a femtocell-only rule, the test host has to be added to
`sprint_femtocell` temporarily:

```bash
dig @8.8.8.8 segw.femto.sprint.net +short            # -> 192.168.1.50 if the redirect works
dig +tcp @8.8.8.8 segw.femto.sprint.net +short       # same over TCP
```

To see the names the femtocell **actually** queries, which helps when they differ from
the docs:

- **Interfaces > Diagnostics > Packet Capture**: interface LAN, host `192.168.1.201`,
  port 53. Then power-cycle the femtocell.
- Or turn on query logging in the dnscrypt-proxy plugin and check its log.

Record the names you see in [findings](findings.md).

Next: [femtocell discovery](03-femto-discovery.md).
