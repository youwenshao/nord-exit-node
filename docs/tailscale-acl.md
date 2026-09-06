# Tailscale ACL: auto-approve this exit node

Apply this **once** on the tailnet so a later agent can advertise `nord-exit` without a click in the admin console.

1. Open [Access controls](https://login.tailscale.com/admin/acls).
2. Merge the following into the JSON policy (keep any existing `autoApprovers` keys):

```json
"autoApprovers": {
  "exitNode": ["youwenshao@github"]
}
```

3. Save. New machines that `--advertise-exit-node` and are owned by that identity are approved automatically.

The identity string must match how this tailnet signs in (GitHub). If the editor shows a different login (email, etc.), use that instead of `youwenshao@github`.

Auth keys are separate: create a **reusable, non-ephemeral** key under [Settings → Keys](https://login.tailscale.com/admin/settings/keys) and put it in local `.env` as `TS_AUTHKEY`. Do not commit it. Rotate the key when it expires.

Do not store a Tailscale API token in this repo.
