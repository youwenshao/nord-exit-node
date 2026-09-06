# Agent redeploy contract

This repo is a NordVPN + Tailscale **exit node** stack. An agent on a **fresh Ubuntu 24.04** machine should be able to bring it up without a human sitting at the keyboard, given secrets.

## Do not invent credentials

Stop if any of these are missing. Do not guess tokens, scrape chat history, or commit secrets.

- Nord `TOKEN`
- Tailscale `TS_AUTHKEY` (reusable, non-ephemeral)
- `/dev/net/tun`
- Git clone access to this **private** repo

## Human one-time steps (not automated)

1. Nord account → access token → `TOKEN`.
2. Tailscale admin → Settings → Keys → reusable auth key → `TS_AUTHKEY`.
3. Tailscale admin → Access controls → paste `autoApprovers.exitNode` from [docs/tailscale-acl.md](docs/tailscale-acl.md).

## Redeploy on Ubuntu 24.04

```bash
git clone git@github.com:youwenshao/nord-exit-node.git
cd nord-exit-node
cp .env.example .env
# write TOKEN and TS_AUTHKEY into .env (mode 600). Never commit .env.
chmod 600 .env
./deploy/bootstrap.sh
```

`bootstrap.sh` installs Docker Engine + the compose plugin, writes `.env.tailscale` (including `TS_AUTHKEY`), starts the stack, installs `~/bin/nord-exit`, and enables the systemd user guard timer.

If `TS_AUTHKEY` is unset, `./up.sh` falls back to an interactive login URL in `AUTH_URL.txt`. That is not unattended — stop and ask for a key.

## Verify

```bash
docker inspect -f '{{.State.Health.Status}}' nord-exit-vpn   # healthy
docker exec nord-exit-vpn curl -4 -fsS --max-time 10 https://ipinfo.io/json
docker exec nord-exit-tailscale tailscale --socket=/tmp/tailscaled.sock status
~/bin/nord-exit doctor
```

Expect Nord/PacketHub (or similar) on the container public IP, and the container node advertising an exit node. On a **client** (laptop), run `nord-exit on` and confirm the host public IP is Spain when `CONNECT=Barcelona`.

## Client vs host

- Stack host: `NORD_EXIT_ROLE=host` in `.env` (bootstrap sets this).
- Laptop after cutover: `NORD_EXIT_ROLE=client`. Do not `docker compose up` on the laptop.

## Hostname cutover

Only one live machine should use `TS_HOSTNAME=nord-exit`. Bring a replacement up as `nord-exit-ws` first if the old node is still online, verify, stop the old stack (keep its `state/` for rollback), then `tailscale set --hostname=nord-exit --advertise-exit-node --accept-dns=false` inside the new container.

## Never commit

`.env`, `.env.tailscale`, `state/`, `AUTH_URL.txt`, `*.log`, `wireguard/*.conf`, `host-wg/*.conf`.
