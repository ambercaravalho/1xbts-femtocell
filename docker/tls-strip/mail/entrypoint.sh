#!/bin/sh
# Plaintext mail listeners on the handset gateway, each upgraded to TLS upstream.
#
#   MAIL_UPSTREAMS=LISTEN_PORT=HOST:PORT[/imap|pop3|smtp],...
#
# No suffix: the upstream port speaks implicit TLS (993, 995, 465).
# A suffix: the upstream port is plaintext plus STARTTLS (143, 110, 587), and
# stunnel negotiates STARTTLS before splicing the handset's session through.
# Upstream certificates are always verified against the system CA bundle.
set -eu

LISTEN_ADDR="${LISTEN_ADDR:-10.55.0.1}"
MAIL_UPSTREAMS="${MAIL_UPSTREAMS:-}"
CA_FILE=/etc/ssl/certs/ca-certificates.crt
CONF_DIR=/run/stunnel
CONF="$CONF_DIR/stunnel.conf"
# Already taken on the fou-nat gateway (DNS, nginx, HDTP, web proxy, Kannel, FOU relay).
RESERVED_PORTS=" 53 80 1905 8080 9200 9201 13000 13002 17010 17011 17012 "

die() { echo "tls-strip-mail: $*" >&2; exit 1; }

idle() {
  trap 'exit 0' INT TERM
  while :; do sleep 3600 & wait $!; done
}

is_port() {
  case "$1" in '' | 0* | *[!0-9]*) return 1 ;; esac
  [ "${#1}" -le 5 ] && [ "$1" -le 65535 ]
}

is_host() {
  printf '%s' "$1" | grep -Eq '^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$'
}

if [ -z "$MAIL_UPSTREAMS" ]; then
  echo "tls-strip-mail: MAIL_UPSTREAMS is empty, no mail listeners"
  idle
fi

mkdir -p "$CONF_DIR"
cat >"$CONF" <<EOF
foreground = yes
pid =
syslog = no
debug = notice
setuid = stunnel
setgid = stunnel
EOF

seen=" "
for entry in $(printf '%s\n' "$MAIL_UPSTREAMS" | tr ',' ' '); do
  listen="${entry%%=*}"
  target="${entry#*=}"
  [ "$listen" != "$entry" ] || die "entry '$entry' is not LISTEN_PORT=HOST:PORT[/proto]"

  proto=""
  case "$target" in
    */*) proto="${target##*/}"; target="${target%/*}" ;;
  esac
  host="${target%:*}"
  port="${target##*:}"
  [ "$host" != "$target" ] || die "entry '$entry' has no upstream port"

  is_port "$listen" || die "bad listen port in '$entry'"
  is_port "$port" || die "bad upstream port in '$entry'"
  is_host "$host" || die "bad upstream host in '$entry'"
  case "$proto" in '' | imap | pop3 | smtp) ;; *) die "bad protocol in '$entry' (imap, pop3 or smtp)" ;; esac
  case "$RESERVED_PORTS" in *" $listen "*) die "listen port $listen is already used on the gateway" ;; esac
  case "$seen" in *" $listen "*) die "listen port $listen is listed twice" ;; esac
  seen="$seen$listen "

  {
    echo ""
    echo "[mail-$listen]"
    echo "client = yes"
    echo "accept = $LISTEN_ADDR:$listen"
    echo "connect = $host:$port"
    echo "delay = yes"
    echo "sni = $host"
    echo "verifyChain = yes"
    echo "checkHost = $host"
    echo "CAfile = $CA_FILE"
    echo "sslVersionMin = TLSv1.2"
    [ -z "$proto" ] || echo "protocol = $proto"
  } >>"$CONF"
  mode="implicit TLS"
  [ -z "$proto" ] || mode="STARTTLS $proto"
  echo "tls-strip-mail: $LISTEN_ADDR:$listen -> $host:$port ($mode)"
done

exec stunnel "$CONF"
