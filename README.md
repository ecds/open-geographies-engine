# open_geographies

A Rails engine that extends Performant Software's **Core Data** (now **FairData**) with
the Open Geographies layer: a no-code, multi-tenant geospatial publishing platform
(atlas provisioning, Sites, authority bulk imports from GeoNames/Wikidata, and a
by-slug public atlas API for the shared dynamic renderer). It is the upper layer of
Open Geographies; the lower layer — the canonical schema, the v1 API and Elasticsearch
indexing — is
[`core-data-connector-open-geographies`](https://github.com/ecds/core-data-connector-open-geographies).

## Why an engine

Jay/Emory asked that we **not diverge** the `core-data-connector` / `core-data-cloud`
forks from Performant upstream — fork modifications (especially schema migrations)
make future upstream updates conflict-prone. This engine packages all the Open
Geographies additions so the connector and cloud apps stay **clean upstream mirrors**.

It is **additive by construction**:

- **Schema:** its migrations only `create_table` the two new tables
  (`core_data_connector_sites`, `core_data_connector_search_collections`). They never
  `ALTER` an upstream Core Data table, so they install onto a clean upstream schema
  with no reconciliation.
- **Code:** the ~28 new classes live in the `CoreDataConnector` namespace (they are
  Core Data domain objects). The ~20 places the fork used to *modify* upstream files
  are applied at boot as **decorators** (`lib/open_geographies/decorators.rb`), never
  as forked copies — so there are no file collisions and the upstream surface we track
  is just the decorator list.
- **Routes:** appended into the connector engine's `/core_data` route set.

## Local development against the real host

Develop against what actually deploys: ECDS's `core-data-cloud` fork on branch `ecds`
(the merged Core Data / FairData app, with the lower-layer engine already in its
Gemfile), with this engine mounted from a local path.

```sh
git clone --branch ecds https://github.com/ecds/core-data-cloud.git ecds-core-data-cloud
cd ecds-core-data-cloud
# Gemfile: gem 'open_geographies', path: '../open-geographies-engine'
cp .env.example .env   # DATABASE_*, SECRET_KEY_BASE, ELASTICSEARCH_HOST/API_KEY, REDIS_URL
bundle install
bin/rails db:create
bin/rails open_geographies:install:migrations
bin/rails db:migrate   # host schema, then the lower engine's migrations, then ours
bin/rails runner 'Rails.application.eager_load!; puts "ok"'
```

Verified 2026-09-04 on `ecds` @ `d5ddd03` with Ruby 4.0.5: bundle resolves both
engines, all migrations apply, eager load is clean, and every route this engine adds
appears under `/core_data` alongside the lower engine's mount at `/open_geographies`.

## Install (host app)

```ruby
# Gemfile (host = core-data-cloud / FairData, which provides the CoreDataConnector
# classes natively — the standalone core_data_connector gem no longer exists)
gem 'open_geographies', git: 'https://github.com/ecds/open-geographies-engine.git'
```

The engine declares no dependency on `core_data_connector`: it needs the
`CoreDataConnector` classes to exist at boot, however the host provides them. On the
merged app they are native code. Routes are appended under the host's existing
`/core_data` scope (or to the connector engine's route set on a legacy gem-based host).

```sh
bundle install
bin/rails open_geographies:install:migrations   # copies the additive migrations
bin/rails db:migrate
```

The host already mounts `CoreDataConnector::Engine` at `/core_data`; this engine adds
its routes there automatically. Nothing else to wire.

## Provisioning is the canonical template

`Atlases::Template` creates a wizard-born atlas's models, user-defined fields and
relationships from `canonical_template.json` — the lower engine's own copy when that engine
is loaded, else `lib/open_geographies/canonical_template.json` (a vendored snapshot; never
edit it here — the template's home is the lower engine's repo). Because the lower engine's
`PromotedRelationships` matches names against the same document, a wizard-born atlas is
compliant by construction: "Types" on Places indexes as `types`, "Short Description" as
`short_description`, and so on. Two starters: `places` (Places + Types) and `atlas` (every
non-optional model), plus optional modules by name (Map Layers, Work Types, Tours).

## The console pages (`/wizard`, `/atlases`)

The engine serves its own console pages — the "Create your atlas" wizard at `/wizard`
and the atlas pages at `/atlases` (list; per atlas: settings, place imports, jobs) — from
one small React app that lives in this engine (`client/`). FairData only needs a
navigation link to `/wizard` or `/atlases`; everything past the link is the engine's.

The atlas settings editor covers name/slug, branding, navigation, map layers, search apps
(collection, facets, result card), an Advanced JSON tab for the rest of the config, the
emitted config.json, plus Reindex and Build map tiles. Facet choices come from
`GET /core_data/sites/:id/facets` (`OpenGeographies::FacetCatalog`), which derives what is
actually facetable from the v1 mapping and the template's promotion rules — so the
pick-list never offers an attribute the index can't aggregate.

- It calls the engine's own admin API (`POST /core_data/atlases`, `GET /core_data/jobs/:id`,
  the `place_imports` endpoints) with the session the console already holds
  (`localStorage['core_data_cloud_user']`, sent as `Authorization`), so it needs no login
  of its own. In Clerk mode the `__session` cookie authenticates the same way.
- Runtime settings come from the host's environment: `VITE_MAP_TILER_KEY` (the draw and
  preview maps; without it MapLibre's demo tiles are used), `GEONAMES_USERNAME` (the
  administrative-unit picker and GeoNames imports), `OG_ATLAS_URL_TEMPLATE` (the "view
  your atlas" link).
- The build is committed (`public/wizard/`) so the host needs no Node step. To change the
  wizard: `cd client && npm install && npm run build`, then commit `public/wizard/` with
  the source. `npm run dev` serves it at http://localhost:5175 proxying `/core_data` to a
  host on :3001.

## Upstream-PR posture

A few decorators carry changes that are **general improvements** to Core Data, not
Open Geographies specifics — the public-API `discoverable` gate, the orphaned-
relationship index crash-guard, GeometryCollection flattening, and an index progress
callback. These are offered upstream as separate PRs (see `UPSTREAM_PRS.md` in the
parent project) and are written to be **deleted from this engine** if/when they land
in an upstream release we depend on. The engine carries them meanwhile so the platform
is correct (and secure) regardless of upstream timing.
