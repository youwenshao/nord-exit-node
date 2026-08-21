#!/usr/bin/env bash
# nord-exit: manage Tailscale exit via Docker Nord stack on this Mac.
# fix = always restore ISP first; heal Nord; re-enable exit only if CLI works.
set -euo pipefail

TS="${TAILSCALE_CLI:-/Applications/Tailscale.app/Contents/MacOS/Tailscale}"
CONNECT_DEFAULT="Barcelona"

_SRC="${BASH_SOURCE[0]}"
while [[ -L "$_SRC" ]]; do
  _LINK="$(readlink "$_SRC")"
  if [[ "$_LINK" == /* ]]; then _SRC="$_LINK"; else _SRC="$(cd "$(dirname "$_SRC")" && pwd)/$_LINK"; fi
done
STACK_DIR="$(cd "$(dirname "$_SRC")" && pwd)"
unset _SRC _LINK

if [[ -f "$STACK_DIR/.env" ]]; then
  CONNECT_DEFAULT="$(grep -E '^CONNECT=' "$STACK_DIR/.env" | head -1 | cut -d= -f2- | tr -d '"' || true)"
  CONNECT_DEFAULT="${CONNECT_DEFAULT:-Barcelona}"
fi

usage() {
  echo "Usage: $0 {on|off|status|ip|fix [--exit]|guard|doctor|watch-install|watch-uninstall}" >&2
  echo "  on               - Barcelona via nord-exit (LAN DNS; auto-rollback if broken)" >&2
  echo "  off              - clear exit; keep LAN DNS (safe)" >&2
  echo "  fix              - unblackhole ISP + heal Nord; exit stays OFF" >&2
  echo "  fix --exit       - unblackhole, then safely re-enable exit" >&2
  echo "  guard            - if exit dead / internet dead, clear exit (unblackhole)" >&2
  echo "  watch-install    - LaunchAgent: run guard every 60s (prevents stuck blackholes)" >&2
  echo "  watch-uninstall  - remove that LaunchAgent" >&2
  exit 1
}

[[ $# -ge 1 ]] || usage
log() { printf '[nord-exit] %s\n' "$*" >&2; }

with_timeout() {
  local secs="$1"; shift
  "$@" &
  local pid=$!
  local i=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( i >= secs )); then
      kill -9 "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    i=$((i + 1))
  done
  wait "$pid"
}

ts_ok() { with_timeout 3 "$TS" status >/dev/null 2>&1; }
ts_run() { local secs="$1"; shift; with_timeout "$secs" "$TS" "$@"; }
ts_json() { with_timeout 5 "$TS" status --json 2>/dev/null; }

flush_dns() {
  dscacheutil -flushcache 2>/dev/null || true
  killall -HUP mDNSResponder 2>/dev/null || true
}

WIFI_SERVICE="Wi-Fi"
GUARD_COOLDOWN_FILE="${TMPDIR:-/tmp}/nord-exit-guard-cooldown"
GUARD_FAIL_FILE="${TMPDIR:-/tmp}/nord-exit-guard-fails"
DESIRED_FILE="$STACK_DIR/state/desired-exit" # "on" | "off"

set_desired() {
  mkdir -p "$STACK_DIR/state"
  printf '%s\n' "$1" >"$DESIRED_FILE"
}

get_desired() {
  [[ -f "$DESIRED_FILE" ]] || { echo off; return; }
  tr -d '[:space:]' <"$DESIRED_FILE"
}

# Tailscale uses network_mode: service:vpn. Restarting vpn creates a new
# netns; a still-running tailscale stays in the old one (no eth0/nordlynx,
# wget country=?, Tailscale reports "network is down").
tailscale_shares_vpn_netns() {
  local vpn_ns ts_ns
  vpn_ns=$(docker exec nord-exit-vpn readlink /proc/1/ns/net 2>/dev/null || true)
  ts_ns=$(docker exec nord-exit-tailscale readlink /proc/1/ns/net 2>/dev/null || true)
  [[ -n "$vpn_ns" && "$vpn_ns" == "$ts_ns" ]]
}

ensure_tailscale_on_vpn_netns() {
  if tailscale_shares_vpn_netns; then
    return 0
  fi
  log "Tailscale netns detached from VPN (stale after vpn restart) — reattaching..."
  docker restart nord-exit-tailscale >/dev/null 2>&1 || return 1
  local i
  for i in $(seq 1 20); do
    if tailscale_shares_vpn_netns; then
      log "Tailscale reattached to VPN netns."
      ensure_container_udp_holes
      return 0
    fi
    sleep 1
  done
  log "Failed to reattach Tailscale to VPN netns."
  return 1
}

# Re-apply container firewall holes (Nord rewrites iptables on reconnect).
ensure_container_udp_holes() {
  docker exec nord-exit-vpn sh -c '
    iptables -C OUTPUT -o eth0 -p udp -j ACCEPT 2>/dev/null || iptables -I OUTPUT -o eth0 -p udp -j ACCEPT
    iptables -C OUTPUT -o eth0 -p icmp -j ACCEPT 2>/dev/null || iptables -I OUTPUT -o eth0 -p icmp -j ACCEPT
    iptables -C FORWARD -i tailscale0 -o nordlynx -j ACCEPT 2>/dev/null || iptables -I FORWARD -i tailscale0 -o nordlynx -j ACCEPT
    iptables -C FORWARD -i nordlynx -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
      || iptables -I FORWARD -i nordlynx -o tailscale0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -t nat -C POSTROUTING -o nordlynx -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -o nordlynx -j MASQUERADE
  ' >/dev/null 2>&1 || true
}

# While on exit, NEVER use LAN DNS: allow-lan-access binds 192.168.31.1 onto utun
# and blackholes resolution. Pin public DNS so queries ride the exit.
pin_exit_dns() {
  networksetup -setdnsservers "$WIFI_SERVICE" 1.1.1.1 8.8.8.8 2>/dev/null || true
  networksetup -setdnsservers Tailscale Empty 2>/dev/null || true
  flush_dns
}

# Back to DHCP DNS when not using exit.
restore_dhcp_dns() {
  networksetup -setdnsservers "$WIFI_SERVICE" Empty 2>/dev/null || true
  flush_dns
}

mark_guard_cooldown() {
  # Guard must not fight a fresh `on` during DERP/DNS settle.
  local until=$(( $(date +%s) + 120 ))
  echo "$until" >"$GUARD_COOLDOWN_FILE"
}

guard_in_cooldown() {
  [[ -f "$GUARD_COOLDOWN_FILE" ]] || return 1
  local until now
  until=$(cat "$GUARD_COOLDOWN_FILE" 2>/dev/null || echo 0)
  now=$(date +%s)
  (( now < until ))
}

quit_tailscale_app() {
  osascript -e 'quit app "Tailscale"' 2>/dev/null || true
  pkill -x Tailscale 2>/dev/null || true
  # Kill stuck CLI children talking to a wedged extension
  pkill -9 -f '/Applications/Tailscale.app/Contents/MacOS/Tailscale' 2>/dev/null || true
}

internet_ok() {
  curl -4 -fsS --max-time 4 https://1.1.1.1 -o /dev/null 2>/dev/null \
    || ping -c 1 -W 2000 1.1.1.1 >/dev/null 2>&1 \
    || return 1
  if curl -4 -fsS --max-time 5 https://example.com -o /dev/null 2>/dev/null; then
    return 0
  fi
  local a
  a=$(dig @192.168.31.1 +short example.com A 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
  [[ -n "$a" ]] || a=$(dig +short example.com A 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
  [[ -n "$a" ]] || return 1
  curl -4 -fsS --max-time 5 --resolve "example.com:443:$a" https://example.com -o /dev/null 2>/dev/null
}

show_public_ip() {
  local i out a
  for i in 1 2 3 4 5; do
    if out=$(curl -4 -fsS --max-time 8 https://ipinfo.io/json 2>/dev/null); then
      printf '%s\n' "$out"
      return 0
    fi
    a=$(dig +short ipinfo.io A 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
    [[ -n "$a" ]] || a=$(dig @192.168.31.1 +short ipinfo.io A 2>/dev/null | awk '/^[0-9.]+$/ {print; exit}')
    if [[ -n "$a" ]]; then
      if out=$(curl -4 -fsS --max-time 8 --resolve "ipinfo.io:443:$a" https://ipinfo.io/json 2>/dev/null); then
        printf '%s\n' "$out"
        return 0
      fi
    fi
    sleep 1
  done
  log "Public IP check failed."
  return 1
}

wait_ts_ok() {
  local max="${1:-12}" i
  for i in $(seq 1 "$max"); do
    ts_ok && return 0
    sleep 1
  done
  return 1
}

# Restart system extension. Never block >20s on password UI.
kick_network_extension() {
  log "Kicking Tailscale network extension (admin password; 20s max)..."
  if sudo -n true 2>/dev/null; then
    sudo -n pkill -9 -f 'io.tailscale.ipn.macsys.network-extension' 2>/dev/null || true
    return 0
  fi
  if with_timeout 20 osascript -e 'do shell script "pkill -9 -f io.tailscale.ipn.macsys.network-extension || true" with administrator privileges' >/dev/null 2>&1; then
    return 0
  fi
  log "No admin auth — extension not kicked."
  return 1
}

# Guaranteed goal: hostname internet works via ISP.
# Fast path: if DNS/hostname is dead, quit Tailscale immediately (don't wait on hung CLI).
restore_isp() {
  log "Restoring ISP path..."

  # Fast unblackhole: MagicDNS (100.100.100.100) is the usual killer.
  if ! internet_ok; then
    log "Internet dead — quitting Tailscale immediately to drop MagicDNS..."
    quit_tailscale_app
    flush_dns
    sleep 2
    if internet_ok; then
      log "ISP OK (Tailscale quit)."
      return 0
    fi
  fi

  if ts_ok; then
    # Hard clear exit + sticky RouteAll via reset-safe up flags
    ts_run 5 set --exit-node= >/dev/null 2>&1 || true
    ts_run 5 set --accept-dns=false >/dev/null 2>&1 || true
    ts_run 12 up --reset --accept-dns=false --exit-node= --exit-node-allow-lan-access=false >/dev/null 2>&1 || true
    flush_dns
    sleep 1
    if internet_ok; then
      log "ISP OK (cleared exit / LAN DNS)."
      return 0
    fi
  fi

  log "Quitting Tailscale to drop MagicDNS blackhole..."
  quit_tailscale_app
  flush_dns
  sleep 2
  if internet_ok; then
    log "ISP OK (Tailscale quit)."
    return 0
  fi

  kick_network_extension || true
  quit_tailscale_app
  flush_dns
  sleep 2
  if internet_ok; then
    log "ISP OK after extension kick."
    return 0
  fi
  log "WARNING: ISP still not healthy — check Wi‑Fi."
  return 1
}

bring_up_tailscale() {
  open -a Tailscale
  if wait_ts_ok 15; then
    # Never come back with a sticky exit / MagicDNS
    ts_run 12 up --reset --accept-dns=false --exit-node= --exit-node-allow-lan-access=false >/dev/null 2>&1 || true
    ts_run 5 set --exit-node= --accept-dns=false >/dev/null 2>&1 || true
    flush_dns
    if internet_ok; then
      return 0
    fi
    log "Internet broke after Tailscale up — quitting again."
    quit_tailscale_app
    flush_dns
    return 1
  fi
  log "CLI hung after relaunch — kicking extension..."
  if kick_network_extension; then
    sleep 2
    open -a Tailscale
    if wait_ts_ok 15; then
      ts_run 12 up --reset --accept-dns=false --exit-node= --exit-node-allow-lan-access=false >/dev/null 2>&1 || true
      ts_run 5 set --exit-node= --accept-dns=false >/dev/null 2>&1 || true
      flush_dns
      internet_ok && return 0
    fi
  fi
  log "CLI still hung. Quitting Tailscale so ISP DNS stays clean."
  quit_tailscale_app
  flush_dns
  return 1
}

ensure_docker() {
  if docker info >/dev/null 2>&1; then return 0; fi
  log "Starting Docker Desktop..."
  open -a Docker
  local i
  for i in $(seq 1 60); do
    docker info >/dev/null 2>&1 && return 0
    sleep 2
  done
  return 1
}

heal_nord_stack() {
  log "Healing Nord exit Docker stack..."
  ensure_docker || { log "Docker unavailable."; return 1; }
  (cd "$STACK_DIR" && docker compose up -d) || true

  local i h
  h=$(docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn 2>/dev/null || echo missing)
  # Only restart if unhealthy — restarting a healthy VPN can invalidate the token session
  if [[ "$h" != "healthy" ]]; then
    log "vpn health=$h — restarting containers..."
    docker restart nord-exit-vpn >/dev/null 2>&1 || true
    sleep 3
    docker restart nord-exit-tailscale >/dev/null 2>&1 || true
  else
    log "vpn already healthy — skipping restart."
  fi

  for i in $(seq 1 40); do
    h=$(docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn 2>/dev/null || echo starting)
    [[ "$h" == "healthy" ]] && break
    sleep 2
  done

  docker exec nord-exit-vpn nordvpn set firewall disabled >/dev/null 2>&1 || true
  docker exec nord-exit-vpn nordvpn set killswitch disabled >/dev/null 2>&1 || true
  docker exec nord-exit-vpn sh -c \
    "nordvpn status | grep -q 'Status: Connected' || nordvpn connect '${CONNECT_DEFAULT}'" \
    >/dev/null 2>&1 || true
  docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock \
    set --advertise-exit-node --accept-dns=false --hostname=nord-exit \
    >/dev/null 2>&1 || true
  ensure_tailscale_on_vpn_netns || true
  ensure_container_udp_holes

  for i in $(seq 1 12); do
    if docker exec nord-exit-tailscale wget -qO- --timeout=8 https://ipinfo.io/country 2>/dev/null | grep -q .; then
      log "Nord container egress OK."
      return 0
    fi
    sleep 2
  done
  log "WARNING: Nord container egress check failed."
  return 1
}

resolve_nord_peer() {
  ts_json | python3 -c '
import json,sys
d=json.load(sys.stdin)
live=[]
for p in d.get("Peer",{}).values():
    dns=(p.get("DNSName") or "").rstrip(".")
    host=(p.get("HostName") or "")
    if not p.get("ExitNodeOption"):
        continue
    if "nord-exit" not in dns and not host.startswith("nord-exit"):
        continue
    ips=p.get("TailscaleIPs") or []
    ip=ips[0] if ips else dns
    online=1 if p.get("Online") else 0
    live.append((0 if dns.startswith("nord-exit.") else 1, -online, dns, ip, p.get("ID") or "", online))
live.sort()
if not live:
    sys.exit(1)
_,_,dns,ip,pid,online=live[0]
print(f"{ip}\t{pid}\t{online}")
'
}

wait_peer_online() {
  local i peer
  for i in $(seq 1 20); do
    peer=$(resolve_nord_peer 2>/dev/null || true)
    if [[ -n "$peer" && "$(printf '%s' "$peer" | cut -f3)" == "1" ]]; then
      printf '%s\n' "$peer"
      return 0
    fi
    sleep 2
  done
  return 1
}

# Require Nord container itself to be in Spain before we risk host routing.
preflight_nord_barcelona() {
  local city country
  if ! ensure_tailscale_on_vpn_netns; then
    log "Tailscale is not on the VPN network namespace — refusing to enable exit."
    return 1
  fi
  if ! docker exec nord-exit-vpn nordvpn status 2>/dev/null | grep -q 'Status: Connected'; then
    log "Nord container not Connected — connecting ${CONNECT_DEFAULT}..."
    docker exec nord-exit-vpn nordvpn set firewall disabled >/dev/null 2>&1 || true
    docker exec nord-exit-vpn nordvpn set killswitch disabled >/dev/null 2>&1 || true
    docker exec nord-exit-vpn nordvpn connect "$CONNECT_DEFAULT" >/dev/null 2>&1 || true
    sleep 3
  fi
  city=$(docker exec nord-exit-vpn nordvpn status 2>/dev/null | awk -F': ' '/^City:/{print $2; exit}')
  country=$(docker exec nord-exit-tailscale wget -qO- --timeout=8 https://ipinfo.io/country 2>/dev/null | tr -d '\r\n' || true)
  log "Nord preflight: city=${city:-?} container_country=${country:-?}"
  if [[ -z "$country" ]]; then
    log "Could not read container egress country (DNS/netns) — refusing to enable exit."
    return 1
  fi
  if [[ "$country" != "ES" ]]; then
    log "Container egress is not Spain — refusing to enable exit (prevents blackhole/wrong geo)."
    return 1
  fi
  return 0
}

clear_exit_safe() {
  ts_run 6 set --exit-node= >/dev/null 2>&1 || true
  ts_run 6 set --accept-dns=false >/dev/null 2>&1 || true
  restore_dhcp_dns
  flush_dns
}

enable_exit() {
  local peer NODE json country i
  if ! ts_ok; then
    log "Tailscale CLI not responsive — cannot enable exit."
    return 1
  fi

  # Anti-blackhole contract:
  # 1) Nord must already egress Spain
  # 2) Never MagicDNS; never LAN DNS via utun (that blackholes)
  # 3) exit-node-allow-lan-access=false + Wi‑Fi DNS=1.1.1.1/8.8.8.8
  # 4) verify internet+Spain or roll back
  # Tradeoff: home LAN (192.168.x) unreachable while exit is on — use `off` for LAN.
  if ! preflight_nord_barcelona; then
    clear_exit_safe
    return 1
  fi

  peer=$(wait_peer_online) || {
    log "nord-exit peer not online — leaving exit cleared."
    clear_exit_safe
    return 1
  }
  NODE=$(printf '%s' "$peer" | cut -f1)

  # DERP-only paths return exit code 1 even after a successful pong — check output.
  ping_out=$(ts_run 8 ping -c 1 -timeout 5s "$NODE" 2>&1 || true)
  if ! printf '%s' "$ping_out" | grep -qi 'pong from'; then
    log "Cannot ping nord-exit — refusing to enable exit."
    log "$ping_out"
    clear_exit_safe
    return 1
  fi
  log "Reachable via: $(printf '%s' "$ping_out" | awk '/pong from/{print; exit}')"

  # Pin DNS BEFORE selecting exit so the first resolver list is already public DNS
  pin_exit_dns
  clear_exit_safe
  pin_exit_dns
  sleep 1
  if ! ts_run 10 set --exit-node="$NODE" --exit-node-allow-lan-access=false --accept-dns=false; then
    log "Failed to set exit node."
    clear_exit_safe
    return 1
  fi
  log "Exit node set to $NODE (public DNS via exit; LAN access off)."
  pin_exit_dns
  mark_guard_cooldown
  rm -f "$GUARD_FAIL_FILE"

  # Settle DERP + DNS, then require hostname internet
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if internet_ok; then
      break
    fi
    sleep 1
  done
  if ! internet_ok; then
    log "Internet broke after exit — rolling back to ISP."
    clear_exit_safe
    quit_tailscale_app
    sleep 1
    open -a Tailscale
    wait_ts_ok 12 || true
    clear_exit_safe
    return 1
  fi

  json=$(show_public_ip 2>/dev/null || true)
  if [[ -z "$json" ]]; then
    log "Could not verify public IP — rolling back."
    clear_exit_safe
    return 1
  fi
  printf '%s\n' "$json"
  country=$(printf '%s' "$json" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("country",""))' 2>/dev/null || true)
  if [[ "$country" != "ES" ]]; then
    log "Expected Spain egress, got '${country:-?}' — rolling back."
    clear_exit_safe
    return 1
  fi

  # Stability check: still good a few seconds later (catches DNS-on-utun flake)
  sleep 3
  if ! internet_ok; then
    log "Internet flaked after verify — rolling back."
    clear_exit_safe
    return 1
  fi
  log "Barcelona exit verified and stable."
  return 0
}

prefs_has_exit_node() {
  with_timeout 4 "$TS" debug prefs 2>/dev/null | python3 -c '
import json,sys
d=json.load(sys.stdin)
sys.exit(0 if d.get("ExitNodeID") else 1)
' 2>/dev/null
}

selected_exit_peer_online() {
  ts_json | python3 -c '
import json,sys
d=json.load(sys.stdin)
ens=d.get("ExitNodeStatus") or {}
eid=ens.get("ID") if isinstance(ens, dict) else None
if not eid:
    for p in d.get("Peer",{}).values():
        if p.get("ExitNode"):
            eid=p.get("ID"); break
if not eid: sys.exit(2)
for p in d.get("Peer",{}).values():
    if p.get("ID")==eid: sys.exit(0 if p.get("Online") else 1)
sys.exit(1)
'
}

doctor() {
  log "=== doctor ==="
  route -n get default 2>&1 | sed -n '1,10p' >&2 || true
  scutil --dns 2>/dev/null | head -18 >&2 || true
  if ts_ok; then
    ts_run 5 status 2>&1 | head -10 >&2 || true
  else
    log "Tailscale CLI NOT responsive."
  fi
  docker ps --format '{{.Names}} {{.Status}}' 2>/dev/null | grep nord >&2 || log "No nord containers"
  if internet_ok; then log "internet_ok=yes"; else log "internet_ok=no"; fi
  show_public_ip || true
}

case "$1" in
  on)
    set_desired on
    ensure_docker || { log "Docker unavailable."; exit 1; }
    (cd "$STACK_DIR" && docker compose up -d) >/dev/null
    for _ in $(seq 1 30); do
      h=$(docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn 2>/dev/null || echo starting)
      [[ "$h" == "healthy" ]] && break
      sleep 2
    done
    ensure_tailscale_on_vpn_netns || { log "Could not attach Tailscale to VPN netns."; exit 1; }
    ensure_container_udp_holes
    if ! ts_ok; then
      bring_up_tailscale || { log "Tailscale CLI hung."; exit 1; }
    fi
    enable_exit || exit 1
    ;;
  off)
    set_desired off
    if ts_ok; then
      ts_run 8 up --reset --accept-dns=false --exit-node= --exit-node-allow-lan-access=false >/dev/null 2>&1 || true
      ts_run 5 set --exit-node= --accept-dns=false >/dev/null 2>&1 || true
    else
      restore_isp || true
      bring_up_tailscale || true
    fi
    restore_dhcp_dns
    log "Exit cleared (desired=off). Mesh should work; no location spoof."
    show_public_ip || true
    ;;
  guard)
    # Supervisor: keep desired=on working. Do NOT permanently drop exit on blips.
    if guard_in_cooldown; then
      exit 0
    fi
    desired=$(get_desired)
    bump_fail() {
      local n=0
      [[ -f "$GUARD_FAIL_FILE" ]] && n=$(cat "$GUARD_FAIL_FILE" 2>/dev/null || echo 0)
      n=$((n + 1))
      echo "$n" >"$GUARD_FAIL_FILE"
      echo "$n"
    }
    clear_fails() { rm -f "$GUARD_FAIL_FILE"; }

    ensure_container_udp_holes

    if [[ "$desired" != "on" ]]; then
      # desired off: if somehow exit still selected and internet dead, clear it
      if prefs_has_exit_node && ! internet_ok; then
        log "desired=off but exit stuck/dead — clearing."
        clear_exit_safe
      fi
      clear_fails
      exit 0
    fi

    # desired=on
    if ! ts_ok; then
      n=$(bump_fail)
      log "CLI hung (x$n) while desired=on — restoring app."
      restore_isp || true
      bring_up_tailscale || true
      if (( n >= 3 )); then
        enable_exit >/dev/null 2>&1 || true
        clear_fails
      fi
      exit 0
    fi

    if prefs_has_exit_node; then
      set +e; selected_exit_peer_online; rc=$?; set -e
      if [[ $rc -ne 0 ]]; then
        n=$(bump_fail)
        log "Exit peer unhealthy (x$n) — recovering (not dropping desired=on)."
        # Brief ISP unblackhole, heal holes, re-enable
        if (( n >= 2 )); then
          clear_exit_safe
          ensure_container_udp_holes
          docker restart nord-exit-tailscale >/dev/null 2>&1 || true
          sleep 4
          enable_exit >/dev/null 2>&1 || true
          mark_guard_cooldown
          clear_fails
        fi
        exit 0
      fi
      if ! internet_ok; then
        pin_exit_dns
        sleep 1
        if internet_ok; then
          clear_fails
          exit 0
        fi
        n=$(bump_fail)
        log "Internet dead on exit (x$n) — recover path."
        if (( n >= 2 )); then
          # Unblackhole briefly, then re-assert exit (user wants Barcelona)
          clear_exit_safe
          ensure_container_udp_holes
          if ! internet_ok; then
            restore_isp || true
            bring_up_tailscale || true
          fi
          enable_exit >/dev/null 2>&1 || true
          mark_guard_cooldown
          clear_fails
        fi
        exit 0
      fi
      # Healthy — quiet success (no log spam)
      clear_fails
      exit 0
    fi

    # desired=on but exit not selected — re-enable
    n=$(bump_fail)
    log "desired=on but exit not selected (x$n) — enabling."
    ensure_container_udp_holes
    enable_exit >/dev/null 2>&1 || true
    mark_guard_cooldown
    if prefs_has_exit_node && internet_ok; then
      clear_fails
    fi
    ;;
  watch-install)
    PLIST="$HOME/Library/LaunchAgents/com.youwen.nord-exit-guard.plist"
    mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
    cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.youwen.nord-exit-guard</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>${STACK_DIR}/use-exit.sh</string>
    <string>guard</string>
  </array>
  <key>StartInterval</key><integer>45</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/Library/Logs/nord-exit-guard.log</string>
  <key>StandardErrorPath</key><string>${HOME}/Library/Logs/nord-exit-guard.log</string>
</dict>
</plist>
EOF
    launchctl bootout "gui/$(id -u)/com.youwen.nord-exit-guard" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST"
    launchctl enable "gui/$(id -u)/com.youwen.nord-exit-guard" 2>/dev/null || true
    log "Installed supervisor (every 45s). Log: ~/Library/Logs/nord-exit-guard.log"
    ;;
  watch-uninstall)
    launchctl bootout "gui/$(id -u)/com.youwen.nord-exit-guard" 2>/dev/null || true
    rm -f "$HOME/Library/LaunchAgents/com.youwen.nord-exit-guard.plist"
    log "Watchdog removed."
    ;;
  fix)
    # Default: restore ISP then honor desired state (re-on if desired=on)
    FORCE_OFF=0
    WANT_EXIT=0
    if [[ "${2:-}" == "--exit" || "${2:-}" == "exit" ]]; then
      WANT_EXIT=1
      set_desired on
    elif [[ "${2:-}" == "--off" ]]; then
      FORCE_OFF=1
      set_desired off
    elif [[ "$(get_desired)" == "on" ]]; then
      WANT_EXIT=1
    fi
    if [[ $WANT_EXIT -eq 1 ]]; then
      log "=== fix: unblackhole then re-enable exit (desired=$(get_desired)) ==="
    else
      log "=== fix: unblackhole only (desired=$(get_desired)) ==="
    fi

    restore_isp || true
    if ! internet_ok; then
      log "ISP still down — check Wi‑Fi. Aborting."
      doctor
      exit 1
    fi
    log "ISP baseline:"
    show_public_ip || true

    heal_nord_stack || log "Nord heal had warnings; continuing..."
    ensure_container_udp_holes

    if ! bring_up_tailscale; then
      log "fix partial: ISP restored; host Tailscale CLI still hung."
      show_public_ip || true
      exit 0
    fi

    if [[ $WANT_EXIT -eq 1 && $FORCE_OFF -eq 0 ]]; then
      if enable_exit; then
        log "fix complete — exit re-enabled (desired=on)."
        exit 0
      fi
      log "Exit not re-enabled yet; supervisor will keep trying. ISP works."
    else
      log "fix complete — exit OFF."
    fi
    show_public_ip || true
    internet_ok
    ;;
  doctor) doctor ;;
  status)
    if ts_ok; then
      ts_run 6 status || true
      echo
      ts_run 6 exit-node list 2>/dev/null | head -20 || true
    else
      log "Tailscale CLI hung (try: ~/bin/nord-exit fix)."
    fi
    show_public_ip || true
    ;;
  ip) show_public_ip ;;
  *) usage ;;
esac
