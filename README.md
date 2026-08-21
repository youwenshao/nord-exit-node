# Nord exit node (via Tailscale)

Standalone location-spoof stack. Daily CLI: `~/bin/nord-exit`.

Linux Docker stack: **NordVPN for public egress** + **Tailscale advertise-exit-node**.

On your MacBook Air, keep Tailscale connected for the mesh. When you want apps to see a Nord location, select this exit node. When you don’t, clear the exit node.

## One-time setup

1. Ensure Docker Desktop is running (and the **NordVPN macOS app is disconnected**).
2. Secrets live in `.env` (gitignored). `TOKEN` / `CONNECT` are already set for this machine.
3. Start:

```bash
cd /Users/youwen/Projects/MISC/nord-exit
./up.sh
```

4. **Approve Tailscale login** (one-time): `up.sh` first starts Tailscale *without* Nord (Nord breaks the login handshake), opens `AUTH_URL.txt` in your browser — sign in with the same account as this tailnet (`youwenshao.github`). Then it attaches Tailscale to Nord.
5. In the [Tailscale admin console](https://login.tailscale.com/admin/machines), open **nord-exit** → **Edit route settings** → enable **Use as exit node** → save.

Keep the **NordVPN macOS app disconnected** while using this stack — the Linux container is your Nord egress.

**Docker note:** Nord’s kill switch/firewall stays **off** inside the container on purpose. With it on, Tailscale DERP dies under Docker Desktop. Egress still goes out NordLynx; you just lose Nord’s local kill-switch.

## Daily use (MacBook Air)

Location spoofing only works while the Tailscale **exit node** is selected **and** the Docker `nord-exit` stack is running. Mesh alone does not change your public IP.

## Robustness (why it used to flake)

Two stacked root causes:

1. **Nord container iptables** used `OUTPUT DROP` and only allowed NordLynx UDP/51820. Tailscale WireGuard UDP was blocked → exit path was **DERP-TCP only**, which dropped randomly. Fix: `scripts/nord-connect-svc/run` punches UDP/ICMP on `eth0` + Tailscale↔NordLynx FORWARD, and re-applies every 20s.
2. **Host DNS** with `--exit-node-allow-lan-access` put `192.168.31.1` on utun and blackholed resolution. Fix: LAN access off + Wi‑Fi DNS pinned to `1.1.1.1`/`8.8.8.8`.
3. The old **guard cleared exit permanently** on brief blips. Fix: supervisor keeps `desired=on` and **re-enables** after recover instead of leaving ISP.

```bash
~/bin/nord-exit on              # Barcelona (sets desired=on)
~/bin/nord-exit off             # ISP (desired=off)
~/bin/nord-exit fix             # unblackhole; re-enables if desired=on
~/bin/nord-exit fix --off       # unblackhole and stay off
~/bin/nord-exit watch-install   # supervisor every 45s
```

**Tradeoff:** home LAN unreachable while exit is on — use `off` when needed.

Do **not** `docker stop` / `compose down` the `nord-exit-*` containers while the exit node is on.

## Change Nord country

Edit `CONNECT` in `.env`, then:

```bash
docker compose up -d vpn
```

## Notes

- Host the stack on any always-on Docker host (this Mac or the Mac mini). Same compose file.
- Do **not** also connect the NordVPN macOS app in full-tunnel mode while using this — it fights Tailscale.
- Exit-node approval is required once in the admin console.
