**English** | [Português (Brasil)](README.pt-BR.md)

# Stick2Server — Stick2Planner sync server

Small Dart/shelf service, without Flutter. Stores opaque blobs per entity,
with per-item revision, idempotency by `changeId`, and a global change cursor.

The app connection/pairing/sync flow lives in the
[Stick2Planner app repository](https://github.com/MikeMequis1/Stick2Planner).

## Compatibility

- Server **0.2.1** targets Stick2Planner **0.3.0** and keeps accepting older
  clients.
- Sync entities are `postIt`, `note`, `history` and `tag`. Their payloads are
  stored opaquely; tag colors, palettes and completion rules are interpreted by
  the app, so adding app-only fields does not require a server update.
- Post-it payloads may carry `timeMinutes` and `tagIds`; tag definitions travel
  as the `tag` entity.

## Quick start with the latest image

```bash
cp .env.example .env
# edit ADMIN_TOKEN and PUBLIC_URL

docker compose pull
docker compose up -d
curl -fsS http://127.0.0.1:8090/v1/health
```

Compose pulls `ghcr.io/mikemequis1/stick2server:latest` and always checks the
registry on startup. Override the image with `STICK2SERVER_IMAGE` if needed.

## Image tags

- `latest` — current `main` branch.
- `X.Y.Z` and `X.Y` — released tags.
- `sha-<commit>` — immutable commit image.

Images are published to GitHub Container Registry for `linux/amd64` and
`linux/arm64`.

## Endpoints

| Method | Route | Auth | Use |
| --- | --- | --- | --- |
| GET | `/v1/health` | — | health/version/serverId |
| POST | `/v1/sync` | device token | push + pull in one call |
| GET | `/v1/sync/stats` | device token | active data counts |
| GET | `/v1/sync/snapshot` | device token | full snapshot (keep remote) |
| POST | `/v1/sync/replace` | device token | replaces the set (keep local) |
| POST | `/v1/pair` | pairing token | exchanged for a device token |
| POST | `/v1/admin/pairing-tokens` | admin token | creates a pairing token (TTL) |
| GET | `/v1/admin/devices` | admin token | lists devices |
| POST | `/v1/admin/devices/<id>/revoke` | admin token | revokes a device |

Push applies only when `baseRev` equals the current revision; divergence returns
`conflicts` with the server version. Resending the same `changeId` returns the
previous ack. Pull returns changes after `since` with the entity's current state.

`/v1/sync/stats` and `/v1/sync/snapshot` feed the app's local × remote check.
`/v1/sync/replace` replaces the remote set with the local snapshot: whatever
does not exist in the upload becomes a tombstone, and history is preserved as an
audit trail.

## Variables

| Variable | Default | Description |
| --- | --- | --- |
| `PORT` | `8090` | HTTP port |
| `DB_PATH` | `data/planner-server.sqlite` | SQLite file |
| `ADMIN_TOKEN` | — | required to serve/pair |
| `PUBLIC_URL` | — | URL shown during pairing |

### Generating the ADMIN_TOKEN

The server reads `ADMIN_TOKEN` from the environment; it is not created
automatically when the container starts. Generate a strong value and write it to
`.env` before starting:

```bash
# In this repository
dart run bin/server token
# or: openssl rand -hex 32
```

Copy the output to `ADMIN_TOKEN=` in `.env` and recreate the service:

```bash
docker compose up -d --force-recreate
```

To look up the current value (on the host, with access to `.env`):

```bash
grep '^ADMIN_TOKEN=' .env
```

This token is the administrative password for the web page and the
`/v1/admin/*` endpoints; the paired app uses separate device tokens.

## Docker Compose

Prebuilt image (recommended):

```bash
cp .env.example .env
# edit ADMIN_TOKEN and PUBLIC_URL
docker compose pull
docker compose up -d
docker compose ps
curl -fsS http://127.0.0.1:8090/v1/health
```

Local build:

```bash
docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
```

The named volume `stick2server-data` holds the SQLite database. Backup:

```bash
docker run --rm -v stick2server-data:/data -v "$PWD/backups:/backup" \
  debian:bookworm-slim sh -c 'apt-get update -qq && apt-get install -y -qq sqlite3 >/dev/null && sqlite3 /data/planner-server.sqlite ".backup /backup/planner-$(date +%F).sqlite"'
```

## Migrating an existing deployment

An older local stack may use the volume `stick2planner_planner-data`. To keep
its SQLite data:

```bash
# in the old deployment directory, stop the old stack
docker compose down
# or: docker stop stick2planner-api

docker volume create stick2server-data
docker run --rm \
  -v stick2planner_planner-data:/from \
  -v stick2server-data:/to \
  alpine sh -c 'cp -a /from/. /to/'

docker compose up -d
```

## Pairing

```bash
docker compose exec api /app/bin/server pair 300
```

Output (once, with TTL):

```json
{
  "url": "http://192.168.0.10:8090",
  "serverId": "…",
  "pairingToken": "…",
  "expiresAt": "2026-11-04T…Z"
}
```

This JSON is the content of the pairing QR code. The app exchanges the token at
`/v1/pair` and receives an individual token, stored only in secure storage.

## Devices

```bash
docker compose exec api /app/bin/server devices
docker compose exec api /app/bin/server revoke <deviceId>
```

## Tests

```bash
dart pub get
dart analyze
dart test
```

## Pairing web page

Open `https://planner.<tailnet>.ts.net/` (or the address used for the service) in
the browser and enter the `ADMIN_TOKEN` to sign in. The page shows:

- pairing QR Code **automatically renewed** while it is open
  (5 min TTL, renewal at 4.5 min);
- equivalent text code to paste into the app;
- paired devices, last access, and **rename** and revoke buttons;
- **Português/English** toggle on the client, without reloading; the choice is
  stored in `localStorage` and also translates the QR countdown, states, and
  actions;
- sign-out button (in-memory session, `HttpOnly`/`SameSite=Strict` cookie).

The CLI remains available for automation:

```bash
docker compose exec api /app/bin/server pair 300
```

The page and the `/api/pairing`, `/api/devices` APIs require an administrative
session; without a cookie, they return the login screen/401. Do not expose the
page outside the LAN/Tailnet.

## Optional exposure

The service can stay on the LAN or be exposed through a VPN/Tailscale or a
reverse proxy with TLS. In that case:

- use `PUBLIC_URL` with the external URL so the pairing QR code carries the
  correct address;
- forward the proxy to port `8090`;
- keep authentication/TLS on the proxy and do not publish the port directly to
  the internet;
- configure the proxy labels/rules in the deployment environment, outside this
  repository.

## Security

- Tokens are stored as SHA-256; comparison in constant time.
- Pairing tokens are single-use and expire.
- Body limited to 8 MB, payload to 1 MB, and batch to 500 changes.
- No token or payload logs.
- Expected exposure: LAN or Tailscale, port 8090; not published to the internet.
- `data/` and `.env` are ignored by git.
