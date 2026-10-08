# Install Open Geographies on your own server

This directory runs the whole platform on one server with Docker: the FairData console with
the Open Geographies engines (where curators make and manage atlases), the public atlas
renderer, search, a database, and Caddy for HTTPS. An empty platform: you sign
in as its first administrator and make atlases.

## What you need

- **A server** with Docker and Docker Compose: 4 GB of memory at least (8 GB is comfortable),
  2 or more CPUs, 20 GB of disk to start. Any Linux host or cloud VM works.
- **A domain** you can add DNS records to, with two names pointed at the server:
  - the **console**, e.g. `data.example.org` (an A record);
  - **every atlas**, e.g. `*.atlas.example.org` (a wildcard A record). An atlas called
    "Historic Atlanta" is then at `historic-atlanta.atlas.example.org`.
- Ports **80** and **443** open to the internet (Caddy gets the certificates).
- Optional, but recommended: a free [MapTiler](https://cloud.maptiler.com) key (maps in the
  console) and a free [GeoNames](https://www.geonames.org/login) username (areas and place
  lookups). For email (inviting curators, feedback), a [Postmark](https://postmarkapp.com)
  server token.

## Install

```sh
git clone https://github.com/ecds/open-geographies-engine.git
cd open-geographies-engine/install
cp .env.example .env
chmod 600 .env
```

Fill in `.env`: the two domains, your email and a password for the first administrator, and
the secrets (each a long random string, e.g. `openssl rand -hex 64`). Then:

```sh
docker compose up -d --build
```

The first build takes 15–30 minutes. Watch the console start with
`docker compose logs -f host`; when it says it's listening, open `https://data.example.org/atlases`
(your console domain), sign in with `ADMIN_EMAIL` / `ADMIN_PASSWORD`, and **Create an atlas**.
The [curator guide](../docs/CURATOR_GUIDE.md) walks through the rest.

An atlas's certificate is issued the first time someone opens its address, which takes a few
seconds once.

## Inviting curators

In an atlas's settings, **People →** opens the FairData console, where owners add curators by
email. Invitations need email: set `POSTMARK_API_TOKEN` and `POSTMARK_FROM`, then
`docker compose up -d`. Without it, add curators' accounts in the console and tell them their
password yourself.

## Where things are kept

| Volume | What | Back up |
|---|---|---|
| `pgdata` | the database: atlases, places, accounts, history | **yes**, daily (`docker compose exec db pg_dump -U og open_geographies`) |
| `storage` | uploaded files: images, datasets | **yes** |
| `esdata` | the search index | no: rebuilt from the database (an atlas's **Reindex**) |
| `caddy_data` | certificates | optional |
| `redisdata` | the job queue | no |

To keep uploaded files in S3 (or another S3-compatible store) instead, set `S3_BUCKET`,
`S3_ACCESS_KEY`, `S3_SECRET_KEY` and `S3_REGION`; for a store other than AWS, also
`S3_ENDPOINT` and usually `S3_FORCE_PATH_STYLE=true`, then `docker compose up -d`. Files
uploaded before the switch stay in the `storage` volume and are still read from there.

## The job dashboard

Imports, reindexes and photo copies run as background jobs. Their dashboard (`/sidekiq`) isn't
served to the internet. To look at it, tunnel to the console's container over SSH:

```sh
# on the server: the console container's address, e.g. 172.18.0.5
docker compose exec host hostname -i
# on your computer
ssh -L 3000:172.18.0.5:3000 you@your-server
```

Then open `http://localhost:3000/sidekiq` and sign in with an administrator's email and password.

## Updating

```sh
git pull
docker compose build --pull
docker compose up -d
```

The build picks up new commits on `HOST_REF` and `RENDERER_REF` by itself. The console applies
database changes when it starts, its engines' included. If you edit a `Caddyfile`, rebuild
Caddy: `docker compose up -d --build caddy` (it's built into the image, so the stack has no
bind mounts and runs from any folder).

## Trying it on one computer

To look around without a server or DNS, use the "Trying it on one computer" lines at the end of
`.env.example` (plain HTTP on port 8080, names under `localhost`), then open
`http://console.localhost:8080/atlases`. Atlases appear at `http://<atlas>.atlas.localhost:8080`.

## Good to know

- **Search stays private.** Only Caddy is reachable from outside; the database, search index
  and job queue are on the stack's internal network.
- **What's refused at the edge:** the job dashboard and Active Storage's own endpoints (its
  upload URLs would take files from anyone). Sign-in allows 10 attempts from one address in
  3 minutes. Atlases accept request bodies up to 1 MB, the console up to 100 MB.
- **Address lookups** use the U.S. Census Bureau for U.S. addresses and OpenStreetMap's public
  service elsewhere (one address a second, at most 500 an import). For more, run your own
  Nominatim and set `OG_NOMINATIM_URL`. See `PRODUCTION.md` in the repository root.
- **The first administrator** comes from `ADMIN_EMAIL` / `ADMIN_PASSWORD`. The console's own
  seed account (`admin@example.com`) is taken over on the first start, so no install keeps its
  published password.
- **Versions**: `HOST_REF` is the FairData branch that mounts the engine (`og/platform-engine`
  until that's merged into `ecds`), `ENGINE_REF` a newer engine commit than it pins, and
  `RENDERER_REF` the renderer's branch.
- The full production checklist (proxy rules, monitoring, Elasticsearch sizing) is
  [`PRODUCTION.md`](../PRODUCTION.md).
