#!/usr/bin/env bash
# Unattended Ubuntu 24.04 host bootstrap for nord-exit-node.
# Requires: sudo, and TOKEN + TS_AUTHKEY in .env or the environment.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$STACK_DIR"

log() { printf '[bootstrap] %s\n' "$*" >&2; }

if [[ "$(uname -s)" != "Linux" ]]; then
  log "This script is for Ubuntu/Linux hosts. On macOS run ./up.sh instead."
  exit 1
fi

if [[ ! -f /etc/os-release ]] || ! grep -q 'ID=ubuntu' /etc/os-release; then
  log "Warning: not Ubuntu; continuing anyway."
fi

if [[ ! -e /dev/net/tun ]]; then
  log "/dev/net/tun is missing — cannot run NordLynx/Tailscale in Docker."
  exit 1
fi

write_env_if_needed() {
  if [[ -f .env ]]; then
    return 0
  fi
  if [[ -z "${TOKEN:-}" || -z "${TS_AUTHKEY:-}" ]]; then
    log "Need .env, or TOKEN and TS_AUTHKEY in the environment. Do not invent credentials."
    exit 1
  fi
  umask 077
  cat >.env <<EOF
TOKEN=${TOKEN}
CONNECT=${CONNECT:-Barcelona}
TECHNOLOGY=${TECHNOLOGY:-NordLynx}
NETWORK=${NETWORK:-100.64.0.0/10}
TZ=${TZ:-Asia/Hong_Kong}
TS_AUTHKEY=${TS_AUTHKEY}
TS_HOSTNAME=${TS_HOSTNAME:-nord-exit}
TS_EXTRA_ARGS=--advertise-exit-node --accept-dns=false
NORD_EXIT_ROLE=host
EOF
  chmod 600 .env
  log "Wrote .env (mode 600) from environment."
}

require_secrets() {
  local token key
  token="$(grep -E '^TOKEN=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  key="$(grep -E '^TS_AUTHKEY=' .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d '[:space:]')"
  if [[ -z "$token" ]]; then
    log "TOKEN is empty in .env"
    exit 1
  fi
  if [[ -z "$key" ]]; then
    log "TS_AUTHKEY is empty in .env — create a reusable auth key and retry."
    exit 1
  fi
  if ! grep -q '^NORD_EXIT_ROLE=' .env; then
    printf '\nNORD_EXIT_ROLE=host\n' >>.env
  fi
}

install_docker() {
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    log "Docker and compose plugin already installed."
    return 0
  fi
  log "Installing Docker Engine + compose plugin..."
  sudo apt-get update -y
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  if [[ ! -f /etc/apt/keyrings/docker.asc ]]; then
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
}

ensure_docker_group() {
  sudo usermod -aG docker "$USER" 2>/dev/null || true
  sudo -n systemctl enable --now docker 2>/dev/null || sudo systemctl enable --now docker
}

with_docker() {
  if docker info >/dev/null 2>&1; then
    "$@"
    return
  fi
  if sg docker -c 'docker info' >/dev/null 2>&1; then
    sg docker -c "$(printf '%q ' "$@")"
    return
  fi
  log "Docker socket not usable yet. Log out/in or run: newgrp docker"
  sudo docker info >/dev/null
  sudo "$@"
}

install_cli() {
  mkdir -p "$HOME/bin"
  ln -sfn "$STACK_DIR/bin/nord-exit" "$HOME/bin/nord-exit"
  chmod +x "$STACK_DIR/bin/nord-exit" "$STACK_DIR/up.sh" "$STACK_DIR/use-exit.sh"
  log "CLI installed at $HOME/bin/nord-exit"
}

install_guard() {
  "$STACK_DIR/bin/nord-exit" watch-install
}

write_env_if_needed
require_secrets
install_docker
ensure_docker_group
with_docker "$STACK_DIR/up.sh"
install_cli
install_guard

echo
log "Bootstrap finished. Verify with:"
echo "  docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn"
echo "  docker exec nord-exit-vpn curl -4 -fsS --max-time 10 https://ipinfo.io/json"
echo "  docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status"
echo "  $HOME/bin/nord-exit doctor"
