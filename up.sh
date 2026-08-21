#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

if [[ ! -f .env ]]; then
  echo "Missing .env — set TOKEN / CONNECT first" >&2
  exit 1
fi

TOKEN=$(python3 - <<'PY'
from pathlib import Path
for line in Path(".env").read_text().splitlines():
    if line.startswith("TOKEN="):
        print(line.split("=", 1)[1].strip().strip('"').strip("'"))
        break
PY
)
if [[ -z "${TOKEN:-}" ]]; then
  echo "TOKEN is empty in .env" >&2
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "Docker is not running. Opening Docker Desktop..." >&2
  open -a Docker
  for _ in $(seq 1 60); do
    docker info >/dev/null 2>&1 && break
    sleep 2
  done
  docker info >/dev/null 2>&1 || {
    echo "Docker still unavailable" >&2
    exit 1
  }
fi

mkdir -p state
# Keep TS_EXTRA_ARGS unquoted for docker env_file (docker handles the line)
if [[ ! -f .env.tailscale ]]; then
  cat > .env.tailscale <<'EOF'
TS_HOSTNAME=nord-exit
TS_EXTRA_ARGS=--advertise-exit-node --accept-dns=false
EOF
fi

# If Tailscale state is not logged in yet, bootstrap on a normal network first
# (Nord's DNS/routing can block the interactive login handshake).
need_bootstrap=1
if [[ -d state ]] && docker compose -f docker-compose.bootstrap.yml run --rm --no-deps \
  -e TS_AUTHKEY=dummy tailscale true >/dev/null 2>&1; then
  :
fi
if docker compose ps --status running 2>/dev/null | grep -q nord-exit-tailscale; then
  state=$(docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
  [[ "$state" == "Running" ]] && need_bootstrap=0
fi
# Detect persisted login in state dir
if [[ -f state/tailscaled.state ]]; then
  need_bootstrap=0
fi

if [[ ! -f state/tailscaled.state ]]; then
  echo "=== Phase 1: bootstrap Tailscale login (without Nord) ==="
  docker compose -f docker-compose.bootstrap.yml up -d
  echo "Waiting for auth URL..."
  url=""
  for i in $(seq 1 60); do
    url=$(docker logs nord-exit-tailscale 2>&1 | grep -oE 'https://login\.tailscale\.com/a/[a-z0-9]+' | tail -1 || true)
    state=$(docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
    if [[ "$state" == "Running" ]]; then
      echo "Already authenticated."
      break
    fi
    if [[ -n "$url" ]]; then
      echo "$url" | tee AUTH_URL.txt
      open "$url" || true
      echo
      echo "Sign in with your Tailscale account (GitHub for youwenshao.github), then return here."
      break
    fi
    sleep 2
  done
  if [[ -z "$url" && "$state" != "Running" ]]; then
    echo "No auth URL yet. Check: docker logs nord-exit-tailscale" >&2
  fi
  echo "Waiting until nord-exit is Running..."
  for i in $(seq 1 120); do
    state=$(docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null \
      | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
    if [[ "$state" == "Running" ]]; then
      echo "Tailscale authenticated."
      break
    fi
    sleep 3
  done
  state=$(docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status --json 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("BackendState",""))' 2>/dev/null || true)
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
echo "  1) Admin console → nord-exit → Edit route settings → enable Use as exit node"
echo "     https://login.tailscale.com/admin/machines"
echo "  2) On this Mac: ./use-exit.sh on"
