#!/usr/bin/env bash
# Generate packet-core secrets into secrets/packet.env (mode 600). Never prints them.
#   A11_SHARED_SECRET_HEX  -> pdsn.local.json a11_security.shared_secret_hex
#   A12_RADIUS_SECRET      -> pdsn.local.json a12.radius_secret and femto.local.json term_auth_psk
#
# Usage: scripts/gen-secrets.sh [--force]
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$REPO_DIR/secrets"
OUT="$OUT_DIR/packet.env"

force=0
case "${1:-}" in
  "") ;;
  --force) force=1 ;;
  *) echo "usage: $0 [--force]" >&2; exit 2 ;;
esac

command -v openssl >/dev/null || { echo "error: openssl not found" >&2; exit 1; }

if [[ -e "$OUT" && "$force" -ne 1 ]]; then
  echo "error: $OUT exists; rotating keys means updating pdsn/femto configs and re-syncing the femtocell. Use --force to overwrite." >&2
  exit 1
fi

umask 077
mkdir -p "$OUT_DIR"
chmod 700 "$OUT_DIR"

tmp="$(mktemp "$OUT_DIR/.packet.env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
  echo "A11_SHARED_SECRET_HEX=$(openssl rand -hex 16)"
  echo "A12_RADIUS_SECRET=$(openssl rand -hex 24)"
} >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$OUT"
trap - EXIT

echo "wrote $OUT (values not shown)"
