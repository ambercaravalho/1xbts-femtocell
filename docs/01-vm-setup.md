# 1. VM setup (Mac mini M4 + VirtualBox)

Goal: an Ubuntu Server 24.04 **ARM64** VM with its own address on the LAN, Docker, a Rust
toolchain, and the `fou` and `ipip` kernel modules loaded.

Examples in this repo use these addresses. Substitute your own everywhere:

| Thing | Example |
| --- | --- |
| LAN subnet | `192.168.1.0/24` |
| OPNsense (gateway + DNS) | `192.168.1.1` |
| VM (1xBTS host / SeGW) | `192.168.1.50` |
| Femtocell | `192.168.1.201` (OPNsense alias `sprint_femtocell`) |

## Automated path (what this setup actually used)

Run everything from a workstation on the LAN. No installer, no VirtualBox GUI:

```bash
cp .env.example .env              # fill in the Mac mini's SSH host/user/password
brew install sshpass
vm/create-vm.sh                   # cloud image + cloud-init seed -> VM "1xbts" running headless
ssh bts@192.168.1.50 'bash -s' < vm/provision-guest.sh    # packages, Docker, Rust, fou/ipip
scripts/remote.sh 'VBoxManage storageattach 1xbts --storagectl VirtioSCSI --port 1 --device 0 --type dvddrive --medium emptydrive --forceunmount'
rsync -a --exclude .env --exclude secrets/ --exclude .git/ ./ bts@192.168.1.50:1xbts-femtocell/
ssh bts@192.168.1.50 1xbts-femtocell/scripts/preflight.sh
```

- [`scripts/remote.sh`](../scripts/remote.sh) runs commands on the Mac mini using `.env`
  (`--sudo` for root, `--copy` for scp). It keeps one multiplexed SSH connection open,
  because macOS briefly rejects password logins after several logins in a row.
- [`vm/create-vm.sh`](../vm/create-vm.sh) downloads and checksum-verifies
  `noble-server-cloudimg-arm64.img`, converts it to VDI (needs `qemu-img` on the host:
  `brew install qemu`), and resizes it to 64 GB. It renders
  [`vm/cloud-init/`](../vm/cloud-init/) into a `cidata` seed ISO with `hdiutil`, then
  creates the VM. Settings are environment overrides at the top of the script.
- The guest user is `bts`, with **SSH key only** (your `~/.ssh/id_ed25519.pub`) and
  passwordless sudo. The fixed MAC `08:00:27:1b:75:50` matches the static netplan config.
- [`vm/launchd/org.1xbts.vm-autostart.plist`](../vm/launchd/org.1xbts.vm-autostart.plist)
  starts the VM at login of the host user. See 1.2 for its auto-login caveat.

The manual steps below describe the same setup, for reference or for rebuilding by hand.

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
| Network > Adapter 1 | **Bridged Adapter**, name: the Mac's Ethernet interface. With VBoxManage, use the full name from `VBoxManage list bridgedifs`, e.g. `"en0: Ethernet"`. Plain `en0` leaves the NIC unattached |
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
Boot" in the VirtualBox manual). This setup uses a user LaunchAgent instead,
[`vm/launchd/org.1xbts.vm-autostart.plist`](../vm/launchd/org.1xbts.vm-autostart.plist).
It waits for the external VM volume to mount and starts the VM if it isn't already running.

**Caveat:** a LaunchAgent only runs once the host user logs in. Auto-login is off on this
Mac mini, so after a power loss the VM stays down until someone logs in, and the same goes
for the Home Assistant VM. To make it unattended, enable auto-login in **System Settings >
Users & Groups**. Auto-login isn't available when FileVault is on.

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

The Ubuntu 24.04 ARM64 cloud image kernel (`6.8.0-*-generic`) already includes both modules.
If `modprobe` says a module isn't found on another image, install the extra modules for the
running kernel and try again:

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
