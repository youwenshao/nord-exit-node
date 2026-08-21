#!/usr/bin/env bash
set -euo pipefail
TS="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
echo "Waiting until offline MagicDNS name nord-exit.tail*.ts.net is gone..."
for i in $(seq 1 60); do
  offline=$($TS status --json | python3 -c '
import json,sys
d=json.load(sys.stdin)
for p in d.get("Peer",{}).values():
  dns=(p.get("DNSName") or "")
  if dns.startswith("nord-exit.") and not p.get("Online"):
    print("yes"); break
')
  live=$($TS status --json | python3 -c '
import json,sys
for p in json.load(sys.stdin).get("Peer",{}).values():
  if p.get("Online") and "nord-exit" in (p.get("DNSName") or ""):
    print(p.get("DNSName"), p.get("TailscaleIPs")); break
')
  echo "[$i] offline_nord_exit=$offline live=$live"
  if [[ -z "$offline" ]]; then
    echo "Stale nord-exit gone. Refreshing hostname on container..."
    docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock set --hostname=nord-exit-tmp 2>/dev/null || true
    sleep 3
    docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock set --hostname=nord-exit --advertise-exit-node --accept-dns=false
    sleep 5
    $TS status | rg nord || $TS status
    echo "Done. Prefer: nord-exit (may take a minute for MagicDNS)."
    exit 0
  fi
  sleep 5
done
echo "Timed out waiting for you to remove the offline nord-exit machine in the admin console." >&2
exit 1
