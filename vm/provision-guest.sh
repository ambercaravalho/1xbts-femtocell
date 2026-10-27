#!/usr/bin/env bash
# Provision the 1xbts guest (docs/01-vm-setup.md steps 1.4-1.7). Run inside the VM as the
# sudo-capable user; safe to re-run.
#   ssh bts@192.168.1.50 'bash -s' < vm/provision-guest.sh
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages"
sudo apt-get update -q
sudo apt-get -yq full-upgrade
sudo apt-get -yq install build-essential pkg-config libssl-dev protobuf-compiler clang \
  git curl ca-certificates jq dnsutils iproute2 tcpdump chrony rsync
sudo systemctl enable --now chrony

echo "==> kernel modules fou, ipip"
# SECURITY-REVIEW: loads kernel modules and writes /etc/modules-load.d as root.
if ! sudo modprobe fou || ! sudo modprobe ipip; then
  sudo apt-get -yq install "linux-modules-extra-$(uname -r)" linux-image-generic
  sudo modprobe fou
  sudo modprobe ipip
fi
printf 'fou\nipip\n' | sudo tee /etc/modules-load.d/1xbts.conf >/dev/null

echo "==> Docker Engine + compose plugin"
if ! command -v docker >/dev/null; then
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $codename stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -q
  sudo apt-get -yq install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
sudo usermod -aG docker "$USER"

echo "==> Rust"
if [[ ! -x "$HOME/.cargo/bin/rustc" ]]; then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal
fi
"$HOME/.cargo/bin/rustc" -vV | grep host

echo "==> done"
lsmod | grep -E '^(fou|ipip) '
docker --version
sudo docker compose version
[[ -f /var/run/reboot-required ]] && echo "NOTE: reboot required (kernel/libc update)"
true
