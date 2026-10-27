#!/usr/bin/env bash
# Start the shared 1xBTS core without an SDR, in the required order:
#   A: cdma-hlr + cdma-smsc + cdma-events   (wait until HLR is listening)
#   B: cdma-pdsn + cdma-msc
#
# Env:
#   ONEXBTS_DIR          1xBTS checkout (default: ~/1xbts)
#   HLR_READY_PATTERN    extended regex marking HLR/SMSC readiness in the log
#                        (default: 'gRPC.*listen|listen.*gRPC', case-insensitive)
#   READY_TIMEOUT        seconds to wait for readiness (default: 90)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ONEXBTS_DIR="${ONEXBTS_DIR:-$HOME/1xbts}"
HLR_READY_PATTERN="${HLR_READY_PATTERN:-gRPC.*listen|listen.*gRPC}"
READY_TIMEOUT="${READY_TIMEOUT:-90}"
LOG_DIR="$REPO_DIR/logs"
RUN_DIR="$REPO_DIR/run"
BIN="$ONEXBTS_DIR/target/release/cdma-nib"

die() { echo "error: $*" >&2; exit 1; }

[[ -x "$BIN" ]] || die "$BIN not found; build with: cargo build --release -p cdma-nib --no-default-features"

# Logs can contain IMSI/MEID; keep them private.
mkdir -p "$LOG_DIR" "$RUN_DIR"
chmod 700 "$LOG_DIR" "$RUN_DIR"

running() { [[ -f "$1" ]] && kill -0 "$(cat "$1")" 2>/dev/null; }
running "$RUN_DIR/core-a.pid" && die "core A already running (pid $(cat "$RUN_DIR/core-a.pid")); run stop-core.sh first"
running "$RUN_DIR/core-b.pid" && die "core B already running (pid $(cat "$RUN_DIR/core-b.pid")); run stop-core.sh first"

cd "$ONEXBTS_DIR"

pg_id="$(docker compose ps -q postgres 2>/dev/null || true)"
[[ -n "$pg_id" ]] || die "postgres container not running (docker compose --profile femto up -d)"
health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$pg_id")"
[[ "$health" == healthy ]] || die "postgres is '$health', wait for healthy"

caps="$(getcap "$BIN" 2>/dev/null || true)"
if [[ "$caps" != *cap_net_raw* || "$caps" != *cap_net_bind_service* ]]; then
  echo "warning: cdma-nib lacks cap_net_raw,cap_net_bind_service; PDSN packet data will fail (see docs/05)" >&2
fi

start() { # name, components...
  local name="$1"; shift
  local args=(--config-dir config)
  for c in "$@"; do args+=(--component "$c"); done
  : >"$LOG_DIR/$name.log"
  nohup "$BIN" "${args[@]}" >>"$LOG_DIR/$name.log" 2>&1 &
  echo $! >"$RUN_DIR/$name.pid"
  echo "started $name (pid $!): $*"
}

start core-a cdma-hlr cdma-smsc cdma-events

echo "waiting up to ${READY_TIMEOUT}s for HLR readiness ($HLR_READY_PATTERN)"
for ((i = 0; i < READY_TIMEOUT; i++)); do
  running "$RUN_DIR/core-a.pid" || die "core A exited; see $LOG_DIR/core-a.log"
  grep -Eiq "$HLR_READY_PATTERN" "$LOG_DIR/core-a.log" && break
  sleep 1
done
((i < READY_TIMEOUT)) || die "HLR not ready after ${READY_TIMEOUT}s; check $LOG_DIR/core-a.log or set HLR_READY_PATTERN"

start core-b cdma-pdsn cdma-msc

sleep 3
running "$RUN_DIR/core-b.pid" || die "core B exited; see $LOG_DIR/core-b.log"
if grep -Eiq 'MEID.*IMSI.*disabled' "$LOG_DIR/core-b.log"; then
  echo "warning: PDSN disabled MEID-to-IMSI lookup (HLR unreachable); run stop-core.sh and start again" >&2
fi
echo "core running; logs in $LOG_DIR"
