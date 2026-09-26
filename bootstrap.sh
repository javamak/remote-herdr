#!/usr/bin/env bash
#
# bootstrap.sh — run from your LOCAL machine.
# Copies this repo to a VPS over SSH and runs setup.sh there.
#
#   ./bootstrap.sh vps1                 # full setup
#   ./bootstrap.sh vps1 install         # just one phase
#   ./bootstrap.sh vps1 harden install services ttyd verify
#
# Configuration is passed through as env vars, e.g.:
#   TTYD_PORT=8080 SSH_ALLOW_USERS=ubuntu ./bootstrap.sh vps1
#   TTYD_CREDENTIAL='me:s3cret' ./bootstrap.sh vps1 ttyd
#
# TUNNEL_TOKEN and TTYD_CREDENTIAL are NOT forwarded (they would leak into the
# process list); set them on the VPS and run `./setup.sh cloudflared` / `ttyd`
# there, e.g.  printf '%s' 'user:pass' | (read -r C; TTYD_CREDENTIAL="$C" ./setup.sh ttyd)

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

HOST="${1:-}"
if [ -z "$HOST" ]; then
  echo "usage: $0 <ssh-host> [phase ...]" >&2
  echo "       e.g. $0 vps1" >&2
  exit 1
fi
shift || true
PHASES=("$@")
[ "${#PHASES[@]}" -gt 0 ] || PHASES=(all)

REMOTE_DIR="${REMOTE_DIR:-remote-herdr}"

echo "==> Copying to ${HOST}:${REMOTE_DIR}"
rsync -az --delete \
  --exclude '.git' \
  --exclude 'secrets/' \
  --exclude '.env' \
  --exclude '*.secret' \
  -e ssh \
  "${SCRIPT_DIR}/" "${HOST}:${REMOTE_DIR}/"

# Forward a whitelist of configuration variables.
ENV_PAIRS=()
for var in TARGET_USER TTYD_PORT SSH_ALLOW_USERS NODE_MAJOR \
           ALLOW_OPENSSH TUNNEL_HOSTNAME TUNNEL_CONFIG; do
  if [ -n "${!var:-}" ]; then
    ENV_PAIRS+=("${var}=${!var}")
  fi
done

ENV_PREFIX=""
if [ "${#ENV_PAIRS[@]}" -gt 0 ]; then
  ENV_PREFIX="env $(printf '%q ' "${ENV_PAIRS[@]}")"
fi

for phase in "${PHASES[@]}"; do
  echo "==> Running: setup.sh ${phase}"
  # shellcheck disable=SC2029
  ssh "$HOST" "cd ${REMOTE_DIR} && ${ENV_PREFIX}bash setup.sh ${phase}"
done

echo "==> Done."
