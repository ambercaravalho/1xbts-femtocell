#!/usr/bin/env bash
# Stop the core started by start-core.sh, in reverse order (B, then A).
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_DIR="$REPO_DIR/run"
STOP_TIMEOUT="${STOP_TIMEOUT:-15}"

stop() {
  local pidfile="$RUN_DIR/$1.pid" pid
  [[ -f "$pidfile" ]] || { echo "$1 not running"; return 0; }
  pid="$(cat "$pidfile")"
  [[ "$pid" =~ ^[0-9]+$ ]] || { echo "$1: bad pid file, removing"; rm -f "$pidfile"; return 0; }
  # Only signal the process if it is still our cdma-nib, not a recycled pid.
  if kill -0 "$pid" 2>/dev/null && [[ "$(ps -o comm= -p "$pid")" == cdma-nib* ]]; then
    kill -TERM "$pid"
    for ((i = 0; i < STOP_TIMEOUT; i++)); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$pid" 2>/dev/null; then
      echo "$1 (pid $pid) did not exit after ${STOP_TIMEOUT}s, sending KILL"
      kill -KILL "$pid"
    fi
    echo "stopped $1 (pid $pid)"
  else
    echo "$1 not running"
  fi
  rm -f "$pidfile"
}

stop core-b
stop core-a
