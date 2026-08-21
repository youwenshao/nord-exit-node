#!/usr/bin/with-contenv bash
set -euo pipefail

echo "[nord-connect] waiting for nordvpnd socket..."
for _ in $(seq 1 90); do
  if nordvpn status >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if [[ -n "${TOKEN:-}" ]]; then
  echo "[nord-connect] ensuring login"
  nordvpn login --token "$TOKEN" >/dev/null 2>&1 || true
fi

nordvpn set technology "${TECHNOLOGY:-NordLynx}" >/dev/null 2>&1 || true
nordvpn set killswitch on >/dev/null 2>&1 || true
nordvpn set autoconnect on >/dev/null 2>&1 || true
# Allow LAN/mesh through kill switch (also set via NETWORK env in image)
nordvpn set lan-discovery disable >/dev/null 2>&1 || true

if ! nordvpn status 2>/dev/null | grep -q "Status: Connected"; then
  echo "[nord-connect] connecting to ${CONNECT:-Hong_Kong}"
  if [[ -n "${CONNECT:-}" ]]; then
    nordvpn connect "$CONNECT" || nordvpn connect
  else
    nordvpn connect
  fi
fi

nordvpn status || true

# Keep service alive so s6 doesn't restart it in a loop
exec sleep infinity
