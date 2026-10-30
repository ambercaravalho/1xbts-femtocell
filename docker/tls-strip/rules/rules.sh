#!/bin/sh
# Install the handset redirect and the listener guard in fou-nat's network
# namespace, hold them while the container runs, and remove them on stop.
#
#   nat    PREROUTING -i fou0 -s MOBILE_CIDR -> TLS_STRIP_PRE
#          TLS_STRIP_PRE: traffic to MOBILE_CIDR (gateway nginx, MMSC, speed.) is
#          left alone; other TCP 80 is redirected to the web proxy.
#   filter INPUT -d GATEWAY_IP -p tcp -> TLS_STRIP_IN
#          TLS_STRIP_IN: proxy and mail ports accept only handsets on fou0
#          (and loopback); anything else is dropped.
set -eu

MOBILE_CIDR="${MOBILE_CIDR:-10.55.0.0/24}"
GATEWAY_IP="${GATEWAY_IP:-10.55.0.1}"
WEB_PORT="${WEB_PORT:-8080}"
MAIL_UPSTREAMS="${MAIL_UPSTREAMS:-}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"

PRE_JUMP="-i fou0 -s $MOBILE_CIDR -j TLS_STRIP_PRE"
IN_JUMP="-d $GATEWAY_IP -p tcp -j TLS_STRIP_IN"

die() { echo "tls-strip-rules: $*" >&2; exit 1; }

[ -e /sys/class/net/fou0 ] || die "no fou0 here; this container must share fou-nat's network namespace"

guarded_ports="$WEB_PORT"
for entry in $(printf '%s\n' "$MAIL_UPSTREAMS" | tr ',' ' '); do
  port="${entry%%=*}"
  case "$port" in '' | 0* | *[!0-9]*) die "bad listen port in MAIL_UPSTREAMS entry '$entry'" ;; esac
  guarded_ports="$guarded_ports $port"
done

remove_rules() {
  # shellcheck disable=SC2086
  while iptables -t nat -D PREROUTING $PRE_JUMP 2>/dev/null; do :; done
  iptables -t nat -F TLS_STRIP_PRE 2>/dev/null || true
  iptables -t nat -X TLS_STRIP_PRE 2>/dev/null || true
  # shellcheck disable=SC2086
  while iptables -D INPUT $IN_JUMP 2>/dev/null; do :; done
  iptables -F TLS_STRIP_IN 2>/dev/null || true
  iptables -X TLS_STRIP_IN 2>/dev/null || true
}

install_rules() {
  remove_rules
  iptables -t nat -N TLS_STRIP_PRE
  iptables -t nat -A TLS_STRIP_PRE -d "$MOBILE_CIDR" -j RETURN
  iptables -t nat -A TLS_STRIP_PRE -p tcp --dport 80 -j REDIRECT --to-ports "$WEB_PORT"
  # shellcheck disable=SC2086
  iptables -t nat -A PREROUTING $PRE_JUMP

  iptables -N TLS_STRIP_IN
  iptables -A TLS_STRIP_IN -i lo -j RETURN
  iptables -A TLS_STRIP_IN -i fou0 -s "$MOBILE_CIDR" -j RETURN
  for port in $guarded_ports; do
    iptables -A TLS_STRIP_IN -p tcp --dport "$port" -j DROP
  done
  # shellcheck disable=SC2086
  iptables -A INPUT $IN_JUMP
  echo "tls-strip-rules: fou0 tcp/80 -> $GATEWAY_IP:$WEB_PORT; guarded ports: $guarded_ports"
}

# shellcheck disable=SC2086
rules_present() {
  iptables -t nat -C PREROUTING $PRE_JUMP 2>/dev/null && iptables -C INPUT $IN_JUMP 2>/dev/null
}

trap 'remove_rules; echo "tls-strip-rules: removed"; exit 0' INT TERM

install_rules
while :; do
  sleep "$CHECK_INTERVAL" &
  wait $!
  rules_present || { echo "tls-strip-rules: rules missing, reinstalling"; install_rules; }
done
