#!/bin/bash
# Ensure Tailscale CGNAT stays on the Tailscale utun, not Nord.
set -euo pipefail
# Find interface that has a 100.x Tailscale address
ts_if=$(ifconfig -l | tr ' ' '\n' | while read -r ifc; do
  if ifconfig "$ifc" 2>/dev/null | grep -q 'inet 100\.'; then
    echo "$ifc"
    break
  fi
done)
if [[ -n "${ts_if:-}" ]]; then
  /sbin/route -n delete -inet 100.64.0.0/10 >/dev/null 2>&1 || true
  /sbin/route -n add -inet 100.64.0.0/10 -interface "$ts_if" >/dev/null 2>&1 || true
fi
