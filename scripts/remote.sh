#!/usr/bin/env bash
# Run commands on the Mac mini VirtualBox host using the SSH credentials in .env.
#
#   scripts/remote.sh '<command>'            run a command
#   scripts/remote.sh --sudo '<command>'     run it as root via sudo -S (password on stdin)
#   scripts/remote.sh --copy <src> <dest>    scp a local file to the host (dest is remote path)
#
# .env (gitignored): SERVER_SSH_HOST, SERVER_SSH_PORT, SERVER_SSH_USER, SERVER_SSH_PASSWORD
# The password is passed to sshpass through the SSHPASS env var, never on a command line.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$REPO_DIR/.env}"

[[ -f "$ENV_FILE" ]] || { echo "error: $ENV_FILE not found (see .env.example)" >&2; exit 1; }
command -v sshpass >/dev/null || { echo "error: sshpass not installed (brew install sshpass)" >&2; exit 1; }

# Parse KEY=VALUE lines instead of sourcing, so values are never executed.
while IFS= read -r line || [[ -n "$line" ]]; do
  [[ "$line" =~ ^[[:space:]]*(SERVER_SSH_[A-Z]+)=(.*)$ ]] || continue
  key="${BASH_REMATCH[1]}"
  val="${BASH_REMATCH[2]}"
  val="${val%$'\r'}"
  if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val="${BASH_REMATCH[1]}"; fi
  printf -v "$key" '%s' "$val"
done <"$ENV_FILE"

: "${SERVER_SSH_HOST:?missing in .env}" "${SERVER_SSH_USER:?missing in .env}" "${SERVER_SSH_PASSWORD:?missing in .env}"
SERVER_SSH_PORT="${SERVER_SSH_PORT:-22}"
export SSHPASS="$SERVER_SSH_PASSWORD"

# Reuse one authenticated connection; many rapid password logins get temporarily rejected by macOS.
ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=30
  -o PubkeyAuthentication=no -o PreferredAuthentications=password,keyboard-interactive
  -o ControlMaster=auto -o "ControlPath=$HOME/.ssh/cm-1xbts-%C" -o ControlPersist=15m)

usage() { sed -n '2,8p' "$0" >&2; exit 2; }

case "${1:-}" in
  --sudo)
    [[ $# -eq 2 ]] || usage
    # SECURITY-REVIEW: privileged remote execution; password goes only to sudo's stdin.
    printf '%s\n' "$SERVER_SSH_PASSWORD" |
      sshpass -e ssh "${ssh_opts[@]}" -p "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_SSH_HOST" \
        "sudo -S -p '' -- /bin/sh -c $(printf '%q' "$2")"
    ;;
  --copy)
    [[ $# -eq 3 ]] || usage
    sshpass -e scp "${ssh_opts[@]}" -P "$SERVER_SSH_PORT" "$2" "$SERVER_SSH_USER@$SERVER_SSH_HOST:$3"
    ;;
  ""|-h|--help) usage ;;
  *)
    [[ $# -eq 1 ]] || usage
    sshpass -e ssh "${ssh_opts[@]}" -p "$SERVER_SSH_PORT" "$SERVER_SSH_USER@$SERVER_SSH_HOST" "$1"
    ;;
esac
