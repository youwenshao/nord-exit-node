#!/usr/bin/env bash
# Bring up the Nord + Tailscale exit-node stack on this machine.
set -euo pipefail
cd "$(dirname "$0")"
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"

env_get() {
  local key="$1"
  [[ -f .env ]] || return 0
  grep -E "^${key}=" .env | head -1 | cut -d= -f2- | tr -d '"' | tr -d "'"
}

if [[ ! -f .env ]]; then
  echo "Missing .env — copy .env.example and set TOKEN / CONNECT / TS_AUTHKEY" >&2
  exit 1
fi

TOKEN="$(env_get TOKEN)"
if [[ -z "${TOKEN:-}" ]]; then
  echo "TOKEN is empty in .env" >&2
  exit 1
fi

TS_AUTHKEY="$(env_get TS_AUTHKEY)"
TS_HOSTNAME="$(env_get TS_HOSTNAME)"
TS_HOSTNAME="${TS_HOSTNAME:-nord-exit}"
TS_EXTRA_ARGS="$(env_get TS_EXTRA_ARGS)"
TS_EXTRA_ARGS="${TS_EXTRA_ARGS:---advertise-exit-node --accept-dns=false}"

ensure_docker() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$OS" == darwin ]]; then
    echo "Docker is not running. Opening Docker Desktop..." >&2
    open -a Docker
  else
    echo "Docker is not running. Starting docker.service..." >&2
    sudo -n systemctl start docker 2>/dev/null || sudo systemctl start docker
  fi
  local _
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  echo "Docker still unavailable" >&2
  return 1
}

write_env_tailscale() {
  # docker env_file: do not quote TS_EXTRA_ARGS
  umask 077
  {
    printf 'TS_HOSTNAME=%s\n' "$TS_HOSTNAME"
    printf 'TS_EXTRA_ARGS=%s\n' "$TS_EXTRA_ARGS"
    if [[ -n "${TS_AUTHKEY:-}" ]]; then
      printf 'TS_AUTHKEY=%s\n' "$TS_AUTHKEY"
    fi
  } >.env.tailscale
  chmod 600 .env.tailscale
}

ts_backend_state() {
  docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true
}

ensure_docker || exit 1
mkdir -p state
write_env_tailscale

need_bootstrap=1
if [[ -n "${TS_AUTHKEY:-}" ]]; then
  echo "TS_AUTHKEY present — skipping interactive Tailscale login."
  need_bootstrap=0
fi
if docker compose ps --status running 2>/dev/null | grep -q nord-exit-tailscale; then
  state="$(ts_backend_state)"
  [[ "$state" == "Running" ]] && need_bootstrap=0
fi
if [[ -f state/tailscaled.state ]]; then
  need_bootstrap=0
fi

if [[ "$need_bootstrap" -eq 1 ]]; then
  echo "=== Phase 1: bootstrap Tailscale login (without Nord) ==="
  docker compose -f docker-compose.bootstrap.yml up -d
  echo "Waiting for auth URL..."
  url=""
  state=""
  local_i=0
  for local_i in $(seq 1 60); do
    url=$(docker logs nord-exit-tailscale 2>&1 | grep -oE 'https://login\.tailscale\.com/a/[a-z0-9]+' | tail -1 || true)
    state="$(ts_backend_state)"
    if [[ "$state" == "Running" ]]; then
      echo "Already authenticated."
      break
    fi
    if [[ -n "$url" ]]; then
      echo "$url" | tee AUTH_URL.txt
      if [[ "$OS" == darwin ]]; then
        open "$url" || true
      fi
      echo
      echo "Sign in with your Tailscale account, then return here."
      echo "Auth URL also written to AUTH_URL.txt"
      break
    fi
    sleep 2
  done
  if [[ -z "$url" && "$state" != "Running" ]]; then
    echo "No auth URL yet. Check: docker logs nord-exit-tailscale" >&2
  fi
  echo "Waiting until nord-exit is Running..."
  for local_i in $(seq 1 120); do
    state="$(ts_backend_state)"
    if [[ "$state" == "Running" ]]; then
      echo "Tailscale authenticated."
      break
    fi
    sleep 3
  done
  state="$(ts_backend_state)"
  if [[ "$state" != "Running" ]]; then
    echo "Still not logged in. Authenticate via AUTH_URL.txt then re-run ./up.sh" >&2
    exit 2
  fi
  docker compose -f docker-compose.bootstrap.yml down
fi

echo "=== Phase 2: Nord + Tailscale exit stack ==="
docker compose pull
docker compose up -d

echo
echo "Waiting for Nord VPN health..."
for i in $(seq 1 40); do
  status=$(docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn 2>/dev/null || echo starting)
  if [[ "$status" == "healthy" ]]; then
    echo "Nord is healthy."
    break
  fi
  echo "  vpn health: $status ($i)"
  sleep 3
done

echo
echo "Tailscale status inside stack:"
docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status 2>&1 | head -20 || true

echo
echo "Public IP from exit stack (should be Nord / PacketHub etc.):"
docker exec nord-exit-vpn curl -4 -fsS --max-time 10 https://ipinfo.io/json || true
echo
echo
echo "Next:"
echo "  1) If this is a new tailnet, add autoApprovers.exitNode (see docs/tailscale-acl.md)"
echo "  2) On a client: nord-exit on"
