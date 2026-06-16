# open_geographies

A Rails engine that extends Performant Software's **Core Data**
(`core_data_connector`) with the Open Geographies layer: a no-code, multi-tenant
geospatial publishing platform (atlas provisioning, Sites, SearchCollections,
authority bulk imports from GeoNames/Wikidata, automated Typesense indexing, and a
by-slug public atlas API for the shared dynamic renderer).

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

## Install (host app)

```ruby
# Gemfile (host = core-data-cloud)
gem 'core_data_connector'                       # stock upstream — no fork
gem 'open_geographies', git: 'https://github.com/terminusfilms/open-geographies-engine.git'
```

```sh
bundle install
bin/rails open_geographies:install:migrations   # copies the additive migrations
bin/rails db:migrate
```

The host already mounts `CoreDataConnector::Engine` at `/core_data`; this engine adds
its routes there automatically. Nothing else to wire.

## Upstream-PR posture

A few decorators carry changes that are **general improvements** to Core Data, not
Open Geographies specifics — the public-API `discoverable` gate, the orphaned-
relationship index crash-guard, GeometryCollection flattening, and an index progress
callback. These are offered upstream as separate PRs (see `UPSTREAM_PRS.md` in the
parent project) and are written to be **deleted from this engine** if/when they land
in an upstream release we depend on. The engine carries them meanwhile so the platform
is correct (and secure) regardless of upstream timing.
