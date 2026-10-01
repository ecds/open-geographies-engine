# open_geographies_platform

A Rails engine that extends Performant Software's **Core Data** (now **FairData**) with
the Open Geographies layer: a no-code, multi-tenant geospatial publishing platform
(atlas provisioning, Sites, authority bulk imports from GeoNames/Wikidata, and a
by-slug public atlas API for the shared dynamic renderer). It is the upper layer of
Open Geographies; the lower layer — the canonical schema, the v1 API and Elasticsearch
indexing — is
[`open-geographies-fairdata`](https://github.com/ecds/open-geographies-fairdata) (gem
`open_geographies_fairdata`, module `OpenGeographies`; renamed from
`core-data-connector-open-geographies` on 2026-09-11).

Because the lower engine took the bare `OpenGeographies` module, this engine's Ruby
namespace is **`OpenGeographiesPlatform`** (gem `open_geographies_platform`). Its
domain classes still live in `CoreDataConnector::`; references into the lower engine
are written `::OpenGeographies::V1::…` / `::OpenGeographies::ProjectModelRole`.

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
  are applied at boot as **decorators** (`lib/open_geographies_platform/decorators.rb`), never
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
# Gemfile: gem 'open_geographies_platform', path: '../open-geographies-engine'
cp .env.example .env   # DATABASE_*, SECRET_KEY_BASE, ELASTICSEARCH_HOST/API_KEY, REDIS_URL
bundle install
bin/rails db:create
bin/rails railties:install:migrations FROM=open_geographies            # the lower engine's
bin/rails railties:install:migrations FROM=open_geographies_platform   # ours
bin/rails db:migrate
bin/rails runner 'Rails.application.eager_load!; puts "ok"'
```

Verified 2026-09-11 on `ecds` @ `ff020c5` (lower engine `67d0728`) with Ruby 4.0.5:
bundle resolves both engines, both `Engine` classes load with their own roots, all
migrations apply (including the lower engine's table rename), eager load is clean,
every route this engine adds appears under `/core_data` alongside the lower engine's
mount at `/open_geographies`, and the tenancy probe passes 37/37.

## Install (host app)

```ruby
# Gemfile (host = core-data-cloud / FairData, which provides the CoreDataConnector
# classes natively — the standalone core_data_connector gem no longer exists)
gem 'open_geographies_platform', git: 'https://github.com/ecds/open-geographies-engine.git'
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
is loaded, else `lib/open_geographies_platform/canonical_template.json` (a vendored snapshot of the lower engine's 0.3.0; never
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

The atlas settings editor covers name/slug, branding (logo, favicon, share image, fonts,
colors, footer), the home page, standalone pages and the menu (see "An atlas is a site"
below), map layers, search apps (collection, facets, result card), detail-page field
hiding, an Advanced JSON tab for the rest of the config with the emitted config.json, plus
Reindex and Build map tiles. Facet choices come from
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

## Getting places in: upload a dataset, or a gazetteer

The wizard's "Add places" step and each atlas's Imports page offer two sources.

**Upload your data** (`DatasetImportsController`, `ImportDatasetJob`,
`app/services/core_data_connector/dataset_imports/`). A CSV (comma, semicolon or tab; any
common encoding), an Excel (.xlsx) or OpenDocument (.ods) workbook (first sheet), a GeoJSON
file, or a zipped shapefile (.shp + .dbf, with .prj/.cpg when present; longitude/latitude
only — projected files are refused with re-export steps), up to 50 MB / 50,000 rows.
Workbooks use roo and shapefiles rubyzip, both already in core-data-cloud's bundle; the
shapefile reader needs no GIS library. The preview proposes a role per
column (place name, field, category, latitude, longitude, geometry, identifier, skip) and a
field type, shows the rows on a map, and lists rows whose location can't be used (e.g. a
projected CRS). The place-name suggestion is scored (a name-like header, filled, nearly unique,
not dates/links/ids), so `RESNAME` beats a first column of dates. Columns that carry nothing a
visitor would read start as *Don't import* with the reason shown — the same value in every
row, GUIDs, GIS bookkeeping (`Shape_Length`, created/edited stamps), millisecond timestamps —
and "Skip all fields" clears the rest of a wide export so the curator turns on only what they
want. Numbers with leading zeros are offered as text. Dates as historical data has them — a
year, a month (`1983-03`, NPS's `1983-03-`), a decade, a range, *circa* — are offered as a
partial date (Core Data's fuzzy date, shown as "1911" or "March 1983", never with an invented
day); *Exact date* takes only full YYYY-MM-DD. A column of marks and blanks ("X" on 7 rows)
reads as Yes/No. For each type a column could take, the preview counts the values it couldn't
read, and the console warns under the column before anything is left empty
(`DatasetImports::Values` does the reading for both preview and import). Nothing is written
until the curator presses Import. Then:

- each row becomes a Place with its name, geometry and typed field values;
- missing fields are created on the Places model; a column matching an existing field
  (e.g. "Short Description") fills it, so canonical promotions still apply;
- a category column becomes Types terms on the canonical Places→Types relationship
  (created as the template defines it if the project lacks one) — the atlas's `types` facet;
- short, repetitive text columns default to pick-list (Select) fields, which the index
  turns into `*_facet` keywords;
- with an identifier column, importing again skips rows whose id is already in the atlas;
  rows of one file that share an id (one listing covering several buildings) are all
  imported, and the preview warns that the column repeats;
- afterwards the project's atlases get the category and pick-list fields as filters, and
  the identifier is hidden on public pages (only ever added, never removed).

Older .xls, a bare .shp and KML are refused with instructions. Fixtures for each reader,
written with independent tools (openpyxl, odfpy, GDAL), are in `test/fixtures/datasets/`.

**From a gazetteer**: GeoNames and Wikidata imports for the atlas's area (`PlaceImportsController`,
`ImportPlacesJob`), idempotent by authority identifier.

Both suspend per-record indexing and queue one scoped reindex. Reindexes of one project run
one at a time (advisory lock in `ReindexAtlasJob`).

## An atlas is a site: home page, pages, branding

Each atlas has its own home page and any number of standalone pages (About, Credits, …),
edited in the console and served by the shared renderer. They live on the site as
`content` (`CoreDataConnector::SiteContent`):

```
{ home:  { description, sections: [...] },
  pages: [{ slug, title, description, sections: [...] }, ...] }
```

A section is a **banner** (`hero`: title, subtitle, background image, search box, button),
**text** (Markdown), **text and image**, or a **call to action**. Text is stored as the
curator wrote it; the renderer converts and sanitizes it. The server holds every link and
image source to a site path, http(s) or mailto (never `javascript:`/`data:`), and branding
colors, sizes and fonts to their formats, since they end up in the renderer's CSS.

- A new atlas starts with a home page: a banner with its description, a search box and a
  button into the map. Atlases without one get the same page by default.
- The navigation can point at a page (`{ _template: 'Page', page: 'about' }`); the public
  bundle turns it into a link labelled with the page's title. With no navigation saved it is
  Explore plus every page.
- Images (logo, favicon, page images) are uploaded to the site
  (`POST /core_data/sites/:id/assets`, multipart `file`; `GET` lists, `DELETE …/assets/:key`
  removes): PNG, JPEG, GIF, WebP, AVIF, SVG or ICO, read from the file's contents, up to
  10 MB. They are ActiveStorage attachments (S3 in production) served publicly at
  `/core_data/public/v1/assets/:key/:filename`, immutable, with a sandboxing CSP so an
  SVG can't run script. Only site assets are served there, never a job's or an upload's
  file. It's our route, not ActiveStorage's: on core-data-cloud the SPA catch-all is drawn
  ahead of ActiveStorage's routes, so `rails_blob_url` answers with the console's HTML.
- `GET /core_data/public/v1/atlases/:slug` carries `content` next to `config`, `branding`
  and `navigation`; `config` (which the browser also fetches) never holds the pages.

## Upstream-PR posture

A few decorators carry changes that are **general improvements** to Core Data, not
Open Geographies specifics — the public-API `discoverable` gate, the orphaned-
relationship index crash-guard, GeometryCollection flattening, and an index progress
callback. These are offered upstream as separate PRs (see `UPSTREAM_PRS.md` in the
parent project) and are written to be **deleted from this engine** if/when they land
in an upstream release we depend on. The engine carries them meanwhile so the platform
is correct (and secure) regardless of upstream timing.
