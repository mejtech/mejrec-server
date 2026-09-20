# mejrec-server

An easy-setup, **fully local** Rec Room server. One machine, no Cloudflare account, no
Photon Cloud — realtime (rooms, matchmaking, events) is self-hosted with
[Luxon Server](https://github.com/niansa/LuxonServer), so the only thing that still wants
a hosted backend is **voice chat**, and that's optional.

It's a fork of [RecFlare](https://github.com/recflare/server) (MIT) that adds a local
play layer on top of the same Workers.

> ⚠️ Unofficial, fan-made, for preservation and experimentation. Not affiliated with or
> endorsed by Rec Room Inc. "Rec Room" is a trademark of its respective owner.

## What you get

- All 27 RecFlare Workers — accounts, auth, rooms, matchmaking, economy, chat, clubs,
  leaderboards, notifications, … — running locally on one box.
- **Luxon** as a drop-in Photon Realtime server (Name/Master/Game, lobbies, matchmaking,
  rooms, actor/event relay). No Photon Cloud app or account needed for room networking.
- A self-signed **TLS front door** so a patched client can reach everything over
  `https://<service>.rec.localhost:8443` (no `/etc/hosts` edits — `*.localhost` resolves
  to loopback).
- One control script: `local/server.sh start | stop | restart | status`.

```
client ──HTTPS──▶ proxy (443 + 8443, 127.0.0.1 + ::1)
                    ├─ <service>.rec.localhost ─▶ worker :8787+i
                    └─ ns.rec.localhost         ─▶ ns worker

client ──UDP────▶ Luxon  (5058 Name / 5055 Master / 5056 Game, dashboard :5088)
```

## Requirements

- **Linux x86-64** (the Luxon prebuilt; build it from source on other platforms)
- Node 24, pnpm, bun, just — pinned in `.mise.toml`; `mise install` gets them
- `openssl`, `curl`, and a Cloudflare-free sense of adventure

## Setup

```sh
git clone https://github.com/mejtech/mejrec-server
cd mejrec-server
local/setup.sh
```

`setup.sh` is interactive and does the rest:

1. asks which **realtime backend** to use:
   - **Luxon (recommended)** — self-hosted, fully local, no Photon account. Voice chat is not available.
   - **Photon Cloud** — realtime *and* voice go through Photon Cloud; you supply your own app ids.

   (A "Luxon realtime + Photon voice" split isn't possible: the client uses one Photon endpoint for both, so voice follows whichever backend you pick.)
2. generates the TLS cert, and for Luxon downloads the binary + writes `luxon/config.yml`
3. writes `.env` (`RECFLARE_DOMAIN=rec.localhost:8443`, the subdomain override, backend-appropriate Photon ids)
4. runs `pnpm install`
5. applies the D1 schema into the shared local database
6. seeds the shared `JWT_SECRET`
7. offers to let the proxy bind 443 (needs `sudo`)

Then:

```sh
local/server.sh start
local/server.sh status     # 27/27 workers running / proxy running / luxon running
```

Logs: `local/logs/<worker>.log`, `local/proxy.log`, `local/luxon/luxon.log`.
Luxon dashboard: http://127.0.0.1:5088/

The choice is saved to `local/backend`, so `server.sh` knows whether to start Luxon.

<details>
<summary>Manual equivalent (what setup.sh runs)</summary>

```sh
cp .env.example .env
#   RECFLARE_DOMAIN=rec.localhost:8443
#   RECFLARE_SUBDOMAINS='{"moderation":"api"}'
#   RECFLARE_PHOTON_*= any GUID (Luxon ignores them) or your Photon Cloud apps
pnpm install

for w in api auth chat clubs econ img leaderboard lists match roomcomments rooms; do
  (cd apps/$w && PATH="$PWD/node_modules/.bin:$PATH" run-wrangler-migrate --local)
done

cd apps/auth
printf 'local-dev-jwt-secret-do-not-use-in-prod' |
  PATH="$PWD/node_modules/.bin:$PATH" wrangler secrets-store secret create local \
    --name JWT_SECRET --scopes workers --persist-to "$(git rev-parse --show-toplevel)/.wrangler/state"
cd ../..

# the proxy binds 443 too (the 2023 client's nameserver fetch drops the port):
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-recflare.conf
```

</details>

## Client setup

### Recommended: the 2023 client (`20230414`)

It's the build this stack targets, and its Dorm has the native **Rec Center** door.
Using the [RecNet Plugin](https://github.com/djdevin/recnet-plugin) (BepInEx), edit
`BepInEx/config/net.rec.plugin.cfg`:

```ini
[Advanced]
Enabled Advanced Settings = true
Photon NameServer = 127.0.0.1
Photon NameServer Port = 5058

[Photon]
App Id Realtime = <a guid>
App Id Voice = <a guid>
App Id Chat = <a guid>

[Server]
RecNet NameServer Host = https://ns.rec.localhost:8443
```

Launch it through Steam (a non-Steam shortcut) with launch options
`WINEDLLOVERRIDES="winhttp=n,b" %command%` so Doorstop/BepInEx loads; the 2023 client
logs in via Steam and needs Steam's identity.

### 2025 client (`20250718.01`)

Using the [2025 patch](https://github.com/recflare/patch-2025) injector, in `2025patch.ini`:

```ini
ApiHost=ns.rec.localhost:8443
PhotonHost=127.0.0.1
PhotonPort=5058
```

Caveat: that build's Dorm door is the **Room-i-verse** door. Its *destination* is
server-configurable, but its label is baked into the client — use the 2023 client if you
want the Rec Center door.

## Voice

Voice is the one piece that isn't local:

- The **2023 client** uses **Photon Voice** — Luxon carries its signaling (it joins the
  `<roomId>_voice_` room), but rejects one of its packets, so voice doesn't work yet.
- The **2025 client** uses **Tachyon**, Rec Room's own voice service, which ships nowhere
  here.

Room networking, text chat (RecFlare's `chat` worker), party chat and everything else work
without any Photon account.

## What this fork changes

- `packages/tools/bin/run-wrangler-dev` — every worker shares one local persist dir
  (`.wrangler/state`), so the shared `recflare` D1 really is shared; and inspector ports
  start at `19229` so Vite (`www`) doesn't steal one.
- `packages/tools/bin/run-wrangler-migrate` — `--local` targets that same shared dir.
- `apps/ns/wrangler.jsonc` — dev `DOMAIN`/`SUBDOMAINS` default to the local hosts
  (`rec.localhost:8443`); deploy still overrides them from `.env`.
- `local/` — the play layer described above.

## Credits & license

MIT, © djdevin and contributors. Built on [RecFlare](https://github.com/recflare/server);
Photon Realtime by [Luxon Server](https://github.com/niansa/LuxonServer); client patches by
[recflare/patch-2025](https://github.com/recflare/patch-2025) and
[recnet-plugin](https://github.com/djdevin/recnet-plugin). See `DEPLOYING.md` for the
upstream Cloudflare deployment path.
