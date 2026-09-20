# Running RecFlare locally

This folder is the local-play layer for this fork: a self-contained way to run the
whole RecFlare stack (all Workers + a TLS front door + a self-hosted Photon) on one
machine, so a patched Rec Room client can play against it.

It exists because `just dev` alone isn't enough for a *client* to connect:

- The Workers are plain HTTP on `8787…`; a client expects HTTPS at the hostnames the
  `ns` worker advertises.
- The shared `recflare` D1 is one database in production but one *per worker* locally,
  so `auth` can't read tables `api`/`rooms` own.
- Photon Realtime has to come from somewhere — here, [Luxon Server](https://github.com/niansa/LuxonServer),
  a clean-room Photon LoadBalancing reimplementation (rooms/matchmaking/events; not chat/voice).

Everything is under this folder; the repo is its parent. `start-server.sh` uses
`RECFLARE_REPO` if you keep the checkout elsewhere.

## What this fork changes in the repo

Three small, general local-dev fixes (see the diffs):

- `packages/tools/bin/run-wrangler-dev` — every worker shares one local persist dir
  (`<repo>/.wrangler/state`), so the shared D1 really is shared; and inspector ports
  start at `19229` instead of `9229`, because Vite (`www`) walks up from `9229` and
  steals a worker's port.
- `packages/tools/bin/run-wrangler-migrate` — `--local` targets that same shared dir.
- `apps/ns/wrangler.jsonc` — the dev `DOMAIN`/`SUBDOMAINS` defaults point at the local
  hosts (`rec.localhost:8443`). Deploy still overrides both from `.env`.

## Prerequisites

- The repo's toolchain: `node`, `pnpm`, `bun`, `just` (the repo pins these in
  `.mise.toml`; `mise install` handles it).
- `openssl` and `curl`.
- A Linux host (the Luxon prebuilt is Linux x86-64; build from source otherwise).

## Setup

```sh
local/setup.sh          # cert + Luxon binary + luxon/config.yml
cp .env.example .env    # then edit (below)
pnpm install
```

`.env` needs at least:

```sh
RECFLARE_DOMAIN=rec.localhost:8443
RECFLARE_SUBDOMAINS='{"moderation":"api"}'

# Photon Cloud apps you created (dashboard.photonengine.com) — not secrets.
RECFLARE_PHOTON_REALTIME_APP_ID=<guid>
RECFLARE_PHOTON_VOICE_APP_ID=<guid>
RECFLARE_PHOTON_CHAT_APP_ID=<guid>
RECFLARE_PHOTON_REGION=us
```

Then apply migrations into the shared local D1 (sequential; `turbo migrate` is flaky):

```sh
for w in api auth chat clubs econ img leaderboard lists match roomcomments rooms; do
  (cd apps/$w && PATH="$PWD/node_modules/.bin:$PATH" run-wrangler-migrate --local)
done
```

Seed the shared local `JWT_SECRET` (every worker binds it):

```sh
cd apps/auth
printf 'local-dev-jwt-secret-do-not-use-in-prod' |
  PATH="$PWD/node_modules/.bin:$PATH" wrangler secrets-store secret create local \
    --name JWT_SECRET --scopes workers --persist-to "$(git rev-parse --show-toplevel)/.wrangler/state"
```

## Run

```sh
local/start-server.sh start     # workers + proxy + luxon
local/start-server.sh status
local/start-server.sh restart
local/start-server.sh stop
```

`status` should read `27/27 workers running / proxy running / luxon running`.

The TLS proxy binds **443 and 8443** on **127.0.0.1 and ::1**. 443 needs privilege:

```sh
sudo sysctl -w net.ipv4.ip_unprivileged_port_start=443
# persist across reboots:
echo 'net.ipv4.ip_unprivileged_port_start=443' | sudo tee /etc/sysctl.d/99-recflare.conf
```

## How it fits together

```
client ──HTTPS──> proxy (443/8443, self-signed)
                     ├─ <service>.rec.localhost ──> worker port 8787+i
                     └─ ns.rec.localhost         ──> ns worker

client ──UDP────> Luxon (5058 Name / 5055 Master / 5056 Game, dashboard :5088)
```

- `*.localhost` resolves to loopback, so no `/etc/hosts` edits are needed. The `ns`
  worker advertises `https://<service>.rec.localhost:8443`; the proxy maps the first
  host label to the worker `run-wrangler-dev` assigned it.
- The proxy terminates TLS with `cert.pem`/`key.pem` — the clients' patches disable
  certificate validation, so self-signed is fine.
- The proxy listens on 443 too because the 2023 BepInEx plugin rewrites only the *host*
  of `https://ns.rec.net`, dropping the port; its first fetch lands on 443.
- Both loopbacks matter: `*.localhost` resolves to `127.0.0.1` and `::1`, and Wine picks
  the IPv6 one, so a missing `::1` listener means `ECONNREFUSED`.

## Luxon (Photon)

Luxon replaces Photon Cloud for room networking: the client connects to `127.0.0.1:5058`
and joins the `photonRoomId` the `match` worker hands out. Dashboard: http://127.0.0.1:5088/.

It implements Photon Realtime (LoadBalancing): Name/Master/Game servers, lobbies,
matchmaking, rooms, actor/event relay, peer persistence. It does **not** implement Photon
Chat (opcodes) or Photon Voice.

## Client configuration

### 2023 client (BepInEx RecNet plugin) — tested, has the Rec Center door

`BepInEx/config/net.rec.plugin.cfg`:

```ini
[Advanced]
Enabled Advanced Settings = true
Photon NameServer = 127.0.0.1
Photon NameServer Port = 5058

[Photon]
App Id Realtime = <your realtime guid>
App Id Voice = <your voice guid>
App Id Chat = <your chat guid>

[Server]
RecNet NameServer Host = https://ns.rec.localhost:8443
```

Notes:
- `Enabled Advanced Settings = true` + `Photon NameServer = 127.0.0.1` points Photon at
  Luxon. (With it `false`, the client uses Photon Cloud's own name server and just your
  app ids — fine for cloud, not for Luxon.)
- The 2023 client auto-logs-in via Steam; on a non-Steam launch Steam init fails and the
  ticket login is refused. Launch it through Steam (a non-Steam shortcut) with
  `WINEDLLOVERRIDES="winhttp=n,b" %command%` so Doorstop/BepInEx loads.

### 2025 client (patch-2025 injector)

`2025patch.ini`: `ApiHost=ns.rec.localhost:8443`, and for Luxon set
`PhotonHost=127.0.0.1` / `PhotonPort=5058` (leave `PhotonHost` empty to use Photon Cloud).

Caveat: the supported 2025 build (`20250718.01`) has the **Room-i-verse** Dorm door — its
label is baked into the client, and only its destination is server-configurable
(`Door.Dormroom.Query`). The 2023 client predates that and has the native Rec Center door.
September 2025+ re-added the Rec Center door, but needs a patch ported to that build.

## Voice

Neither client gets working voice out of the box:

- The 2023 client uses **Photon Voice** (a LoadBalancing client Luxon *does* carry — it
  joins the `<roomId>_voice_` room — but Luxon's deserializer rejects one of its packets,
  and the client is then disconnected). The 2025 client uses **Tachyon**, Rec Room's own
  voice service, which ships nowhere here (`RECFLARE_TACHYON_HOST_PORT` unset).
