#!/usr/bin/env bash
# Read-only checks for the 1xBTS femtocell VM. Changes nothing.
#
# Usage: VM_IP=192.168.1.50 DNS_SERVER=192.168.1.1 scripts/preflight.sh
#   ONEXBTS_DIR   1xBTS checkout (default: ~/1xbts)
#   VM_IP         address the femtocell should reach the SeGW on (default: 192.168.1.50)
#   DNS_SERVER    LAN resolver the femtocell uses, i.e. OPNsense (default: default gateway)
set -uo pipefail

ONEXBTS_DIR="${ONEXBTS_DIR:-$HOME/1xbts}"
VM_IP="${VM_IP:-192.168.1.50}"
DNS_SERVER="${DNS_SERVER:-$(ip -4 route show default 2>/dev/null | awk '{print $3; exit}')}"

fails=0
warns=0
pass() { printf '  [PASS] %s\n' "$*"; }
warn() { printf '  [WARN] %s\n' "$*"; warns=$((warns + 1)); }
fail() { printf '  [FAIL] %s\n' "$*"; fails=$((fails + 1)); }
have() { command -v "$1" >/dev/null 2>&1; }

echo "Host"
arch="$(uname -m)"
if [[ "$arch" == "aarch64" ]]; then pass "architecture $arch"; else warn "architecture $arch (expected aarch64 on a Mac mini M4 guest)"; fi

if have timedatectl && timedatectl show -p NTPSynchronized --value 2>/dev/null | grep -qx yes; then
  pass "clock synchronized"
else
  warn "clock not reported as NTP-synchronized"
fi

echo "Kernel modules"
for m in fou ipip; do
  if lsmod | awk '{print $1}' | grep -qx "$m"; then
    pass "$m loaded"
  elif modinfo "$m" >/dev/null 2>&1; then
    fail "$m available but not loaded (sudo modprobe $m)"
  else
    fail "$m not available (install linux-modules-extra-$(uname -r))"
  fi
done
[[ -f /etc/modules-load.d/1xbts.conf ]] && pass "modules persisted in /etc/modules-load.d/1xbts.conf" \
  || warn "fou/ipip not persisted in /etc/modules-load.d/"

echo "Network"
if ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -qx "$VM_IP"; then
  pass "VM has $VM_IP"
else
  fail "VM does not have $VM_IP (bridged adapter? static IP?)"
fi
if [[ -n "$DNS_SERVER" ]]; then pass "DNS server under test: $DNS_SERVER"; else fail "no default gateway / DNS_SERVER"; fi

echo "Bootstrap DNS (via $DNS_SERVER)"
if have dig && [[ -n "$DNS_SERVER" ]]; then
  for name in segw.femto.sprint.net "preflight-$RANDOM.femto.sprint.net"; do
    got="$(dig +short +time=2 +tries=1 @"$DNS_SERVER" "$name" A | tail -n1)"
    if [[ "$got" == "$VM_IP" ]]; then pass "$name -> $got"; else fail "$name -> '${got:-no answer}' (expected $VM_IP; check dnscrypt-proxy cloaking)"; fi
  done
  got="$(dig +short +time=2 +tries=1 @"$DNS_SERVER" example.com A | tail -n1)"
  [[ -n "$got" ]] && pass "upstream resolution works (example.com)" || warn "example.com did not resolve via $DNS_SERVER"
else
  fail "dig not installed (apt install dnsutils)"
fi

echo "Docker"
if have docker; then
  if docker info >/dev/null 2>&1; then pass "docker daemon reachable"; else fail "cannot talk to docker (in docker group? re-login?)"; fi
  if docker compose version >/dev/null 2>&1; then pass "docker compose plugin present"; else fail "docker compose plugin missing"; fi
else
  fail "docker not installed"
fi

echo "1xBTS checkout ($ONEXBTS_DIR)"
if [[ -d "$ONEXBTS_DIR" ]]; then
  pass "checkout present"
  for f in femto msc pdsn; do
    path="$ONEXBTS_DIR/config/$f.local.json"
    if [[ ! -f "$path" ]]; then
      [[ "$f" == pdsn ]] && warn "$f.local.json missing (only needed for packet data)" || fail "$f.local.json missing"
      continue
    fi
    if have jq && ! jq empty "$path" >/dev/null 2>&1; then fail "$f.local.json is not valid JSON"; fi
    n="$(grep -c '\${' "$path" || true)"
    [[ "$n" -eq 0 ]] && pass "$f.local.json has no placeholders" || fail "$f.local.json still has $n \${...} placeholder line(s)"
    mode="$(stat -c '%a' "$path")"
    [[ "$mode" == 600 || "$mode" == 400 ]] && pass "$f.local.json mode $mode" || warn "$f.local.json mode $mode (chmod 600)"
  done
  bin="$ONEXBTS_DIR/target/release/cdma-nib"
  if [[ -x "$bin" ]]; then
    pass "cdma-nib built"
    caps="$(getcap "$bin" 2>/dev/null)"
    if [[ "$caps" == *cap_net_raw* && "$caps" == *cap_net_bind_service* ]]; then
      pass "cdma-nib has cap_net_raw,cap_net_bind_service"
    else
      warn "cdma-nib lacks PDSN capabilities (needed for packet data; see docs/05)"
    fi
  else
    warn "cdma-nib not built yet"
  fi
else
  warn "no checkout at $ONEXBTS_DIR (set ONEXBTS_DIR)"
fi

echo "Listening (only after the femto stack is up)"
for p in 500 4500; do
  if ss -Hlun "sport = :$p" 2>/dev/null | grep -q .; then pass "UDP $p listening"; else warn "nothing listening on UDP $p yet"; fi
done
if ss -Hltn 'sport = :3000' 2>/dev/null | grep -q .; then pass "dashboard on TCP 3000"; else warn "dashboard not listening on TCP 3000 yet"; fi

echo
echo "Summary: $fails fail, $warns warn"
[[ "$fails" -eq 0 ]]
