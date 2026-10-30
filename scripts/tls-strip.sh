#!/usr/bin/env bash
# Run the handset TLS-stripping proxy (docs/06-tls-strip.md). Run in the VM.
#
#   scripts/tls-strip.sh up       build and (re)create the proxy containers in fou-nat's netns
#   scripts/tls-strip.sh down     stop them and remove their iptables rules
#   scripts/tls-strip.sh status   containers, rules and listeners; exits 1 if anything is off
#
# Rerun `up` after fou-nat restarts or is recreated, and after a VM reboot: the
# proxy containers stay attached to fou-nat's old network namespace until they
# are re-created.
#
# SECURITY-REVIEW: drives docker and iptables inside fou-nat; config values are
# parsed as data (never sourced) and validated again inside the containers.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_FILE="$REPO_DIR/docker/tls-strip/compose.yml"
CONFIG="$REPO_DIR/config/tls-strip.local.env"
FOU_NAT=1xbts-fou-nat
SIDECARS=(1xbts-tls-strip-web 1xbts-tls-strip-mail 1xbts-tls-strip-rules)
GATEWAY_IP=10.55.0.1
WEB_PORT=8080

die() { echo "error: $*" >&2; exit 1; }
usage() { sed -n '2,6p' "$0" >&2; exit 2; }
compose() { docker compose -f "$COMPOSE_FILE" "$@"; }

fou_nat_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$FOU_NAT" 2>/dev/null)" == true ]]
}

config_value() { # key -> value from $CONFIG, empty if unset
  [[ -f "$CONFIG" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*$1=(.*)$ ]] && { printf '%s' "${BASH_REMATCH[1]}"; return 0; }
  done <"$CONFIG"
}

mail_ports() {
  local entry upstreams
  local -a entries
  upstreams="$(config_value MAIL_UPSTREAMS)"
  IFS=',' read -ra entries <<<"$upstreams"
  for entry in "${entries[@]}"; do
    [[ "${entry%%=*}" =~ ^[1-9][0-9]{0,4}$ ]] && echo "${entry%%=*}"
  done
}

started_epoch() {
  date -d "$(docker inspect -f '{{.State.StartedAt}}' "$1" 2>/dev/null)" +%s 2>/dev/null || echo 0
}

listening() { # port: bound on the gateway in fou-nat's current namespace
  docker exec "$FOU_NAT" ss -Hltn "sport = :$1" 2>/dev/null | grep -q "$GATEWAY_IP:$1 "
}

remove_rules_in_fou_nat() {
  docker exec -i "$FOU_NAT" sh -s <<'EOF'
while iptables -t nat -D PREROUTING -i fou0 -s 10.55.0.0/24 -j TLS_STRIP_PRE 2>/dev/null; do :; done
iptables -t nat -F TLS_STRIP_PRE 2>/dev/null || true
iptables -t nat -X TLS_STRIP_PRE 2>/dev/null || true
while iptables -D INPUT -d 10.55.0.1 -p tcp -j TLS_STRIP_IN 2>/dev/null; do :; done
iptables -F TLS_STRIP_IN 2>/dev/null || true
iptables -X TLS_STRIP_IN 2>/dev/null || true
EOF
}

cmd_up() {
  fou_nat_running || die "$FOU_NAT is not running (cd ~/1xbts && docker compose up -d fou-nat)"
  [[ -f "$CONFIG" ]] || echo "note: $CONFIG not found; starting the web proxy with no mail listeners"
  compose up -d --build --force-recreate --wait --wait-timeout 120
  cmd_status
}

cmd_down() {
  compose down --timeout 15
  # The rules container removes its rules on SIGTERM; this catches rules left
  # behind if it was killed instead.
  if fou_nat_running; then remove_rules_in_fou_nat; fi
  echo "tls-strip: stopped"
}

cmd_status() {
  local problems=0 fou_started name port
  compose ps --format 'table {{.Name}}\t{{.Status}}'

  fou_nat_running || { echo "FAIL $FOU_NAT is not running"; return 1; }
  fou_started="$(started_epoch "$FOU_NAT")"
  for name in "${SIDECARS[@]}"; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" != true ]]; then
      echo "FAIL $name is not running"; problems=1
    elif (( $(started_epoch "$name") < fou_started )); then
      echo "FAIL $name started before $FOU_NAT; it is on a stale network namespace (run: $0 up)"
      problems=1
    fi
  done

  if docker exec "$FOU_NAT" iptables -t nat -C PREROUTING -i fou0 -s 10.55.0.0/24 -j TLS_STRIP_PRE 2>/dev/null; then
    echo "ok   handset tcp/80 redirected to $GATEWAY_IP:$WEB_PORT"
  else
    echo "FAIL redirect rule missing in $FOU_NAT"; problems=1
  fi
  if docker exec "$FOU_NAT" iptables -C INPUT -d "$GATEWAY_IP" -p tcp -j TLS_STRIP_IN 2>/dev/null; then
    echo "ok   listener guard installed"
  else
    echo "FAIL listener guard missing in $FOU_NAT"; problems=1
  fi

  for port in "$WEB_PORT" $(mail_ports); do
    if listening "$port"; then
      echo "ok   listening on $GATEWAY_IP:$port"
    else
      echo "FAIL nothing listening on $GATEWAY_IP:$port"; problems=1
    fi
  done
  return "$problems"
}

[[ $# -eq 1 ]] || usage
command -v docker >/dev/null || die "docker not found; run this in the VM"
case "$1" in
  up) cmd_up ;;
  down) cmd_down ;;
  status) cmd_status ;;
  *) usage ;;
esac
