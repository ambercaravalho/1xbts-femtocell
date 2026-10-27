# 1. VM setup (Mac mini M4 + VirtualBox)

Goal: an Ubuntu Server 24.04 **ARM64** VM with its own address on the LAN, Docker, a Rust
toolchain, and the `fou` and `ipip` kernel modules loaded.

Examples in this repo use these addresses. Substitute your own everywhere:

| Thing | Example |
| --- | --- |
| LAN subnet | `192.168.1.0/24` |
| OPNsense (gateway + DNS) | `192.168.1.1` |
| VM (1xBTS host / SeGW) | `192.168.1.50` |
| Femtocell | `192.168.1.60` |

## Why these choices

- **Apple Silicon only runs ARM64 guests.** VirtualBox 7.1+ supports Apple Silicon hosts,
  but it does not emulate x86. Use the `arm64` Ubuntu Server ISO. Anything that ships only
  `amd64` Docker images won't run. See [findings](findings.md).
- **Bridged networking, not NAT.** The femtocell has to reach the VM directly on UDP
  500/4500 (IKE/NAT-T), and the VM needs to route return traffic back to it.
  VirtualBox NAT hides the VM behind the Mac and breaks inbound IPsec and the host routes
  1xBTS installs.
- **Ethernet, not Wi-Fi.** Bridging over Wi-Fi rewrites MACs and is unreliable for this.

If VirtualBox bridging gives you trouble on macOS, [UTM](https://mac.getutm.app/) runs
the same ARM64 guest with bridged networking. Everything after the VM creation step
stays the same.

## 1.1 Mac host prep

1. Install VirtualBox 7.1 or newer, the **macOS / Apple Silicon** build.
2. Keep the Mac awake. A sleeping host means a dead cell:

   ```bash
   sudo pmset -a sleep 0 disksleep 0 displaysleep 10 womp 1 autorestart 1
   ```

3. If macOS asks whether VirtualBox may access devices on your local network, allow it.
   Bridged traffic can silently fail without that permission. Check
   **System Settings > Privacy & Security > Local Network**.

## 1.2 Create the VM

| Setting | Value |
| --- | --- |
| ISO | `ubuntu-24.04.x-live-server-arm64.iso` |
| CPUs | 4 (Rust builds are slow with fewer) |
| Memory | 8 GB |
| Disk | 64 GB, dynamically allocated (`target/` plus Docker images get large) |
| Network > Adapter 1 | **Bridged Adapter**, name: the Mac's Ethernet interface (usually `en0`) |
| Network > Advanced > Promiscuous Mode | **Allow All** |
| Network > Advanced > Adapter type | Virtio-net if offered, otherwise the default |

Write down the adapter's MAC address. You need it for an OPNsense static lease.

Install Ubuntu Server with OpenSSH enabled. Skip the optional snaps, including Docker
(the snap Docker build doesn't work well with Compose profiles and host networking).

### Optional: start the VM headless at boot

```bash
VBoxManage startvm "1xbts" --type headless
```

`VBoxManage modifyvm --autostart-enabled on` only takes effect on macOS once the VirtualBox
autostart launchd service is configured (see "Starting Virtual Machines During System
Boot" in the VirtualBox manual). A simpler option is a user LaunchAgent that runs the
`startvm` command above at login, with the Mac set to log in automatically.

## 1.3 Give the VM a fixed address

Either set an OPNsense static DHCP mapping for the VM's MAC
(**Services > ISC DHCPv4 / Kea > LAN > Static mappings**), or set it statically in netplan.
A DHCP reservation keeps all addressing in one place. A static netplan config keeps working
even if DHCP is down. Pick one approach.

Static netplan (`/etc/netplan/50-lan.yaml`; check the interface name with `ip -br link`):

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: false
      addresses: [192.168.1.50/24]
      routes:
        - to: default
          via: 192.168.1.1
      nameservers:
        addresses: [192.168.1.1]
```

```bash
sudo chmod 600 /etc/netplan/50-lan.yaml
sudo netplan apply
ip -br addr
```

Make sure `192.168.1.50` is outside the DHCP pool.

## 1.4 Base packages and time

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y build-essential pkg-config libssl-dev protobuf-compiler clang \
  git curl ca-certificates jq dnsutils iproute2 tcpdump chrony
timedatectl   # "System clock synchronized: yes"
```

The exact build dependencies for 1xBTS are listed on its
[Building from Source](https://1xbts.org/docs/) page. Treat the list above as a starting
point and record any missing package in [findings](findings.md).

## 1.5 Docker Engine + Compose plugin

Use Docker's apt repository, not the snap:

```bash
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt update
sudo apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker "$USER"   # log out and back in
docker compose version
```

## 1.6 Rust

```bash
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
. "$HOME/.cargo/env"
rustc -vV | grep host     # expect aarch64-unknown-linux-gnu
```

## 1.7 Kernel modules: `fou` and `ipip`

The femto stack uses foo-over-UDP and IP-in-IP tunnels between containers and the host.

```bash
sudo modprobe fou ipip && lsmod | grep -E '^(fou|ipip)'
```

If `modprobe` says the module isn't found, install the extra modules for the running kernel
and try again:

```bash
sudo apt install -y "linux-modules-extra-$(uname -r)"
```

Load them at boot:

```bash
printf 'fou\nipip\n' | sudo tee /etc/modules-load.d/1xbts.conf
```

## 1.8 Host firewall

Ubuntu Server ships with `ufw` inactive. If you enable it, allow:

```bash
sudo ufw allow 22/tcp
sudo ufw allow 500/udp      # IKE
sudo ufw allow 4500/udp     # IPsec NAT-T
sudo ufw allow 3000/tcp     # 1xBTS dashboard (LAN only; don't port-forward it)
# Docker bridge -> host core (gRPC/management). Adjust the bridge subnet if yours differs.
for p in 17017 17019 17020 17021 17023; do sudo ufw allow from 172.31.0.0/16 to any port "$p" proto tcp; done
```

Docker manages its own iptables chains and can bypass `ufw` for published ports. Don't
publish core ports on `0.0.0.0` and assume `ufw` protects them.

## 1.9 Check it

Run [`scripts/preflight.sh`](../scripts/preflight.sh) in the VM. It is read-only and checks
architecture, modules, addressing, Docker, and DNS.

Next: [OPNsense DNS](02-opnsense-dns.md).
