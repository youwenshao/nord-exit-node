# Nord exit node (via Tailscale)

Standalone location-spoof stack: **NordVPN for public egress** + **Tailscale advertise-exit-node**.

Daily CLI: `nord-exit` (`bin/nord-exit`, also `~/bin/nord-exit`). The same script hosts the Docker stack on Ubuntu and selects the exit node on macOS or Linux clients.

Private repo: `github.com/youwenshao/nord-exit-node`.

## What runs where

- **Host** (always-on Ubuntu, intended: `syw-workstation`): Docker Compose stack. Container hostname `nord-exit`.
- **Client** (MacBook Air, or any other tailnet node): Tailscale app/CLI selects that exit node. Mesh alone does **not** change your public IP.

## Secrets

Copy [`.env.example`](.env.example) to `.env` (gitignored, mode `600`):

- `TOKEN` — Nord access token
- `TS_AUTHKEY` — reusable Tailscale auth key (unattended bring-up)
- `CONNECT` — Nord city (default `Barcelona`)
- `NORD_EXIT_ROLE` — `host` | `client` | `auto`

Never commit `.env`, `.env.tailscale`, or `state/` (Tailscale node identity).

## Ubuntu host (agent or human)

See [AGENTS.md](AGENTS.md) for the unattended path.

```bash
git clone git@github.com:youwenshao/nord-exit-node.git
cd nord-exit-node
cp .env.example .env   # fill TOKEN and TS_AUTHKEY
./deploy/bootstrap.sh
```

`bootstrap.sh` installs Docker Engine, starts the stack, links `~/bin/nord-exit`, and enables a systemd user timer (`nord-exit-guard.timer`, every 45s).

Before the first new host, add ACL auto-approval ([docs/tailscale-acl.md](docs/tailscale-acl.md)):

```json
"autoApprovers": {
  "exitNode": ["youwenshao@github"]
}
```

### Manual host start

```bash
./up.sh
```

If `TS_AUTHKEY` is set, login is non-interactive. If it is unset, `up.sh` prints a Tailscale auth URL (`AUTH_URL.txt`) and waits.

## Client use (macOS or Linux)

Location spoofing only works while the Tailscale **exit node** is selected **and** the Docker stack is running on the host.

```bash
nord-exit on              # Barcelona (sets desired=on)
nord-exit off             # ISP (desired=off)
nord-exit fix             # unblackhole; re-enables if desired=on
nord-exit fix --off       # unblackhole and stay off
nord-exit watch-install   # supervisor every 45s
nord-exit doctor
```

On macOS the supervisor is a LaunchAgent. On Linux it is a systemd user timer.

**Tradeoff:** home LAN is unreachable while the exit is on — use `off` when you need LAN.

After the host moved off this Mac, set `NORD_EXIT_ROLE=client` in the laptop `.env` so the CLI never starts Docker Desktop for the stack.

## Change Nord country

Edit `CONNECT` in `.env` on the **host**, then:

```bash
docker compose up -d vpn
```

## Robustness

Two stacked root causes this stack already mitigates:

1. **Nord container iptables** used `OUTPUT DROP` and only allowed NordLynx UDP/51820. Tailscale WireGuard UDP was blocked → exit path was DERP-TCP only. `scripts/nord-connect-svc/run` punches UDP/ICMP on `eth0` + Tailscale↔NordLynx FORWARD every 20s.
2. **Host DNS** with `--exit-node-allow-lan-access` put the LAN resolver on the tunnel and blackholed resolution. Fix: LAN access off + public DNS (1.1.1.1 / 8.8.8.8).
3. The guard keeps `desired=on` and **re-enables** after recover instead of leaving ISP.

Nord’s kill switch/firewall stays **off** inside the container on purpose (DERP/handshake issues, especially under Docker Desktop). Egress still goes out NordLynx.

Do **not** `docker stop` / `compose down` the `nord-exit-*` containers while clients have the exit selected.

## Hostname cutover

Only one live node should be named `nord-exit`. If you are replacing the host, bring the new stack up as `nord-exit-ws` (`TS_HOSTNAME=nord-exit-ws`), verify Nord egress, stop the old stack (leave `state/` on disk for rollback), then rename the new container node to `nord-exit`. `reclaim-name.sh` waits for the offline MagicDNS name to disappear.

## Notes

- Do not also connect the NordVPN desktop app in full-tunnel mode while using this — it fights Tailscale.
- `use-exit.sh` is a wrapper around `bin/nord-exit`.
