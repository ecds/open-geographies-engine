# Open Geographies — demo stack

The whole platform on one machine with one command: the FairData host with
this engine mounted, the shared v1 Elasticsearch index, PostGIS, and the
shared dynamic renderer — seeded with the Historic Rural Churches of Georgia
atlas pulled from the live instance's public API.

```
cd demo
cp .env.example .env      # add a MapTiler key and a GeoNames username
docker compose up --build
```

The first build takes a while (Ruby gems, the FairData console, the renderer).
Once `host` logs `[seed] … HRCGA is live`, open:

| | |
|---|---|
| **The atlas** | http://hrcga.localhost:4321/en/search/places |
| **Its settings** (facets, layers, hidden fields, reindex) | http://localhost:3001/atlases |
| **Create another atlas** | http://localhost:3001/wizard |
| FairData console (projects, data entry) | http://localhost:3001 |
| Elasticsearch | http://localhost:9200 |

Sign in as `admin@example.com` / `Changeme1!!` (change both in `.env`). The
engine pages have their own sign-in form against the host's `/auth/login`, so
they work with or without FairData's nav link.

Every `*.localhost` name resolves to the machine in Chrome, Firefox and Safari
with no hosts-file change; an atlas created in the wizard with slug `foo` is at
`http://foo.localhost:4321` the moment it's provisioned.

## What's in the box

| Service | Image | Notes |
|---|---|---|
| `db` | postgis/postgis 16-3.4 | `core_data` / `core_data_local`, published on :54334 |
| `elasticsearch` | elasticsearch 8.15 | single node, security off, the `open_geographies_v1` index |
| `host` | `host/Dockerfile` | `ecds/core-data-cloud` (`ecds` branch) + the two mount patches in `host/patches/` + this engine, built from the repo checkout you run it from |
| `renderer` | `renderer/Dockerfile` | `ecds/core-data-places` `main` (pin with `RENDERER_REF`), Astro's standalone Node adapter |

`host/patches/` is the future integration PR against the host, as patches:
the `open_geographies` gem mount (`path: '../open-geographies-engine'`), the
two additive migrations, and the lower-engine pin bump to `42a8727`
(`Reindexable`). Nothing in the host repo needs to change for the demo to run.

The host seeds itself on start (`host/seed.rb`, idempotent): the admin
account, then the HRCGA project cloned through `coredata.ecds.io`'s public
API (`open_geographies:import_public_project`), its search collection and
site, and the churches reindexed. The fetched snapshot is kept in the `og_import` volume so a rebuilt
container doesn't walk the source again. Set
`DEMO_SKIP_HRCGA=1` for an empty instance.

## Decisions

**The engine's console ships as a committed bundle.** `client/` (the wizard
and atlas pages) is built with `cd client && npm run build` and the result in
`public/wizard/` is committed. The host image therefore needs no knowledge of
our client — its Dockerfile stays Jay's, and the engine is mounted like any
other gem. The cost is ~3 MB of built assets in the repo and the discipline of
rebuilding before committing a client change; the alternative (the host's
Docker build running our `npm run build`) couples the host image to our
toolchain for no runtime gain. Revisit if the bundle starts churning.

**The renderer reads the host at two addresses.** The atlas config's
`core_data.url` is what the browser uses (`http://localhost:3001`); the
renderer's own server-side fetches use `OG_CORE_DATA_INTERNAL_URL`
(`http://host:3000`, inside the compose network). Same for `OG_CONSOLE_URL`.

**Development mode, in-process jobs.** The host runs `RAILS_ENV=development`
(as `Dockerfile-ecds` does), so ActiveJob uses the async adapter — no Redis or
Sidekiq to run. Wizard provisioning, imports and reindexes run inside the
host process; a container restart drops jobs in flight.

## Knobs (`.env`)

| | default | |
|---|---|---|
| `VITE_MAP_TILER_KEY` | — | wizard area picker, FairData maps |
| `GEONAMES_USERNAME` | — | admin-unit picker, place imports |
| `DEMO_ADMIN_EMAIL` / `DEMO_ADMIN_PASSWORD` | `admin@example.com` / `Changeme1!!` | |
| `BUILD_CONSOLE` | `1` | `0` skips the FairData console build (engine pages still work) |
| `DEMO_SKIP_HRCGA` | `0` | `1` seeds only the account |
| `DEMO_HRCGA_SOURCE` | `https://coredata.ecds.io` | where the HRCGA project is pulled from |
| `RENDERER_REF` | `main` | git ref of `ecds/core-data-places` |
| `SECRET_KEY_BASE` | a demo value | |

## Rebuilding

The host image copies the engine at build time; after changing engine code,
`docker compose build host && docker compose up -d host`. The renderer clones
at build time; `docker compose build --no-cache renderer` picks up new
commits on `main`.
