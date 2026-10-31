#!/usr/bin/env bash
# Create the 1xbts Ubuntu 24.04 ARM64 VM on the Mac mini VirtualBox host from this machine.
# Uses scripts/remote.sh (SSH credentials in .env), the Ubuntu cloud image, and a cloud-init
# NoCloud seed ISO rendered from vm/cloud-init/. No interactive installer.
#
# Override any of these via env:
VM_NAME="${VM_NAME:-1xbts}"
VM_USER="${VM_USER:-bts}"
VM_IP="${VM_IP:-192.168.1.102}"
VM_PREFIX="${VM_PREFIX:-24}"
VM_GATEWAY="${VM_GATEWAY:-192.168.1.1}"
VM_DNS="${VM_DNS:-192.168.1.1}"
VM_MAC="${VM_MAC:-0800271B7550}"          # VirtualBox format, no separators
VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY_MB="${VM_MEMORY_MB:-8192}"
VM_DISK_MB="${VM_DISK_MB:-65536}"
VM_BRIDGE="${VM_BRIDGE:-en0: Ethernet}"   # full name from `VBoxManage list bridgedifs`
VM_NICTYPE="${VM_NICTYPE:-virtio}"        # fall back to 82540EM if the guest sees no NIC
VM_BASE_DIR="${VM_BASE_DIR:-/Volumes/ssd_array/virtualbox_machines}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-$HOME/.ssh/id_ed25519.pub}"
IMAGE_URL_DIR="${IMAGE_URL_DIR:-https://cloud-images.ubuntu.com/noble/current}"
IMAGE_NAME="${IMAGE_NAME:-noble-server-cloudimg-arm64.img}"
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REMOTE="$REPO_DIR/scripts/remote.sh"
VM_DIR="$VM_BASE_DIR/$VM_NAME"

[[ -f "$SSH_PUBKEY_FILE" ]] || { echo "error: $SSH_PUBKEY_FILE not found" >&2; exit 1; }
[[ "$VM_MAC" =~ ^[0-9A-Fa-f]{12}$ ]] || { echo "error: VM_MAC must be 12 hex digits" >&2; exit 1; }
pubkey="$(head -n1 "$SSH_PUBKEY_FILE")"
mac_colon="$(echo "$VM_MAC" | tr 'A-F' 'a-f' | sed -E 's/(..)(..)(..)(..)(..)(..)/\1:\2:\3:\4:\5:\6/')"

render_dir="$(mktemp -d)"
trap 'rm -rf "$render_dir"' EXIT
for f in user-data meta-data network-config; do
  sed -e "s|__VM_HOSTNAME__|$VM_NAME|g" -e "s|__VM_USER__|$VM_USER|g" \
      -e "s|__SSH_PUBKEY__|$pubkey|g" -e "s|__VM_MAC_COLON__|$mac_colon|g" \
      -e "s|__VM_IP__|$VM_IP|g" -e "s|__VM_PREFIX__|$VM_PREFIX|g" \
      -e "s|__VM_GATEWAY__|$VM_GATEWAY|g" -e "s|__VM_DNS__|$VM_DNS|g" \
      "$REPO_DIR/vm/cloud-init/$f" >"$render_dir/$f"
done
if grep -q '__[A-Z_]*__' "$render_dir"/*; then echo "error: unrendered placeholders" >&2; exit 1; fi

echo "==> preparing $VM_DIR on host"
"$REMOTE" "export PATH=/usr/local/bin:\$PATH
if VBoxManage list vms | grep -q '^\"$VM_NAME\" '; then echo 'error: VM $VM_NAME already exists' >&2; exit 1; fi
mkdir -p '$VM_DIR/seed'"

for f in user-data meta-data network-config; do
  "$REMOTE" --copy "$render_dir/$f" "$VM_DIR/seed/$f"
done

host_script="$(cat <<EOF
set -euo pipefail
export PATH=/opt/homebrew/bin:/usr/local/bin:\$PATH
cd '$VM_DIR'

echo '==> downloading and verifying $IMAGE_NAME'
if [[ ! -f '$IMAGE_NAME' ]]; then
  curl -fsSL -o '$IMAGE_NAME.part' '$IMAGE_URL_DIR/$IMAGE_NAME'
  mv '$IMAGE_NAME.part' '$IMAGE_NAME'
fi
curl -fsSL -o SHA256SUMS '$IMAGE_URL_DIR/SHA256SUMS'
awk -v n='$IMAGE_NAME' '\$2 == n || \$2 == "*" n { print \$1 "  " n }' SHA256SUMS | shasum -a 256 -c -

echo '==> converting to VDI and resizing to $VM_DISK_MB MB'
rm -f '$VM_NAME.vdi'
qemu-img convert -f qcow2 -O vdi '$IMAGE_NAME' '$VM_NAME.vdi'
VBoxManage modifymedium disk '$VM_DIR/$VM_NAME.vdi' --resize $VM_DISK_MB

echo '==> building seed.iso (cidata)'
rm -f seed.iso
hdiutil makehybrid -quiet -o seed.iso -iso -joliet -iso-volume-name cidata -joliet-volume-name cidata -default-volume-name cidata seed

echo '==> creating VM'
VBoxManage createvm --name '$VM_NAME' --platform-architecture arm --ostype Ubuntu24_LTS_arm64 --basefolder '$VM_BASE_DIR' --register
VBoxManage modifyvm '$VM_NAME' --cpus $VM_CPUS --memory $VM_MEMORY_MB --firmware efi \\
  --chipset armv8virtual --graphicscontroller qemuramfb --audio-enabled off --usb-xhci on \\
  --nic1 bridged --bridge-adapter1 '$VM_BRIDGE' --nic-type1 $VM_NICTYPE \\
  --nic-promisc1 allow-all --mac-address1 $VM_MAC
VBoxManage modifyvm '$VM_NAME' --uart1 0x3F8 4 --uart-mode1 file '$VM_DIR/console.log' || echo 'note: serial console logging not supported, skipping'
VBoxManage storagectl '$VM_NAME' --name VirtioSCSI --add virtio --controller VirtIO --portcount 4 --bootable on
VBoxManage storageattach '$VM_NAME' --storagectl VirtioSCSI --port 0 --device 0 --type hdd --medium '$VM_DIR/$VM_NAME.vdi'
VBoxManage storageattach '$VM_NAME' --storagectl VirtioSCSI --port 1 --device 0 --type dvddrive --medium '$VM_DIR/seed.iso'

echo '==> starting headless'
VBoxManage startvm '$VM_NAME' --type headless
EOF
)"

# Pass the script base64-encoded so the remote login shell (zsh) doesn't reinterpret it.
"$REMOTE" "echo $(printf '%s' "$host_script" | base64 | tr -d '\n') | base64 -D | /bin/bash"

echo "==> VM started. Wait for SSH: ssh $VM_USER@$VM_IP"
